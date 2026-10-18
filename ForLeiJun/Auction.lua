-- 本文件由 tools/build_lite.py 从 ../WeeklyBoard/Auction.lua 同步生成，请勿手改。
-- 改动请改源文件后重跑：python3 tools/build_lite.py
--==========================================================================
-- ForLeiJun · 拍卖行价格快照（Browse 路径）
--
-- 这一版是照着 Auctionator 的 Source_ModernAH/IncrementalScan 抄的。
-- 起因：本插件原先用 C_AuctionHouse.ReplicateItems()，实测在这台机器上
-- 请求发得出去、服务器就是不回数据（diag 里 lastRequestTs 有、lastEventTs
-- 没有），而玩家的 Auctionator 全量扫描却每次都能成。
--
-- 翻 Auctionator 源码得到的结论：
--
--   Auctionator 有 **三套** 扫描引擎，由一个配置项 REPLICATE_SCAN 分流：
--     * REPLICATE_SCAN = true  → FullScan，用 ReplicateItems()
--     * REPLICATE_SCAN = false → IncrementalScan，用 Browse 查询   ← 默认
--     * 经典旧世拍卖行         → LegacyAH，用 QueryAuctionItems()
--   玩家自己的配置是 ["replicate_scan_3"] = false，也就是他每次点按钮
--   走的其实是 **Browse 路径**，跟 ReplicateItems 一点关系都没有。
--
--   ReplicateItems 的两个硬伤（也是 Auctionator 把它放进「高级」选项的原因）：
--     1) 15 分钟账号级冷却 —— Auctionator 自己在 CanInitiate() 里写死
--        time() - TimeOfLastReplicateScan > 60 * 15。
--     2) 静默失败 —— 不回数据、不报错，玩家完全不知道发生了什么。
--
--   Browse 路径（打开拍卖行 → 发一个「无条件」浏览查询）没有那个冷却：
--
--     发查询：
--       C_AuctionHouse.SendBrowseQuery({searchString="", sorts={},
--                                       filters={}, itemClassFilters={}})
--     收事件：
--       AUCTION_HOUSE_BROWSE_RESULTS_UPDATED  首批（≤500 条）
--       AUCTION_HOUSE_BROWSE_RESULTS_ADDED    后续每一批（服务器自动分页）
--     翻页：
--       C_AuctionHouse.HasFullBrowseResults()      是否已取完
--       C_AuctionHouse.RequestMoreBrowseResults()  请求下一批
--     读数据：
--       C_AuctionHouse.GetBrowseResults() → {
--           { itemKey = { itemID = 12345, ... },
--             minPrice       = 最低单价（铜）,
--             totalQuantity  = 可买总量,
--             containsCommodity = bool },
--           ...
--       }
--
--     ★ 最大的好处：browse 的结果**服务器已经按物品聚合好了**，
--       minPrice 就是单价、totalQuantity 就是总量 —— 不需要我们再遍历
--       十万条挂单自己去算最低价。原先 ReplicateItems 那套遍历+聚合的
--       代码整个可以删掉。
--
--   Auctionator 的节流处理：直接发，让客户端的消息队列自己排队；
--   队列状态看 C_AuctionHouse.IsThrottledMessageSystemReady() 和
--   AUCTION_HOUSE_THROTTLED_* / AUCTION_HOUSE_BROWSE_FAILURE 事件。
--
-- 数据来源限制（不变）：
--   拍卖行数据的唯一出口是「暴雪服务器 → 登录中的游戏客户端」。
--   国服没有对外 HTTP API（cn.api.blizzard.com 不存在，旧的
--   auction-api-cn 已废弃返回 403），第三方数据站只覆盖 us/eu/kr/tw。
--   => 游戏外任何程序都拿不到价格，必须由游戏内插件取、写盘、本地解析。
--==========================================================================

local ADDON, ns = ...

ns.AH = ns.AH or {}
local AH = ns.AH

local time, date, pcall, type, pairs, ipairs, tostring, floor, min, max, ceil =
      time, date, pcall, type, pairs, ipairs, tostring, math.floor, math.min, math.max, math.ceil

