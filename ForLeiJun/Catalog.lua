-- 本文件由 tools/build_lite.py 从 ../WeeklyBoard/Catalog.lua 同步生成，请勿手改。
-- 改动请改源文件后重跑：python3 tools/build_lite.py
--[[--------------------------------------------------------------------------
    ForLeiJun / Catalog.lua
    物品知识库 + 背包/银行库存 + 关注清单

    ── 为什么需要这一层 ──────────────────────────────────────────────────
    拍卖行快照能给到「2.5 万种物品 × 价格」，但那是给机器看的原始数据。
    看板要回答的是「我该卖什么、该刷什么材料」，这需要三样东西：

      1) 物品的名字 + 分类
         —— 没有名字，搜索框就是个摆设（实测 25513 种物品 0 个名字）；
            没有分类，就没法「只看材料」这种筛法。
      2) 我背包和银行里有什么
         —— 否则算不出「我手头的货值多少钱」，看板就只是个价格浏览器。
      3) 一份关注清单
         —— 2.5 万行里，真正和你有关的可能就几十个。

    ── 关键实现取舍 ──────────────────────────────────────────────────────
    * 分类（classID / subclassID）用 C_Item.GetItemInfoInstant 取：
      这个接口**不需要物品数据加载完成**，立刻就能拿到。所以「按分类浏览」
      在第一次扫描后马上可用，不用等名字补全。

    * 名字必须异步：C_Item.RequestLoadItemDataByID → ITEM_DATA_LOAD_RESULT。
      2.5 万条要跑一两分钟，所以做成**分批慢跑 + 单次会话上限**，
      并且**按价格从高到低排队** —— 先补贵的，先补你真正会看的。

    * 背包/银行的容器号：
        0 = 主背包，1..NUM_BAG_SLOTS = 皮包，NUM_BAG_SLOTS+1 = 试剂袋
        个人银行：11.0 起银行改成了「标签页」，容器号要从
          Enum.BagIndex.CharacterBankTab_1..9 拿（老客户端才是 -1 + 数字段）；
        **战团银行（Enum.BagIndex.AccountBankTab_*）是账号共享的，必须单独扫**：
          老写法用「银行主格后面跟 N 个数字」，正好把战团银行的容器也圈进去，
          于是同一个账号仓库被每个开过银行的角色各记一遍（实测：906 暗月火酒
          被四个角色各扫一次 → 看板显示 3624，虚高 4 倍）。
      银行容器**只有打开银行时才能读**（否则槽位数返回 0），所以银行只在
      BANKFRAME_OPENED 时扫，且「扫到 0 格就不覆盖旧数据」——
      避免你路过银行扫一次、之后在野外卖东西，银行那部分凭空消失。

    ── 数据结构（写进 ForLeiJunDB） ────────────────────────────────────
      DB.cat = {
        n   = { [itemID] = "物品名" },
        c   = { [itemID] = classID },
        s   = { [itemID] = subclassID },
        q   = { [itemID] = quality },       -- 0..7
        p   = { [itemID] = 参考单价(铜) },   -- 只用于「补名字」的优先级排序
        cls = { [classID] = "商品" },        -- 本地化分类名
        sub = { ["7:9"] = "草药" },          -- 本地化子类名
      }
      DB.bag = { chars = { ["服务器|角色"] = {
                    pocket = {[id]=数量}, pocketTs = ts,
                    bank   = {[id]=数量}, bankTs   = ts } },   -- bank = 个人银行，不含战团
                 warband = { items = {[id]=数量}, itemsTs = ts } }  -- 账号共享，只一份
      DB.watch = { [itemID] = true }
--------------------------------------------------------------------------]]

local ADDON, ns = ...

ns.Catalog = ns.Catalog or {}
local C = ns.Catalog

local time, type, pairs, ipairs, pcall, tostring, tonumber, floor, min, max, sort =
      time, type, pairs, ipairs, pcall, tostring, tonumber, math.floor, math.min, math.max, table.sort

-- 可按需调：名字补全的节奏
local NAME_STEP    = 80     -- 每批请求多少个 itemID
local NAME_TICK    = 0.30   -- 批次间隔（秒）
local SESSION_CAP  = 9000   -- 单次登录最多补多少个（2.5 万条约 3 次登录补完）
local BAG_DEBOUNCE = 3.0    -- 背包变动后多久才重扫

local function msg(s)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd97757[雷菌]|r " .. tostring(s))
    end