-- 可调参数
--（v0.9.31：AUTO_DELAY 已删 —— 打开拍卖行不再自动扫描，只走按钮）
local PAGE_TIMEOUT = 30     -- 连续多少秒收不到新数据就判定卡住、收尾
local MAX_PAGES    = 600    -- 安全上限：600 批 × 500 条 = 30 万条
local MAX_ITEMS    = 150000 -- 安全上限：聚合后最多保留多少种物品
local MAX_NAME     = 36     -- 物品名截断长度
local SOFT_CD      = 60     -- 自发的最小重扫间隔（秒），防手抖连点；不是服务器冷却
local NAME_STEP    = 60     -- 名字补全每批请求多少个 itemID
local NAME_TICK    = 0.4    -- 名字补全的节奏（秒），照抄 Auctionator

AH.SOFT_CD = SOFT_CD

local function msg(s)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd97757[雷菌]|r " .. tostring(s))
    end
end
AH.msg = msg

--==========================================================================
-- 存取
--==========================================================================
local function ahdb()
    local d = ns.db()
    local a = d.ah
    if type(a) ~= "table" then a = {}; d.ah = a end
    if type(a.items) ~= "table" then a.items = {} end
    return a
end
AH.db = ahdb

--==========================================================================
-- 诊断：写进 SavedVariables，出问题时一眼看出卡在哪一步
--==========================================================================
local function diag(k, v)
    local a = ahdb()
    local d = a.diag
    if type(d) ~= "table" then d = {}; a.diag = d end
    d[k] = v
    d.updatedAt = time()
end
AH.diag = diag

local state = {
    phase  = "idle",   -- idle | browsing | naming
    items  = nil,      -- 本次扫描的聚合结果（browsing 期间有效）
    pages  = 0,        -- 已收到多少批
    got    = 0,        -- 已收到多少条原始结果
    kinds  = 0,        -- 已聚合多少种物品
    lastGot = 0,       -- 最后一次收到数据的时刻（用于「无进展才判超时」）
    names  = nil,      -- 名字补全队列（itemID 数组）
    ncur   = 0,        -- 名字补全游标
}

function AH.Busy()
    return state.phase ~= "idle"
end

--==========================================================================
-- 只读信息（给 UI 用）
--==========================================================================
function AH.LastScanText()
    local a = ahdb()
    local ts = a.lastScanTs or 0
    if ts == 0 then return "从未扫描" end
    local d = time() - ts
    if d < 60 then return d .. " 秒前" end
    if d < 3600 then return floor(d / 60) .. " 分钟前" end
    if d < 86400 then return floor(d / 3600) .. " 小时前" end
    return date("%m-%d %H:%M", ts)
end

function AH.CanScan()
    local a = ahdb()
    local elapsed = time() - (a.lastScanTs or 0)
    return elapsed >= SOFT_CD, SOFT_CD - elapsed
end

-- 取某物品的价格（铜），优先用名称或 ID
function AH.PriceOf(itemID)
    local a = ahdb()
    local r = a.items and a.items[itemID]
    if not r then return nil end
    return { unit = r.u or 0, supply = r.n or 0, name = r.nm }
end

-- 拍卖行是否处于「可查询」状态
local function ahReady()
    if not (C_AuctionHouse and C_AuctionHouse.SendBrowseQuery) then
        return false, "当前客户端没有拍卖行的浏览查询接口"
    end
    if InCombatLockdown and InCombatLockdown() then
        return false, "战斗中，稍后再试"
    end
    return true
end

--==========================================================================
-- 名字补全
--   browse 结果里只有 itemKey.itemID，没有名字；客户端对没缓存的物品要
--   异步 C_Item.RequestLoadItemDataByID 之后才有名字（Auctionator 也是这么做的）。
--   所以：扫的时候能拿到就存，拿不到的排队，扫完后分批补。
--   名字写进 a.names 长期缓存，所以补过一次以后就不用再补。
--==========================================================================
local function nameCache()
    -- 名字统一存在 Catalog 的物品目录里（DB.cat.n），避免同一份名字在两处各存一遍
    if ns.Catalog and ns.Catalog.NameMap then return ns.Catalog.NameMap() end
    local a = ahdb()
    if type(a.names) ~= "table" then a.names = {} end
    return a.names
end

local function nameOf(id)
    local cache = nameCache()
    local n = cache[id]
    if n then return n end
    n = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
     or (GetItemInfo and GetItemInfo(id))
    if type(n) == "string" and n ~= "" then
        cache[id] = n:sub(1, MAX_NAME)
        return cache[id]
    end
    return nil