end
C.msg = msg

--==========================================================================
-- 存取
--==========================================================================
local function catdb()
    local d = ns.db()
    if type(d.cat) ~= "table" then d.cat = {} end
    local cat = d.cat
    if type(cat.n) ~= "table" then cat.n = {} end
    if type(cat.c) ~= "table" then cat.c = {} end
    if type(cat.s) ~= "table" then cat.s = {} end
    if type(cat.q) ~= "table" then cat.q = {} end
    if type(cat.p) ~= "table" then cat.p = {} end
    if type(cat.cls) ~= "table" then cat.cls = {} end
    if type(cat.sub) ~= "table" then cat.sub = {} end
    return cat
end
C.db = catdb

-- Auction.lua 的名字缓存也指向这张表，避免同一份名字存两遍
function C.NameMap()
    return catdb().n
end

function C.Watch()
    local d = ns.db()
    if type(d.watch) ~= "table" then d.watch = {} end
    return d.watch
end

local function bagdb()
    local d = ns.db()
    if type(d.bag) ~= "table" then d.bag = {} end
    if type(d.bag.chars) ~= "table" then d.bag.chars = {} end
    -- 战团银行：账号级一份，不按角色分（见文件头说明）
    if type(d.bag.warband) ~= "table" then d.bag.warband = {} end
    return d.bag
end

--==========================================================================
-- 读客户端物品信息
--==========================================================================
-- GetItemInfoInstant 是即时接口：不需要物品数据加载完成。
-- 期望返回 itemID, itemType, itemSubType, itemEquipLoc, icon, classID, subclassID
-- 但补丁间位置偶有变动，所以用「小整数」特征来定位 classID（icon 是六位大数）。
local function instant(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f then return nil end
    local ok, r1, r2, r3, r4, r5, r6, r7 = pcall(f, id)
    if not ok then return nil end
    local v = { r1, r2, r3, r4, r5, r6, r7 }
    for i = 7, 5, -1 do
        local cv = v[i]
        if type(cv) == "number" and cv >= 0 and cv <= 30 then
            local sv = v[i + 1]
            if type(sv) ~= "number" or sv < 0 or sv > 300 then sv = 0 end
            return cv, sv
        end
    end
    return nil
end

-- 物品名 / 品质：只有数据加载完成才有
local function loaded(id)
    local n, q
    if GetItemInfo then
        local ok, name, _link, quality = pcall(GetItemInfo, id)
        if ok then n, q = name, quality end
    end
    if (type(n) ~= "string" or n == "") and C_Item and C_Item.GetItemNameByID then
        local ok, name = pcall(C_Item.GetItemNameByID, id)
        if ok and type(name) == "string" and name ~= "" then n = name end
    end
    if type(n) ~= "string" or n == "" then return nil end
    if type(q) ~= "number" then q = nil end
    if #n > 60 then n = n:sub(1, 60) end
    return n, q
end

local function className(classID)
    local cat = catdb()
    local v = cat.cls[classID]
    if v then return v end
    local n
    local f = GetItemClassInfo or (C_Item and C_Item.GetItemClassInfo)
    if f then
        local ok, s = pcall(f, classID)
        if ok and type(s) == "string" and s ~= "" then n = s end
    end
    if not n then n = "分类" .. tostring(classID) end
    cat.cls[classID] = n
    return n
end

local function subclassName(classID, subclassID)
    local cat = catdb()
    local k = classID .. ":" .. subclassID
    local v = cat.sub[k]
    if v then return v end
    local n
    local f = GetItemSubClassInfo or (C_Item and C_Item.GetItemSubClassInfo)
    if f then
        local ok, s = pcall(f, classID, subclassID)
        if ok and type(s) == "string" and s ~= "" then n = s end
    end
    cat.sub[k] = n or ""
    return cat.sub[k]
end

--==========================================================================
-- 登记一个物品：分类即时写入，名字能拿到就写，拿不到就交给补全队列
--==========================================================================
function C.Note(id, price)
    id = tonumber(id)
    if not id or id <= 0 then return end
    local cat = catdb()

    if cat.c[id] == nil then
        local cid, sid = instant(id)
        if cid then
            cat.c[id] = cid
            cat.s[id] = sid or 0
            className(cid)
            subclassName(cid, sid or 0)
        end
    end

    if cat.n[id] == nil then
        local n, q = loaded(id)
        if n then
            cat.n[id] = n
            if q then cat.q[id] = q end
        end
    end

    if price and price > 0 then cat.p[id] = price end
end

--==========================================================================
-- 扫描结束后：把整张价格表登记进目录，然后开始补名字
--==========================================================================
function C.Ingest(items, priceKey)
    if type(items) ~= "table" then return 0 end
    local cat = catdb()
    local n = 0
    for id, rec in pairs(items) do
        id = tonumber(id)
        if id and id > 0 then
            local cid = cat.c[id]
            local nm  = cat.n[id]
            local p   = (type(rec) == "table" and tonumber(rec[priceKey or "u"])) or nil
            if cid == nil or nm == nil then
                C.Note(id, p)
                n = n + 1
            elseif p and p > 0 then
                cat.p[id] = p
            end
        end
    end
    return n
end

--==========================================================================
-- 名字补全（后台慢跑）
--==========================================================================
local pump = { running = false, queue = nil, cur = 0, done = 0 }

local frame = CreateFrame("Frame")
frame:Hide()
frame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
frame:SetScript("OnEvent", function(_, _, itemID)
    if type(itemID) ~= "number" or itemID <= 0 then return end
    local cat = catdb()
    if cat.n[itemID] ~= nil then return end
    local n, q = loaded(itemID)
    if n then
        cat.n[itemID] = n
        if q then cat.q[itemID] = q end
    end
end)
C.frame = frame

local function step()
    if not pump.running then return end
    local cat = catdb()
    local q = pump.queue

    if not q or pump.cur > #q or pump.done >= SESSION_CAP then
        pump.running = false
        pump.queue = nil
        frame:Hide()
        local left = 0
        for id in pairs(cat.c) do
            if cat.n[id] == nil then left = left + 1 end
        end
        cat.missing = left
        cat.ts = time()
        local added = pump.done
        pump.done = 0
        if added > 0 then
            msg(string.format("已补 %d 个物品名%s", added,
                left > 0 and ("（还剩 " .. left .. " 个，下次登录继续）") or "（已全部补齐）"))
        end
        return
    end

    local stop = min(pump.cur + NAME_STEP - 1, #q)
    local cnt = 0
    for i = pump.cur, stop do
        if pcall(C_Item.RequestLoadItemDataByID, q[i]) then cnt = cnt + 1 end
    end
    pump.cur  = stop + 1
    pump.done = pump.done + cnt
    if C_Timer and C_Timer.After then
        C_Timer.After(NAME_TICK, step)
    end
end

-- 开始补名字。优先级：参考单价从高到低（先补你真正会看的），同价按 ID。
function C.Pump(quiet)
    if pump.running then return end
    local cat = catdb()
    local q = {}
    for id in pairs(cat.c) do
        if cat.n[id] == nil then q[#q + 1] = id end
    end
    if #q == 0 then
        cat.missing = 0
        cat.ts = time()
        if not quiet then msg("物品名已全部补齐。") end
        return
    end
    sort(q, function(a, b)
        local pa, pb = cat.p[a] or 0, cat.p[b] or 0
        if pa ~= pb then return pa > pb end
        return a < b
    end)
    pump.running = true
    pump.queue   = q
    pump.cur     = 0
    pump.done    = 0
    frame:Show()
    if not quiet then
        msg(string.format("开始补物品名：待补 %d 个，这次先补 %d 个（后台慢跑，不卡）",
            #q, min(#q, SESSION_CAP)))
    end
    step()
end

function C.Busy()
    return pump.running
end

function C.Stats()
    local cat = catdb()
    local total, named = 0, 0
    for id in pairs(cat.c) do
        total = total + 1
        if cat.n[id] then named = named + 1 end
    end
    return { total = total, named = named, missing = total - named,
             classes = cat.cls, subs = cat.sub, ts = cat.ts }
end

--==========================================================================
-- 背包 / 银行
--==========================================================================
local function containerSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then
        local ok, n = pcall(C_Container.GetContainerNumSlots, bag)
        if ok and type(n) == "number" then return n end
    end
    if GetContainerNumSlots then
        local ok, n = pcall(GetContainerNumSlots, bag)
        if ok and type(n) == "number" then return n end
    end
    return 0
end

local function scanContainer(bag, out)
    local slots = containerSlots(bag)
    if slots <= 0 then return 0 end
    local found = 0
    for slot = 1, slots do
        local iid, cnt, bound

        if C_Container and C_Container.GetContainerItemInfo then
            local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
            if ok and type(info) == "table" then
                iid   = info.itemID
                cnt   = info.stackCount
                bound = info.isBound
            end
        end
        if not iid and GetContainerItemID then
            local ok, v = pcall(GetContainerItemID, bag, slot)
            if ok and type(v) == "number" and v > 0 then iid = v end
        end
        if not cnt and GetContainerItemInfo then
            local ok, _, c = pcall(GetContainerItemInfo, bag, slot)
            if ok and type(c) == "number" then cnt = c end
        end

        if type(iid) == "number" and iid > 0 and not bound then
            cnt = tonumber(cnt) or 1
            if cnt > 0 then
                out[iid] = (out[iid] or 0) + cnt
                found = found + 1
                C.Note(iid)
            end
        end
    end
    return found
end

-- 角色键统一走 Core 的 ns.CharKey()（v0.9.10）。
-- 这里以前返回 "服务器|角色名"（竖线），和 Core 的 "服务器-角色名" 对不上，
-- 导致 chars 与 bag.chars 是两个互不认识的键空间。现在合并成一处。
local function charKey()
    if ns.CharKey then
        local k = ns.CharKey()
        if k then return k end
    end
    -- 兜底：Core 还没加载完时（理论上不会发生，Catalog 排在 Core 之后）
    local r = (GetRealmName and GetRealmName()) or "?"
    local n = (UnitName and UnitName("player")) or "?"
    return r .. "-" .. n
end

-- 背包容器：0 = 主背包，1..NUM_BAG_SLOTS = 皮包，NUM_BAG_SLOTS+1 = 试剂袋
local function pocketBags()
    local nb = tonumber(NUM_BAG_SLOTS) or 4
    local t = { 0 }
    for i = 1, nb + 1 do t[#t + 1] = i end
    return t
end

-- 银行容器：11.0 起是标签页（Enum.BagIndex.CharacterBankTab_N），
-- 老客户端才是「-1 主格 + NUM_BANKBAGSLOTS 个包」。两套都要能跑。
-- 【重要】不能再用「-1 后面跟 N 个数字」的写法：在 11.0 客户端里那段数字
-- 空间已经被**战团银行**占用，会把账号共享的仓库算进每个角色（实测虚高 4 倍）。
local function enumTabs(prefix, maxN)
    local E = Enum and Enum.BagIndex
    local t = {}
    if not E then return t end
    for i = 1, maxN do
        local id = E[prefix .. i]
        if type(id) == "number" then t[#t + 1] = id end
    end
    return t
end

local function bankBags()
    local t, seen = {}, {}
    local function add(id)
        if id and not seen[id] then seen[id] = true; t[#t + 1] = id end
    end
    add(tonumber(BANK_CONTAINER) or -1)
    local tabs = enumTabs("CharacterBankTab_", 9)
    if #tabs > 0 then
        for _, id in ipairs(tabs) do add(id) end
    else
        local nb  = tonumber(NUM_BAG_SLOTS) or 4
        local nbb = tonumber(NUM_BANKBAGSLOTS) or 7
        for i = nb + 2, nb + 1 + nbb do add(i) end
    end
    return t
end

-- 战团银行容器（账号共享）。老客户端没有这些枚举，返回空表＝不扫。
local function warbandBags()
    return enumTabs("AccountBankTab_", 9)
end

function C.ScanBags(which)
    which = which or "auto"
    local d = bagdb()
    local key = charKey()
    if type(d.chars[key]) ~= "table" then d.chars[key] = {} end
    local rec = d.chars[key]
    local report = {}

    if which == "auto" or which == "pocket" then
        local out, hits = {}, 0
        for _, bag in ipairs(pocketBags()) do
            hits = hits + scanContainer(bag, out)
        end
        rec.pocket = out
        rec.pocketTs = time()
        d.ts = rec.pocketTs
        report.pocket = hits
    end

    if which == "auto" or which == "bank" then
        local out, hits = {}, 0
        local readable = false
        for _, bag in ipairs(bankBags()) do
            if containerSlots(bag) > 0 then
                readable = true
                hits = hits + scanContainer(bag, out)
            end
        end
        -- 银行没开时槽位数是 0：这时**不覆盖**旧数据
        if readable then
            rec.bank = out
            rec.bankTs = time()
            d.ts = rec.bankTs
            report.bank = hits
        else
            report.bank = nil
        end
    end

    -- 战团银行：账号共享 → 写账号级一份（d.bag.warband.items），不挂到角色上
    if which == "auto" or which == "warband" then
        local tabs = warbandBags()
        if #tabs > 0 then
            local out, hits, readable = {}, 0, false
            for _, bag in ipairs(tabs) do
                if containerSlots(bag) > 0 then
                    readable = true
                    hits = hits + scanContainer(bag, out)
                end
            end
            if readable then
                d.warband.items = out
                d.warband.itemsTs = time()
                d.ts = d.warband.itemsTs
                report.warband = hits
            end
        end
    end

    return report
end

function C.BagStats()
    local d = bagdb()
    local nPocket, nBank, nWb, chars = 0, 0, 0, 0
    for _, rec in pairs(d.chars) do
        chars = chars + 1
        if type(rec.pocket) == "table" then
            for _ in pairs(rec.pocket) do nPocket = nPocket + 1 end
        end
        if type(rec.bank) == "table" then
            for _ in pairs(rec.bank) do nBank = nBank + 1 end
        end
    end
    if type(d.warband.items) == "table" then
        for _ in pairs(d.warband.items) do nWb = nWb + 1 end
    end
    return { chars = chars, pocketKinds = nPocket, bankKinds = nBank,
             warbandKinds = nWb, ts = d.ts }
end

--==========================================================================
-- 关注清单
--==========================================================================
function C.WatchAdd(id)
    id = tonumber(id)
    if not id or id <= 0 then return false end
    C.Note(id)
    C.Watch()[id] = true
    return true
end

function C.WatchRemove(id)
    id = tonumber(id)
    if not id then return false end
    C.Watch()[id] = nil
    return true
end

function C.WatchHas(id)
    return C.Watch()[tonumber(id)] == true
end

function C.WatchCount()
    local n = 0
    for _ in pairs(C.Watch()) do n = n + 1 end
    return n
end

--==========================================================================
-- 触发时机
--==========================================================================
local ev = CreateFrame("Frame")
local bagDue = {}   -- which -> 计划执行的时刻，用来对高频事件去重

local function scheduleBagScan(which, delay)
    which = which or "pocket"
    if not (C_Timer and C_Timer.After) then
        C.ScanBags(which)
        return
    end
    local due = time() + (delay or BAG_DEBOUNCE)
    bagDue[which] = due
    C_Timer.After((delay or BAG_DEBOUNCE) + 0.05, function()
        -- 期间又有新事件把时间推后了，就交给那一次去做
        if bagDue[which] ~= due then return end
        bagDue[which] = nil
        C.ScanBags(which)
    end)
end

ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("BANKFRAME_OPENED")
ev:RegisterEvent("PLAYER_MONEY")

ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        catdb(); bagdb(); C.Watch()

        -- v0.5.0 起物品名统一放在 cat.n（Auction 模块的 nameCache 也指过来），
        -- 把旧版存在 ah.names 里的名字搬过来，别白扔也别存两份。
        local d = ns.db()
        local old = (type(d.ah) == "table") and d.ah.names
        if type(old) == "table" then
            local names = catdb().n
            local moved = 0
            for id, n in pairs(old) do
                if type(n) == "string" and n ~= "" and names[id] == nil then
                    names[id] = n
                    moved = moved + 1
                end
            end
            d.ah.names = nil
            if moved > 0 then
                msg("已把 " .. moved .. " 个物品名从旧缓存迁进物品目录。")
            end
        end

        -- 继续补上一轮没补完的物品名
        if C_Timer and C_Timer.After then
            C_Timer.After(6, function() C.Pump(true) end)
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        scheduleBagScan("pocket", 5)

    elseif event == "BAG_UPDATE_DELAYED" then
        scheduleBagScan("pocket", BAG_DEBOUNCE)

    elseif event == "BANKFRAME_OPENED" then
        -- 银行开着的时候顺便把背包也重扫一遍（这时两个都读得到）
        scheduleBagScan("auto", 2)

    elseif event == "PLAYER_MONEY" then
        -- 金币变动常常伴随买卖，顺手重算一次背包
        scheduleBagScan("pocket", BAG_DEBOUNCE)
    end
end)

C.events = ev

--==========================================================================
-- 命令：/wb watch /wb bag /wb cat
--==========================================================================
local function itemIDFromToken(tok)
    tok = tostring(tok or "")
    local id = tonumber(tok)
    if id and id > 0 then return id end
    id = tonumber(tok:match("item:(%d+)"))
    if id then return id end
    if GetItemInfoFromHyperlink then
        local ok, v = pcall(GetItemInfoFromHyperlink, tok)
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return nil
end

function C.Command(sub, rest)
    local w = C.Watch()

    if sub == "watch" then
        rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local act, arg = rest:match("^(%S*)%s*(.*)$")

        if act == "" or act == "list" then
            local ids = {}
            for id in pairs(w) do ids[#ids + 1] = id end
            table.sort(ids)
            msg("关注清单：共 " .. #ids .. " 个物品")
            if #ids == 0 then
                msg("|cff9a968c  加物品：/wb watch add <物品链接或ID>（shift+点击物品可直接贴链接）|r")
                return
            end
            local cat = catdb()
            for i = 1, min(#ids, 30) do
                local id = ids[i]
                local p = cat.p[id]
                msg(string.format("  %-26s %s",
                    (cat.n[id] or ("物品#" .. id)):sub(1, 26),
                    p and string.format("%.2f 金", p / 10000) or "无价格"))
            end
            if #ids > 30 then msg("  …另有 " .. (#ids - 30) .. " 个（看板里看全）") end

        elseif act == "add" then
            local id = itemIDFromToken(arg)
            if not id then msg("用法：/wb watch add <物品链接或ID>") return end
            C.WatchAdd(id)
            msg("已关注：" .. (catdb().n[id] or ("物品#" .. id)))

        elseif act == "remove" or act == "rm" then
            local id = itemIDFromToken(arg)
            if not id then msg("用法：/wb watch remove <物品链接或ID>") return end
            C.WatchRemove(id)
            msg("已取消关注：" .. (catdb().n[id] or ("物品#" .. id)))

        elseif act == "clear" then
            ns.db().watch = {}
            msg("已清空关注清单")

        else
            msg("用法：/wb watch [list | add <链接/ID> | remove <链接/ID> | clear]")
        end
        return
    end

    if sub == "bag" then
        local r = C.ScanBags(rest == "bank" and "bank" or (rest == "pocket" and "pocket"
                          or (rest == "warband" and "warband" or "auto")))
        local s = C.BagStats()
        msg("库存快照")
        if r.pocket then msg("  背包：可交易物品 " .. r.pocket .. " 格 → " .. s.pocketKinds .. " 种") end
        if r.bank ~= nil then
            msg("  个人银行：可交易物品 " .. r.bank .. " 格 → " .. s.bankKinds .. " 种")
        else
            msg("|cff9a968c  个人银行：没打开过银行，读到 0 格，本次不覆盖旧数据|r")
        end
        if r.warband then
            msg("  战团银行：可交易物品 " .. r.warband .. " 格 → " .. s.warbandKinds .. " 种（账号共享，只算一次）")
        elseif s.warbandKinds > 0 then
            msg("|cff9a968c  战团银行：本次没读到（没开银行或没买标签页），沿用上次快照|r")
        end
        msg("|cff9a968c  看板会把「数量 × 拍卖行单价」算成你的库存市值。|r")
        msg("|cff9a968c  /reload 或退出游戏后落盘生效。|r")
        return
    end

    if sub == "cat" or sub == "items" then
        if rest == "pump" then
            C.Pump(false)
            return
        end
        local s = C.Stats()
        local ncls = 0
        for _ in pairs(s.classes) do ncls = ncls + 1 end
        msg("物品目录")
        msg(string.format("  已登记 %d 种 · 有名字 %d 种 · 待补 %d 种",
            s.total, s.named, s.missing))
        msg("  已识别 " .. ncls .. " 个大类")
        if s.missing > 0 then
            msg("|cffe8e4dc  /wb cat pump|r 立刻开始补名字（后台慢跑）")
        end
        return
    end

    msg("用法：/wb watch | /wb bag | /wb cat")
end

-- 自诊断：把「本文件加载成功」记进 ns._mark 的内存轨迹。
--   别删 —— 加载期报错会让本文件**从出错那行起**的后续代码全不执行
--   （注意：**不影响别的文件**。WoW 每个 .lua 独立成一段 chunk，报错只中止这一段。
--    这点最初写反了，已在 Core.lua 自诊断段更正）。
--   轨迹的正确读法：出现名字 = 这个文件走到底了；**缺谁就是谁在加载期挂了**。
--   实证：v0.9.15 时 Auction.lua 因事件名拼错在顶层抛错，轨迹里正好缺它一个。
if ns._mark then ns._mark("Catalog.lua") end