end

local nameFrame = CreateFrame("Frame")
nameFrame:Hide()
nameFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
nameFrame:SetScript("OnEvent", function(_, _, itemID)
    if type(itemID) ~= "number" then return end
    local n = nameOf(itemID)
    if not n then return end
    -- 注意：这里要读 ahdb().items（已落盘的那张表），不能用 state.items ——
    -- 扫描一结束 state.items 就置空了，补名字是「扫描之后」跑的事。
    local rec = (ahdb().items or {})[itemID]
    if rec and not rec.nm then rec.nm = n end
end)

local function pumpNames()
    if state.phase ~= "naming" then return end
    local q = state.names
    if not q or state.ncur > #q then
        local a = ahdb()
        local stillMissing = 0
        for _, rec in pairs(a.items or {}) do
            if not rec.nm then stillMissing = stillMissing + 1 end
        end
        a.namesMissing = stillMissing
        state.phase = "idle"
        state.names = nil
        nameFrame:Hide()
        msg(string.format("价格快照已就绪：%d 种物品%s",
            a.itemCount or 0,
            stillMissing > 0 and ("（" .. stillMissing .. " 种还没有中文名，下次扫描会补上）") or ""))
        msg("|cffd97757输入 /reload 或退出游戏即可落盘，看板会立刻刷新。|r")
        return
    end

    local stop = min(state.ncur + NAME_STEP - 1, #q)
    for i = state.ncur, stop do
        pcall(C_Item.RequestLoadItemDataByID, q[i])
    end
    state.ncur = stop + 1
    C_Timer.After(NAME_TICK, pumpNames)
end

--==========================================================================
-- 扫描主流程
--==========================================================================
local absorb, nextPage, finishScan

-- 把一批原始结果并进聚合表
absorb = function(results)
    if type(results) ~= "table" then return end
    local items = state.items
    local got = state.got
    local kinds = state.kinds

    for i = 1, #results do
        local r = results[i]
        local key = r and r.itemKey
        local iid = key and key.itemID
        local unit = r and r.minPrice
        got = got + 1

        -- iid 为 0 / nil 的条目是「没有物品数据」的脏数据（Auctionator 也遇到过），跳过
        if type(iid) == "number" and iid > 0
           and type(unit) == "number" and unit > 0 then
            local rec = items[iid]
            if not rec then
                if kinds < MAX_ITEMS then
                    items[iid] = {
                        u  = unit,                     -- 最低单价（铜）
                        n  = tonumber(r.totalQuantity) or 1,  -- 可买总量
                        nm = nameOf(iid),              -- 物品名（可能为 nil，后面补）
                    }
                    kinds = kinds + 1
                end
            else
                -- 同一物品可能出现在多批里（含装备类不同装等），取更低的价
                if unit < rec.u then rec.u = unit end
                local q = tonumber(r.totalQuantity) or 0
                if q > 0 then rec.n = (rec.n or 0) + q end
                if not rec.nm then rec.nm = nameOf(iid) end
            end
        end
    end

    state.got   = got
    state.kinds = kinds
    state.pages = state.pages + 1
    state.lastGot = time()
end

nextPage = function()
    if state.phase ~= "browsing" then return end

    if state.pages >= MAX_PAGES then
        diag("lastResult", "page-limit")
        finishScan()
        return
    end

    local okFull, full = pcall(C_AuctionHouse.HasFullBrowseResults)
    if okFull and not full then
        local okReq = pcall(C_AuctionHouse.RequestMoreBrowseResults)
        if not okReq then
            diag("lastResult", "request-more-failed")
            finishScan()
        end
    else
        finishScan()
    end
end

finishScan = function()
    if state.items == nil then
        state.phase = "idle"
        return
    end

    local a = ahdb()
    local items = state.items
    -- 注意：state.kinds 是增量维护的，不要在这里再遍历一次（上万种物品）
    local kinds = state.kinds or 0

    a.lastScanTs = time()
    a.source     = "browse"
    a.rawCount   = state.got
    a.itemCount  = kinds
    a.pages      = state.pages
    a.skipped    = 0
    a.items      = items
    -- 登记进物品目录：分类（classID/subclassID）是即时接口，马上就有；
    -- 名字能读到就顺手写进去，读不到的交给后面的补全队列。
    if ns.Catalog and ns.Catalog.Ingest then
        local okIng, nNew = pcall(ns.Catalog.Ingest, items, "u")
        if okIng and nNew and nNew > 0 then
            diag("lastNewCatalog", nNew)
        end
    end
    a.realm      = (GetRealmName and GetRealmName()) or ""
    a.faction    = (UnitFactionGroup and UnitFactionGroup("player")) or ""
    a.addonVer   = (ns.VERSION or "")

    diag("lastResult", kinds > 0 and "ok" or "empty")
    diag("lastNumItems", state.got)
    diag("lastKinds", kinds)
    diag("lastPages", state.pages)

    if kinds <= 0 then
        state.phase = "idle"
        state.items = nil
        msg("扫描结束但没读到任何商品 —— 拍卖行界面关得太快，或者接口结构变了。")
        return
    end

    msg(string.format("扫描完成：%d 批 / %d 条结果 → %d 种物品",
        state.pages, state.got, kinds))

    -- 补齐还没有名字的物品（后台，不阻塞）
    local missing = {}
    for id, rec in pairs(items) do
        if not rec.nm then missing[#missing + 1] = id end
    end
    if #missing > 0 then
        state.phase = "naming"
        state.names = missing
        state.ncur  = 0
        nameFrame:Show()
        pumpNames()
    else
        state.phase = "idle"
        msg("|cffd97757输入 /reload 或退出游戏即可落盘，看板会立刻刷新。|r")
    end
    state.items = nil
end

-- 看门狗：只在「连续 PAGE_TIMEOUT 秒没有收到任何新数据」时才判定卡住收尾。
-- 不能用固定超时 —— 大服的完整结果集要翻几十上百页，正常就要花一两分钟。
local function watchdog()
    if state.phase ~= "browsing" then return end
    if time() - (state.lastGot or 0) >= PAGE_TIMEOUT then
        diag("lastResult", "timeout")
        msg("|cff9a968c拍卖行数据等超时了 —— 先收下已经读到的部分。|r")
        finishScan()
        return
    end
    C_Timer.After(5, watchdog)
end

-- 发一个「无条件」浏览查询 = 取全服全部在售。返回 true / false,原因
local function sendBrowse()
    local q = { searchString = "", sorts = {}, filters = {}, itemClassFilters = {} }
    local ok = pcall(C_AuctionHouse.SendBrowseQuery, q)
    if ok then return true end
    -- 老签名兜底：SendBrowseQuery(searchString, sorts, filters, itemClassFilters)
    ok = pcall(C_AuctionHouse.SendBrowseQuery, "", nil, nil, nil)
    if ok then return true end
    return false, "浏览查询发送失败"
end

function AH.Scan(opts)
    opts = opts or {}
    if state.phase == "browsing" then
        return false, "已在扫描中"
    end
    if state.phase == "naming" then
        -- 名字还在补，直接收尾，然后开始新扫描
        state.phase = "idle"
        state.names = nil
        nameFrame:Hide()
    end

    local okr, why = ahReady()
    if not okr then return false, why end

    local okCd, left = AH.CanScan()
    if not okCd and not opts.force then
        return false, string.format("刚刚扫过（%s），%d 秒后可以再扫一次",
                                    AH.LastScanText(), ceil(left))
    end

    state.phase = "browsing"
    state.items = {}
    state.pages = 0
    state.got   = 0
    state.kinds = 0
    state.lastGot = time()

    local a = ahdb()
    a.attempts = (a.attempts or 0) + 1
    diag("lastRequestTs", time())
    diag("lastResult", "browsing")

    if opts.silent ~= true then
        msg("开始扫描拍卖行价格…（逐批读取，期间游戏略卡属正常）")
    end

    local sent, serr = sendBrowse()
    if not sent then
        state.phase = "idle"
        state.items = nil
        diag("lastResult", "send-failed")
        diag("lastError", tostring(serr))
        return false, serr
    end

    -- 看门狗兜底：连续收不到新数据就收尾，已经读到的部分照样保留
    if C_Timer and C_Timer.After then
        C_Timer.After(PAGE_TIMEOUT, watchdog)
    end
    return true
end

--==========================================================================
-- 打开拍卖行之后的动作
--   打开拍卖行是这个接口唯一可靠的触发点：browse 查询本来就要求拍卖行
--   处于可用状态，服务器才会回数据。
--==========================================================================
function AH.OnAuctionHouseReady()
    if state.phase ~= "idle" then return end
    diag("lastPath", "browse")
    local ok, why = AH.Scan({ silent = true })
    if not ok and why then
        -- 刚扫过不算错误，不打扰玩家
        if not why:find("刚刚扫过") then msg(why) end
    end
end

--==========================================================================
-- 拍卖行面板上的实体按钮（照抄 Auctionator 的思路：挂成 AuctionHouseFrame 的
-- 子控件，随拍卖行一起显示/隐藏）。点一下就重扫，且可以拖动，位置会记住。
--==========================================================================
local function buildButton()
    if AH.button then return AH.button end
    if not AuctionHouseFrame then return nil end

    local b = CreateFrame("Button", "ForLeiJunAHButton", UIParent)
    b:SetSize(126, 24)
    b:SetFrameStrata("HIGH")
    b:SetClampedToScreen(true)

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.35, 0.19, 0.13, 0.95)
    b.bg = bg

    local border = b:CreateTexture(nil, "BORDER")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0.85, 0.47, 0.34, 0.9)
    b.border = border

    local fs = b:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(GameFontHighlightSmall or GameFontNormalSmall)
    fs:SetPoint("CENTER", 0, 0)
    fs:SetText("刷新周报价格")
    b.label = fs

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("刷新周报拍卖行价格", 1, 1, 1)
        GameTooltip:AddLine("浏览式全量扫描，没有 15 分钟冷却。", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("不会自动扫，想更新就点这里。", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Ctrl+拖动可以挪位置。", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    b:SetScript("OnClick", function(self)
        if IsControlKeyDown and IsControlKeyDown() then return end
        if state.phase == "browsing" then
            msg("正在扫描中…")
            return
        end
        local ok, why = AH.Scan({ force = true })
        if not ok and why then msg(why) end
    end)

    -- Ctrl+拖动挪位置，位置存进 db
    b:RegisterForDrag("LeftButton")
    b:SetMovable(true)
    b:SetScript("OnDragStart", function(self)
        if IsControlKeyDown and IsControlKeyDown() then self:StartMoving() end
    end)
    b:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local a = ahdb()
        a.btn = { self:GetLeft(), self:GetTop() }
    end)

    -- 默认位置：飘在拍卖行窗口正上方
    local a = ahdb()
    if type(a.btn) == "table" and a.btn[1] and a.btn[2] then
        b:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", a.btn[1], a.btn[2])
    else
        b:SetPoint("BOTTOMLEFT", AuctionHouseFrame, "TOPLEFT", 4, 8)
    end

    b:Hide()
    AH.button = b
    return b
end

local function showButton()
    local b = buildButton()
    if b then b:Show() end
end

local function hideButton()
    if AH.button then AH.button:Hide() end
end

--==========================================================================
-- 触发时机
--==========================================================================
AH.frame = CreateFrame("Frame")
local f = AH.frame

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("AUCTION_HOUSE_SHOW")
f:RegisterEvent("AUCTION_HOUSE_CLOSED")
f:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
f:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
f:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
f:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
f:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")
-- ★ v0.9.16 真机修复 ★ 这里原本写的是 AUCTION_HOUSE_THROTTLED_MESSAGE_SYSTEM_READY。
--   客户端里**根本没有这个名字** —— 它叫 AUCTION_HOUSE_THROTTLED_SYSTEM_READY
--   （没有中间的 MESSAGE_；带 MESSAGE_ 的是 DROPPED / QUEUED / SENT /
--    RESPONSE_RECEIVED 这一族，唯独 SYSTEM_READY 不带）。
--
--   代价远不止「少收一个事件」：RegisterEvent 收到客户端不认识的名字会**当场抛错**，
--   而这行是**顶层代码**（不在任何函数里），于是整个 Auction.lua 的 chunk
--   从这一行开始被中止 —— 本文件在这行**之后**的内容全部没执行：
--     · 第 584 行那个 RegisterEvent（AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED）
--     · f:SetScript("OnEvent", ...) —— 事件帧建了、前 8 个事件也注册上了，
--       但**处理器没接上**，所以那些事件触发了也什么都不干
--     · AH.Command —— /wb ah 系列命令全都没注册
--     · 文件尾的 ns._mark("Auction.lua") —— 所以自诊断轨迹里缺它一个
--   结果就是「拍卖行扫描静默失效」：错误只写进 Logs/General.log，
--   而 _diag.errors 抓不到它（错误钩子是 PLAYER_LOGIN 才挂上的，那时文件早加载完了），
--   表现只是「市场价格快照永远不更新、/wb ah 没反应」。
--
--   怎么抓到的（证据链，供以后再遇到同类问题时复用）：
--     ① 存档 _diag.load 只有 11 条，**独缺 Auction.lua**，而它在 toc 里排第 7；
--     ② 轨迹里 Auction 之后的 Mail/Professions/Route/UI/DashboardUI **都在**
--        → 说明 WoW **不会**因为某个文件加载报错就停掉后面的文件
--        （这点很反直觉，之前注释里写反了，见 Core.lua 自诊断段的更正）；
--     ③ General.log 里每次开游戏都报一条
--        `[string "Auction.lua"]:580: Attempt to register unknown event
--         "AUCTION_HOUSE_THROTTLED_MESSAGE_SYSTEM_READY"`
--        （上一轮我按全路径 "Interface/AddOns/WeeklyBoard/" 过滤找错，
--          而这消息里只有裸文件名，于是整条被漏掉、还误判成别的插件的错）；
--     ④ 从客户端可执行文件里 strings 出全部事件名，逐一对表 —— 28 个里只有这 1 个不存在。
--   已加 tools/check_events.py 做全量离线校验（零成本、一秒出结果，见 README）。
f:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
f:RegisterEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")

f:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_LOGIN" then
        ahdb()
        nameCache()

    elseif event == "AUCTION_HOUSE_SHOW" then
        -- ★ v0.9.31 规则变更（2026-10-18 用户拍板，lite v1.3.4 同步）★
        --   打开拍卖行**不再自动扫描**。原来是为了数据新鲜，但全量 browse
        --   扫描会占住拍卖行的浏览查询，玩家搜东西都被拖慢 —— 正常使用
        --   优先，更新只走面板上的「刷新周报价格」按钮（force 绕过冷却）。
        diag("lastAhShowTs", time())
        showButton()

    elseif event == "AUCTION_HOUSE_CLOSED" then
        hideButton()
        if state.phase == "browsing" then
            -- 拍卖行一关，browse 结果就被客户端清空了，只能先收下已有的部分
            diag("lastResult", "closed-early")
            finishScan()
        end

    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        -- 现代客户端的拍卖行开关事件（Auctionator 用的就是这个）
        local isAuctioneer = (Enum and Enum.PlayerInteractionType
                              and arg1 == Enum.PlayerInteractionType.Auctioneer)
        if isAuctioneer then
            diag("lastAhShowTs", time())
            showButton()
        end

    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        local isAuctioneer = (Enum and Enum.PlayerInteractionType
                              and arg1 == Enum.PlayerInteractionType.Auctioneer)
        if isAuctioneer then hideButton() end

    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        -- 只在「本次扫描还没收到任何数据」时才把 UPDATED 当成新一轮的开始。
        -- 否则忽略：扫描中途别的插件/拍卖行界面做定向搜索会把结果集合换掉，
        -- 那种事件不该让我们把已经读到的几万条丢掉重来。
        if state.phase ~= "browsing" or state.pages > 0 then return end
        diag("lastEventTs", time())
        local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
        if ok and type(results) == "table" and #results > 0 then
            absorb(results)
            nextPage()
        end

    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        if state.phase ~= "browsing" then return end
        diag("lastEventTs", time())
        local added = arg1
        if type(added) ~= "table" then
            -- 事件没带数据就自己从结果集里取增量（跳过已经吸收过的前 state.got 条）
            local ok, all = pcall(C_AuctionHouse.GetBrowseResults)
            if ok and type(all) == "table" and #all > state.got then
                added = {}
                for i = state.got + 1, #all do added[#added + 1] = all[i] end
            end
        end
        absorb(added)
        nextPage()

    elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
        if state.phase == "browsing" then
            diag("lastResult", "browse-failure")
            msg("|cff9a968c拍卖行的浏览查询被服务器拒了 —— 稍后再试一次。|r")
            state.phase = "idle"
            state.items = nil
        end

    elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
        if state.phase == "browsing" then
            diag("lastResult", "throttled-dropped")
            msg("|cff9a968c请求发得太密被服务器丢了 —— 过一会儿再试。|r")
            state.phase = "idle"
            state.items = nil
        end

    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        -- 名字必须和上面 RegisterEvent 用的完全一致（v0.9.16 修过一次拼写）：
        -- 写错的话这里会变成一段永远不成立的死分支，而且**不报任何错** ——
        -- 比加载期报错更难发现。tools/check_events.py 会连这类字面量一起校验。
        diag("lastThrottleReadyTs", time())
    end
end)

--==========================================================================
-- 命令：/wb ah 系列（由 UI.lua 转过来）
--==========================================================================
function AH.Command(rest)
    local a = ahdb()
    rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

    if rest == "" or rest == "status" then
        msg("拍卖行快照状态")
        msg("  上次采集：" .. AH.LastScanText())
        msg("  来源：浏览式全量扫描（Browse 路径，无 15 分钟冷却）")
        msg(string.format("  结果 %d 条 · %d 批 → %d 种物品",
            a.rawCount or 0, a.pages or 0, a.itemCount or 0))
        if a.namesMissing and a.namesMissing > 0 then
            msg("  还有 " .. a.namesMissing .. " 种物品缺名字，下次扫描补")
        end
        msg("  服务器：" .. tostring(a.realm or "?") .. " · 阵营：" .. tostring(a.faction or "?"))
        msg("|cff9a968c  打开拍卖行不会自动扫（不打扰你用拍卖行）；想更新就点面板上的「刷新周报价格」按钮。|r")

    elseif rest == "diag" then
        local d = a.diag or {}
        msg("拍卖行采集诊断")
        msg("  发起扫描：" .. tostring(a.attempts or 0) .. " 次")
        msg("  最后请求时间：" .. (d.lastRequestTs and date("%m-%d %H:%M:%S", d.lastRequestTs) or "从未发出"))
        msg("  收到数据事件：" .. (d.lastEventTs and date("%m-%d %H:%M:%S", d.lastEventTs) or "从未收到"))
        msg("  拍卖行打开：" .. (d.lastAhShowTs and date("%m-%d %H:%M:%S", d.lastAhShowTs) or "本次会话没打开过"))
        msg("  最后结果：" .. tostring(d.lastResult or "—"))
        if d.lastPages then msg("  收到批次：" .. tostring(d.lastPages)) end
        if d.lastError then msg("  错误：" .. tostring(d.lastError)) end

    elseif rest == "scan" or rest == "now" then
        local ok, why = AH.Scan({ silent = false })
        if not ok then msg(why or "无法扫描") end

    elseif rest == "force" then
        local ok, why = AH.Scan({ silent = false, force = true })
        if not ok then msg(why or "无法扫描") end

    elseif rest:match("^top") then
        local n = tonumber(rest:match("^top%s*(%d+)")) or 15
        local list = {}
        for id, r in pairs(a.items or {}) do
            list[#list + 1] = { id = id, u = r.u or 0, n = r.n or 0, nm = r.nm }
        end
        table.sort(list, function(x, y) return x.u > y.u end)
        msg("当前单价最高的 " .. n .. " 种物品（全服最低一口价）")
        for i = 1, min(n, #list) do
            local e = list[i]
            msg(string.format("  %-28s %8s 金 · 在售 %d 个",
                (e.nm or ("物品#" .. e.id)):sub(1, 28),
                string.format("%.2f", e.u / 10000), e.n))
        end

    elseif rest == "clear" then
        a.items = {}
        a.itemCount, a.rawCount, a.lastScanTs, a.source = 0, 0, 0, nil
        msg("已清空拍卖行快照")

    else
        msg("用法：/wb ah [status | diag | scan | force | top 20 | clear]")
    end
end

-- 自诊断：把「本文件加载成功」记进 ns._mark 的内存轨迹。
--   别删 —— 加载期报错会让本文件**从出错那行起**的后续代码全不执行
--   （注意：**不影响别的文件**。WoW 每个 .lua 独立成一段 chunk，报错只中止这一段。
--    这点最初写反了，已在 Core.lua 自诊断段更正）。
--   轨迹的正确读法：出现名字 = 这个文件走到底了；**缺谁就是谁在加载期挂了**。
--   实证：v0.9.15 时 Auction.lua 因事件名拼错在顶层抛错，轨迹里正好缺它一个。
if ns._mark then ns._mark("Auction.lua") end
