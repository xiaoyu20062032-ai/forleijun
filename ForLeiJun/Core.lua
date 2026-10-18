-- 本文件由 tools/build_lite.py 从 ../WeeklyBoard/Core.lua 同步生成，请勿手改。
-- 改动请改源文件后重跑：python3 tools/build_lite.py
--[[--------------------------------------------------------------------------
    ForLeiJun / Core.lua
    采集当前角色的每周进度快照，写入账号级 SavedVariables (ForLeiJunDB)。
    本地 Python 脚本再把 SavedVariables 解析成 JSON，生成 HTML 看板。

    设计原则：
      * 所有暴雪 API 调用都包在 pcall 里 —— 某个接口在某个补丁被改掉时，
        插件不会报错，只是对应字段为空，看板照常出。
      * 只采「当前登录角色」的数据（客户端限制，无法读取其他角色的实时状态），
        每个角色登录一次即完成一次快照，账号级保存后自动汇总。
--------------------------------------------------------------------------]]

local ADDON, ns = ...
ns.ADDON = ADDON
ns.VERSION = "0.9.40"

local date, time, pcall, type, ipairs, pairs, tostring, floor, max, min, sort =
      date, time, pcall, type, ipairs, pairs, tostring, math.floor, math.max, math.min, table.sort

local WEEK_SECONDS = 7 * 24 * 60 * 60

-- 安全调用：失败返回 nil，绝不抛错
local function S(f, ...)
    if type(f) ~= "function" then return nil end
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end
ns.S = S

local function num(v)
    if type(v) == "number" then return v end
    return 0
end
ns.num = num

--==========================================================================
-- 时间：本周区间
--==========================================================================
function ns.GetWeek()
    local left = 0
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
        local v = S(C_DateAndTime.GetSecondsUntilWeeklyReset)
        if type(v) == "number" and v >= 0 then left = v end
    end
    local now = time()
    local nextReset = now + left
    local weekStart = nextReset - WEEK_SECONDS
    return {
        now         = now,
        weekStart   = weekStart,
        nextReset   = nextReset,
        key         = date("%Y-%m-%d", weekStart),
        resetKey    = date("%Y-%m-%d", nextReset),
        secondsLeft = left,
        leftText    = ns.FormatDuration(left),
    }
end

function ns.FormatDuration(sec)
    sec = num(sec)
    local d = floor(sec / 86400)
    local h = floor((sec % 86400) / 3600)
    local m = floor((sec % 3600) / 60)
    if d > 0 then return d .. "天" .. h .. "小时" end
    if h > 0 then return h .. "小时" .. m .. "分" end
    return m .. "分"
end

--==========================================================================
-- DB 初始化
--==========================================================================
local function db()
    if type(ForLeiJunDB) ~= "table" then ForLeiJunDB = {} end
    local d = ForLeiJunDB
    d.schema = 1
    d.version = d.version or ns.VERSION
    d.chars = d.chars or {}
    d.history = d.history or {}
    d.rewardCache = d.rewardCache or {}
    -- 账号级世界任务池：世界任务对所有角色一致，单独存一份
    if type(d.wqPool) ~= "table" then d.wqPool = {} end
    if type(d.wqPool.entries) ~= "table" then d.wqPool.entries = {} end
    -- 世界任务奖励「永久记忆库」：qid -> { m = 铜, lvl = 记时的等级, ts = 时间 }。
    --   与上面按周清空的 rewardCache 不同，这里**跨周、跨会话、跨角色保留** ——
    --   它是治「暴雪读取世界任务限流」的核心，详见文件下方 memo 模块的说明。
    if type(d.wqMoneyMemo) ~= "table" then d.wqMoneyMemo = {} end
    -- 战团银行：账号级共享（跨角色、跨子账号），金币等通用资产存这里
    if type(d.warband) ~= "table" then d.warband = {} end
    return d
end
ns.db = db

--==========================================================================
-- 自诊断（v0.9.15，v0.9.16 更正过一处结论）
--   为什么要让插件自己记错：这次「看板一片空白」的根因只躺在
--   Logs/General.log 里，而那个文件得用户自己到磁盘上翻 —— 排查绕了一大圈。
--   更糟的是那个文件**一重启游戏就被轮转清空**（v0.9.16 就吃过：等回头去看
--   20:39 那次会话的报错时，General.log 已被 20:45 的重启清成 0 字节了）。
--   插件把「加载到哪一步」和「最近几次报错」写进自己的存档，
--   下次读 ForLeiJunDB._diag 一个字段就能定位，不用再猜是哪个文件哪一行。
--
--   ★ 加载模型的重要更正（v0.9.16）★
--   原先这里写的是「某个文件在加载期报错，WoW 会跳过它**后面所有文件**」——
--   **这是错的**。WoW 把 toc 里每个 .lua 各当成一段独立 chunk 加载，
--   某段抛错只中止**这一段**，后面的文件照常加载。
--   实证：v0.9.15 时 Auction.lua 在顶层 RegisterEvent 抛错，而它在 toc 里
--   排第 7 —— 后面的 Mail/Professions/Route/UI/DashboardUI **全部留下了标记**。
--   所以轨迹的表现是**中间缺一个（缺口）**，不是「从某处开始截断」。
--   读法：轨迹里出现的名字 = 该文件走到底了；**缺谁就是谁在加载期挂了**。
--   （tools/read_diag.py 已按这个读法自动比对 toc 清单、把缺口点名报出来。）
--==========================================================================
local bootTrace = {}     -- 加载期只在内存里攒，PLAYER_LOGIN 再落库
                         -- （加载期就写档不安全：那时 ForLeiJunDB 未必齐）

-- 每个 .lua 文件**最后一行**调一次 ns._mark("<文件名>").
--   某个文件在加载期报错 → 它**自己**从出错那行起的代码都不执行，
--   所以它就不会留下标记（别的文件不受影响，见上面的更正）。
--   对着 toc 清单看轨迹，缺的名字就是挂在加载期的文件。
function ns._mark(name)
    bootTrace[#bootTrace + 1] = tostring(name)
    return true
end

local ERR_KEEP = 8       -- 只留最近 8 条，别把存档刷爆

function ns._diag()
    local d = db()
    local x = d._diag
    if type(x) ~= "table" then x = {}; d._diag = x end
    if type(x.errors) ~= "table" then x.errors = {} end
    return x
end

-- 记一条错误。错误处理器**本身可能就是在错误里被调用的**，所以整段 pcall
--   包住：绝不能因为它自己出错，把原始错误吃掉。
function ns._noteError(msg)
    pcall(function()
        local x = ns._diag()
        local e = x.errors
        e[#e + 1] = { ts = time(), msg = tostring(msg):sub(1, 400) }
        while #e > ERR_KEEP do table.remove(e, 1) end
        x.errN = (tonumber(x.errN) or 0) + 1
    end)
end

-- 挂到全局错误处理器上。**链条式**：照常把消息交给原来的处理器，
--   所以聊天框红字 / BugSack 的行为一点不变，只是多留一份到存档。
function ns._hookErrors()
    if ns._errHooked then return true end
    if type(geterrorhandler) ~= "function" or type(seterrorhandler) ~= "function" then return false end
    local prev = geterrorhandler()
    local ok = pcall(seterrorhandler, function(msg)
        ns._noteError(msg)
        if prev then return prev(msg) end
    end)
    ns._errHooked = ok and true or false
    return ok
end

function ns._flushBoot()
    pcall(function()
        local x = ns._diag()
        x.ver    = ns.VERSION
        x.bootTs = time()
        x.load   = bootTrace        -- 加载成功的文件，按 toc 顺序
        x.loadN  = #bootTrace
    end)
end

-- 金币可读性开关。GetMoney() 在 PLAYER_ENTERING_WORLD 之前恒返回 0（暴雪文档
-- 明确写了 "Available after PLAYER_ENTERING_WORLD"），而登录早期那次扫描早于
-- 该事件。如果那时不加判断地写入，就会把上次记录的真实金额擦成 0 —— 这正是
-- 「换了好几个角色，看板上却总有角色金币是 0」的根因。所以统一用这个开关护栏。
ns.moneyReady = false

-- 每周重置时清空「世界任务奖励预载缓存」
local function rewardCache()
    local d = db()
    local wk = ns.GetWeek().key
    if d.rewardCache.week ~= wk then
        d.rewardCache = { week = wk }
    end
    return d.rewardCache
end

--==========================================================================
-- 世界任务奖励「永久记忆库」（v0.9.5 · 治暴雪预载限流的根本手段）
--
--   问题：世界任务的金币奖励在同一资料片内是**固定值** —— 同一个任务下次
--         刷新出现，给的钱一模一样。可读这个金额要发
--         C_TaskQuest.RequestPreloadRewardData 请求，暴雪对它**有限流**：
--         请求一多就整批丢弃，只回来零星几条。而旧实现里这请求会被反复发
--         （每周清缓存 + 单会话重试上限 20 次），于是「没读到 → 重试 →
--         更限流 → 更读不到」形成死循环，池里长期压着一批读不到的任务，
--         金币任务数也就长期偏少。
--
--   解法：读到一次就**永久记住**（跨周 / 跨会话）。以后同一个任务
--         再出现，直接查表拿金额，**一个预载请求都不发**。
--         ⚠ v0.9.35 起**不再跨角色**：见 MemoKey（一次存档实测：
--         92571「黑暗大军」83 级读到 0、90 级读到 1010.79 金；若两号共用
--         一条记录，读不到的那个角色会把另一个角色的金额永久压成 0）。
--
--   作废：记忆库按「大版本.次版本」（如 12.0）分纪元。跨纪元（12.0 → 12.1）
--         自动整库作废重读 —— 新版本暴雪可能调整过奖励数值。
--
--   按等级分键（关键）：世界任务的金币奖励**随角色等级缩放** —— 同一个任务
--         90 级号看到 1035 金，83 级号可能只有 800 金。所以键里必须有等级，
--         各等级各记各的。不这么做的话，一个低等级号读到的低值会被当成本
--         任务的"真实奖励"，把高等级号上本该值钱的任务误判成不值钱而漏掉。
--
--   v0.9.35 再加**角色**（见下）：光有等级还不够 —— 同一个任务对不同角色
--         可能一个「有奖励」一个「读到 0」（角色做不了 / 客户端不给数据）。
--         同等级的两个角色会互相覆盖，读不到的那个会把 0 写进另一个角色
--         的槽位，且再也不会重读。
--
--   效果：请求量随周数单调递减。第一周读全池，之后每周只读「新出现的任务」，
--         通常个位数 —— 限流提示会自然消失。
--==========================================================================
local memoEpochCache
local function memoEpoch()
    if memoEpochCache then return memoEpochCache end
    local v = S(GetBuildInfo)
    local s = (type(v) == "string") and v or ""
    memoEpochCache = s:match("^(%d+%.%d+)") or s or "?"
    return memoEpochCache
end

-- 记忆库键：角色 + 等级 + 任务ID（v0.9.35）
--   为什么要角色：任务奖励是**每个角色各算各的**（没有「按角色查」的 API，
--   接口只返回当前登录角色的值）。实测同一个 questID「黑暗大军 92571」：
--   83 级读到 0、90 级读到 10107916 铜（1010.79 金）。只按等级记的话，
--   同等级的另一个角色会直接吃到别人的（甚至是不适用的 0），而且永不重读。
--   ⚠ ns.CharKey 在本文件后半段才定义，但 MemoKey 只在运行时被调，
--     那时早已加载完 —— 用 `ns.CharKey and` 兜底只是防测试里缺桩。
local function MemoKey(qid)
    local lvl = num(S(UnitLevel, "player"))
    if lvl <= 0 then lvl = 0 end
    local ch = (ns.CharKey and ns.CharKey()) or "?"
    return ch .. "|" .. lvl .. ":" .. tostring(qid)
end
ns.MemoKey = MemoKey

-- 记忆库结构版本：1（隐式）=「等级:任务ID」，2 =「角色|等级:任务ID」
--   旧键没有角色归属，无法安全沿用（谁读的都不知道）→ 整库作废重读一次。
local MEMO_SCHEMA = 2

local function memoBucket()
    local d = db()
    if type(d.wqMoneyMemo) ~= "table" then d.wqMoneyMemo = {} end
    local ep = memoEpoch()
    if d.wqMemoEpoch ~= ep then
        -- 跨大版本：奖励数值可能被调过，整库作废重读
        local n = 0
        for _ in pairs(d.wqMoneyMemo) do n = n + 1 end
        d.wqMoneyMemo = {}
        d.wqMemoEpoch = ep
        if n > 0 then
            print(("|cff9ecbff[雷菌]|r 游戏版本已更新到 %s，世界任务奖励记忆库（%d 条）作废，本轮起重新读取。")
                :format(ep, n))
        end
    end
    if d.wqMemoSchema ~= MEMO_SCHEMA then
        -- 旧键（"90:123456"）没有角色归属：不知道是哪条角色读到的，
        -- 沿用就等于把别人的金额（尤其是不适用的 0）当成自己的。
        local n = 0
        for _ in pairs(d.wqMoneyMemo) do n = n + 1 end
        d.wqMoneyMemo = {}
        d.wqMemoSchema = MEMO_SCHEMA
        if n > 0 then
            print(("|cff9ecbff[雷菌]|r 奖励记忆库升级为「按角色记录」（旧数据 %d 条作废），各角色会重新读一遍自己的奖励。")
                :format(n))
        end
    end
    return d.wqMoneyMemo
end
ns.MemoBucket = memoBucket

-- 读记忆库：命中返回铜数（0 视为「确认没金币」也算命中），未命中返回 nil
local function MemoGet(qid)
    local v = memoBucket()[MemoKey(qid)]
    if v == nil then return nil end
    return num(type(v) == "table" and v.m or v)
end
ns.MemoGet = MemoGet

-- 写记忆库（记下是谁、几级读的：出问题能查，也是「只认本角色」的依据）
local function MemoPut(qid, copper)
    memoBucket()[MemoKey(qid)] = {
        m   = num(copper),
        lvl = num(S(UnitLevel, "player")),
        ch  = (ns.CharKey and ns.CharKey()) or nil,
        ts  = time(),
    }
end
ns.MemoPut = MemoPut

-- 跨会话「放弃名单」：同一个任务反复读不到（多是被限流整批丢弃，或数据异常），
--   记满 GIVEUP_AFTER 次后停一段时间不再请求。
--   为什么必须有这道闸：记忆库对「从来没读到过」的任务无能为力 —— 没读到就
--   没有记录，下次登录照样再试一遍。没有它，池里那批读不到的会天天重试，
--   限流永远停不下来。
--   /wb wqretry 可清空全部放弃记录，重新尝试。
local GIVEUP_AFTER = 6                 -- 累计请求这么多次还没回来就暂停
local GIVEUP_TTL   = 14 * 24 * 60 * 60 -- 暂停这么久后自动解禁、再试一轮
local function giveUpMap()
    local d = db()
    if type(d.wqGiveUp) ~= "table" then d.wqGiveUp = {} end
    return d.wqGiveUp
end
ns.GiveUpMap = giveUpMap

-- 该任务是否处于「放弃」状态（累计失败够多 + 还没到自动解禁时间）
local function GiveUpBlocked(gm, qid, now)
    local g = gm[qid]
    if type(g) ~= "table" then return false end
    if num(g.n) < GIVEUP_AFTER then return false end
    return (now - num(g.ts)) < GIVEUP_TTL
end
ns.GiveUpBlocked = GiveUpBlocked

--==========================================================================
-- 小工具
--==========================================================================
local function MapName(mapID)
    if type(mapID) ~= "number" then return nil end
    if not (C_Map and C_Map.GetMapInfo) then return nil end
    local info = S(C_Map.GetMapInfo, mapID)
    if type(info) == "table" and info.name then return info.name end
    return nil
end
ns.MapName = MapName

-- 所有 Zone 类型地图 ID（缓存；换区域时失效）
local zoneCache
local continentMemo = {}
function ns.ResetZoneCache() zoneCache = nil; continentMemo = {} end
local function ZoneMapIDs()
    if zoneCache then return zoneCache end
    local ids = {}
    if C_Map and C_Map.GetMapInfo and Enum and Enum.UIMapType then
        for mapID = 1, 3000 do
            local info = C_Map.GetMapInfo(mapID)
            if type(info) == "table" and info.mapType == Enum.UIMapType.Zone then
                ids[#ids + 1] = mapID
            end
        end
    end
    zoneCache = ids
    return ids
end

-- 枚举名反查：把数字还原成可读名字（自动适配补丁改枚举）
local function EnumName(enumTable, names, value)
    if type(enumTable) ~= "table" then return nil end
    for _, k in ipairs(names) do
        if enumTable[k] == value then return k end
    end
    return nil
end

local VAULT_NAMES = { "Activities", "World", "MythicPlus", "Raid", "RankedPvP", "AlsoReceive", "Concession", "None" }
-- 枚举名拿不到时的数字兜底。数值取自本机存档实测（type 字段原样落盘）：
--   1 = Activities（大秘境行，1/4/8）· 3 = Raid（2/4/6）
--   5 = Concession · 6 = World（世界行，2/4/8）
-- 注意别按 wowpedia 的旧表把 1 当 RankedPvP —— 本客户端压根不是那套编号。
local VAULT_FALLBACK = {
    [1] = "Activities", [3] = "Raid", [5] = "Concession", [6] = "World",
}
local function VaultKindLabel(typeValue)
    local t = Enum and Enum.WeeklyRewardChestThresholdType
    local n = EnumName(t, VAULT_NAMES, typeValue)
    if n then return n end
    return VAULT_FALLBACK[typeValue] or ("Type" .. tostring(typeValue))
end
ns.VaultKindLabel = VaultKindLabel

local WQ_TYPE_NAMES = { "None", "Normal", "PvP", "Profession", "Dungeon", "Raid", "WorldBoss", "Questline" }
local WQ_TYPE_FALLBACK = { [0] = "Other", [1] = "Normal", [2] = "PvP", [3] = "Profession", [4] = "Dungeon", [5] = "Raid", [6] = "WorldBoss" }
local function WQTypeLabel(v)
    if type(v) ~= "number" then return nil end
    local n = EnumName(Enum and Enum.WorldQuestType, WQ_TYPE_NAMES, v)
    return n or WQ_TYPE_FALLBACK[v] or ("Type" .. tostring(v))
end

--==========================================================================
-- 当前版本口径（关键）
--   看板只统计「当前版本」的内容：当前团本梯队、当前大秘境赛季、
--   当前资料片的大陆区域。全部从客户端读取，不硬编码任何版本名 ——
--   补丁更新后自动适配，也不会因为客户端语言不同而失配。
--==========================================================================
local contentCache

-- 验证一个数字是不是「真地图 ID」（C_Map 认得出来的才算）
local function ValidMapID(v)
    if type(v) ~= "number" or v <= 0 then return nil end
    local info = S(C_Map and C_Map.GetMapInfo, v)
    if type(info) == "table" and info.mapID then return info.mapID end
    return nil
end
ns.ValidMapID = ValidMapID

-- 从一串返回值里挑第一个「真地图 ID」。
-- 用途：EJ / 挑战模式的接口返回值位置在补丁间改过（实测 12.0 的
-- EJ_GetInstanceByIndex 第 9 个返回值已经不是区域地图了），
-- 与其猜位置，不如把返回值全扫一遍，哪个能被 C_Map 认出来就用哪个。
local function PickMapID(...)
    local n = select("#", ...)
    for i = 1, n do
        local m = ValidMapID(select(i, ...))
        if m then return m end
    end
    return nil
end
ns.PickMapID = PickMapID

-- 同上，但优先要「区域/副本」级的地图（不要大陆级）。
-- 原因：接口返回值里可能混着日志实例 ID 之类的整数，恰好撞上某个地图 ID；
-- 而副本/区域图钉用的是 Zone/Micro 级地图，优先取它，命中率高得多。
local function PickAreaMapID(...)
    local n = select("#", ...)
    local ut = Enum and Enum.UIMapType
    local zoneT    = ut and ut.Zone
    local contT    = ut and ut.Continent
    local worldT   = ut and ut.World
    local cosmicT  = ut and ut.Cosmic
    local firstAny
    for i = 1, n do
        local v = select(i, ...)
        if type(v) == "number" and v > 0 then
            local info = S(C_Map and C_Map.GetMapInfo, v)
            if type(info) == "table" and info.mapID then
                if zoneT and info.mapType == zoneT then return info.mapID end
                local isBig = (contT and info.mapType == contT)
                           or (worldT and info.mapType == worldT)
                           or (cosmicT and info.mapType == cosmicT)
                if not isBig then firstAny = firstAny or info.mapID end
            end
        end
    end
    return firstAny
end
ns.PickAreaMapID = PickAreaMapID

-- 把一张地图沿 parentMapID 向上追溯，返回所属「大陆」的 mapID
local function ContinentOf(mapID)
    if type(mapID) ~= "number" or mapID <= 0 then return nil end
    local cached = continentMemo[mapID]
    if cached ~= nil then return cached or nil end

    local continentType = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
    local cur, guard, found = mapID, 0, nil
    while type(cur) == "number" and cur > 0 and guard < 10 do
        guard = guard + 1
        local info = S(C_Map and C_Map.GetMapInfo, cur)
        if type(info) ~= "table" then break end
        if info.mapType == continentType then found = info.mapID or cur; break end
        cur = info.parentMapID
    end
    continentMemo[mapID] = found or false
    return found
end

function ns.CurrentContent()
    local now = time()
    if contentCache then
        -- 探测成功永久缓存；失败则 60 秒后重试（EJ 数据可能尚未就绪）
        if contentCache.detected or (now - (contentCache.at or 0)) < 60 then
            return contentCache
        end
    end

    local cc = {
        at = now, detected = false,
        tierIndex = nil, tierName = nil,
        raidNames = {}, raidSet = {},
        seasonID = nil,
        pool = {}, poolSet = {},
        continentID = nil, continentName = nil,
    }

    -- ① 团本：冒险指南（EJ）的「当前梯队」→ 本梯队全部团本实例名
    if EJ_GetCurrentTier and EJ_SelectTier and EJ_GetInstanceByIndex then
        local ti = S(EJ_GetCurrentTier)
        if type(ti) ~= "number" or ti <= 0 then
            local n = S(EJ_GetNumTiers)   -- 兜底：EJ 梯队按时间升序，取最后一个
            if type(n) == "number" and n > 0 then ti = n end
        end
        if type(ti) == "number" and ti > 0 then
            cc.tierIndex = ti
            local tname = S(EJ_GetTierInfo, ti)
            if type(tname) == "string" and tname ~= "" then cc.tierName = tname end
            S(EJ_SelectTier, ti)
            for i = 1, 80 do
                local ok, iid, iname = pcall(EJ_GetInstanceByIndex, i, true)
                if not ok or not iid then break end
                if iname then
                    -- 区域地图 ID：不猜返回值位置，把返回值全扫一遍挑一个区域级地图
                    local areaMap = PickAreaMapID(select(2, pcall(EJ_GetInstanceInfo, iid)))
                    if not areaMap then
                        areaMap = PickAreaMapID(select(2, pcall(EJ_GetInstanceByIndex, i, true)))
                    end
                    -- 顺便数出这个本有几个首领，这样"一次都没打过"也能显示 0/N，
                    -- 而不是整个团本从看板上消失。
                    -- 注：会临时切换冒险指南的选中实例，用户打开指南时游戏会自行重选。
                    local bossNames = {}
                    if EJ_SelectInstance and EJ_GetEncounterInfoByIndex then
                        S(EJ_SelectInstance, iid)
                        for j = 1, 40 do
                            local bok, bname = pcall(EJ_GetEncounterInfoByIndex, j, iid)
                            if not bok or not bname then break end
                            bossNames[#bossNames + 1] = bname
                        end
                    end
                    cc.raidNames[#cc.raidNames + 1] = {
                        id = iid, name = iname, areaMapID = areaMap,
                        bossCount = #bossNames, bossNames = bossNames,
                    }
                    cc.raidSet[iname] = true
                end
            end
        end
    end

    -- ② 当前资料片的大陆：用本梯队第一个团本所在区域向上追溯
    if #cc.raidNames > 0 then
        cc.continentID = ContinentOf(cc.raidNames[1].areaMapID)
        if cc.continentID then
            local info = S(C_Map.GetMapInfo, cc.continentID)
            if type(info) == "table" then cc.continentName = info.name end
        end
    end

    -- ③ 大秘境：当前赛季 + 本赛季副本池
    if C_MythicPlus then
        S(C_MythicPlus.RequestMapInfo)
        local sid = S(C_MythicPlus.GetCurrentSeason)
        if type(sid) == "number" and sid > 0 then cc.seasonID = sid end
    end
    if C_ChallengeMode and C_ChallengeMode.GetMapTable then
        local maps = S(C_ChallengeMode.GetMapTable)
        if type(maps) == "table" then
            for _, mid in ipairs(maps) do
                if type(mid) == "number" then
                    -- 注意：GetMapTable 给的是「挑战模式地图 ID」，不是 C_Map 的区域地图 ID。
                    -- 口径大陆要用后者才能沿 parentMapID 追溯，所以两个都存。
                    local ok, nm, r2, r3, r4 = pcall(C_ChallengeMode.GetMapUIInfo, mid)
                    local uiMap = ok and PickAreaMapID(r2, r3, r4) or nil
                    if not uiMap then uiMap = PickAreaMapID(mid) end
                    local name = (ok and type(nm) == "string" and nm ~= "") and nm
                                 or MapName(uiMap) or ("#" .. tostring(mid))
                    cc.pool[#cc.pool + 1] = {
                        mapID = mid, uiMapID = uiMap, name = name,
                        timeLimit = num(ok and r3),        -- 若返回值位置变了，这里会退回 0
                    }
                    cc.poolSet[mid] = true
                end
            end
        end
    end

    cc.detected = (#cc.raidNames > 0) or (#cc.pool > 0)
    contentCache = cc
    return cc
end

--==========================================================================
-- 任务奖励解析
--==========================================================================
function ns.QuestRewards(questID)
    local r = { money = 0, xp = 0, currencies = {}, items = {} }
    if type(questID) ~= "number" then return r end

    local m = S(GetQuestLogRewardMoney, questID)
    if type(m) == "number" then r.money = m end

    local xp = S(GetQuestLogRewardXP, questID)
    if type(xp) == "number" then r.xp = xp end

    local nc = S(GetNumQuestLogRewardCurrencies, questID)
    if type(nc) == "number" and nc > 0 and nc < 30 then
        for i = 1, nc do
            local cname, _, cnt = S(GetQuestLogRewardCurrencyInfo, i, questID)
            if cname then r.currencies[#r.currencies + 1] = { name = cname, count = num(cnt) } end
        end
    end

    local ni = S(GetNumQuestLogRewards, questID)
    if type(ni) == "number" and ni > 0 and ni < 30 then
        for i = 1, ni do
            local iname, _, icnt, iqual, _, itemID = S(GetQuestLogRewardInfo, i, questID)
            if iname then
                r.items[#r.items + 1] = {
                    name = iname, count = num(icnt), quality = num(iqual), itemID = itemID,
                }
            end
        end
    end
    return r
end

--==========================================================================
-- 采集：宝库
--   按「枚举名」显式取各档位，而不是解码 activity.type 的数字。
--   实测：同一客户端的 type 会出现 1/3/5/6，与文档枚举值（0-4）并不一致，
--   按数字反查会把大秘境档位错判成别的名字。按名字取数才永远归位正确。
--==========================================================================
-- 档位键名一律以客户端枚举名为准（权威定义见 docs/enum_dict.json 的 vault_kind 域）：
--   Activities = 大秘境（阈值 1/4/8）· Raid = 团本（2/4/6）· World = 世界（2/4/8）
-- ⚠ 两处历史错误，已修正：
--   1) 大秘境那档曾写作 lt = "MythicPlus" —— 本客户端没有这个枚举名，
--      走枚举路径时 type(enum["MythicPlus"]) 恒为 nil，大秘境档永远取不到。
--   2) World 行曾挂 alt = "Activities" 作兜底 —— Activities 其实是大秘境，
--      兜底一旦生效就把大秘境的行错记成世界档。
-- first = 该档首档阈值，用于「枚举名存在但一行都没返回」时补 0 进度行。
local VAULT_ROWS = {
    { key = "Raid",       lt = "Raid",       label = "团本",   first = 2 },
    { key = "Activities", lt = "Activities", label = "大秘境", first = 1 },
    { key = "World",      lt = "World",      label = "世界",   first = 2 },
}

-- 兜底：拿不到枚举名时，按「三档阈值组合」反推档位（阈值比枚举稳定得多）
--   12.0 至暗之夜实测三行的阈值：
--     团本 2/4/6 · 大秘境 1/4/8 · 世界 2/4/8
--   ⚠ 2/4/8 是「世界」行，不是大秘境 —— 早先误标成 MythicPlus，
--     只在枚举名取不到、走阈值兜底时才会发作，但一旦发作就把世界行
--     的名字安到大秘境头上，所以这里必须钉死。
local VAULT_SIG = {
    ["2,4,6"]  = { key = "Raid",       label = "团本" },
    ["1,4,8"]  = { key = "Activities", label = "大秘境" },
    ["2,4,8"]  = { key = "World",      label = "世界" },
    ["3"]      = { key = "World",      label = "世界" },
    ["3,6,12"] = { key = "World",      label = "世界" },
}

local function vaultPick(out, key, label, a)
    local row = {
        kind = key, label = label, type = a.type, slot = num(a.index),
        progress = num(a.progress), threshold = num(a.threshold), level = num(a.level),
        id = a.id, raidText = a.raidString,
        rewards = type(a.rewards) == "table" and #a.rewards or 0,
        options = type(a.rewardOptions) == "table" and #a.rewardOptions or 0,
    }
    out.rowList[#out.rowList + 1] = row
    -- 同一档位保留推进度最高的那一行
    local prev = out.rows[key]
    if not prev or row.progress > prev.progress
       or (row.progress == prev.progress and row.threshold > prev.threshold) then
        out.rows[key] = row
    end
end

local function scanVault()
    local out = { rows = {}, rowList = {}, canClaim = false, hasRewards = false,
                  hasGenerated = false, resolvedBy = "none" }
    if not C_WeeklyRewards then return out end

    out.canClaim     = (S(C_WeeklyRewards.CanClaimRewards) == true)
    out.hasRewards   = (S(C_WeeklyRewards.HasAvailableRewards) == true)
    out.hasGenerated = (S(C_WeeklyRewards.HasGeneratedRewards) == true)

    local enum = Enum and Enum.WeeklyRewardChestThresholdType

    -- 首选：按枚举名显式取
    for _, spec in ipairs(VAULT_ROWS) do
        local got = false
        for _, ltName in ipairs({ spec.lt, spec.alt }) do
            if not got and enum and type(enum[ltName]) == "number" then
                local acts = S(C_WeeklyRewards.GetActivities, enum[ltName])
                if type(acts) == "table" and #acts > 0 then
                    for _, a in ipairs(acts) do
                        if type(a) == "table" then
                            vaultPick(out, spec.key, spec.label, a)
                            got = true
                        end
                    end
                elseif type(acts) == "table" then
                    -- 枚举名存在 → 这一档在本客户端确实存在；却一行都没返回
                    -- → 「已观测到，本周进度 0」。必须落一行，否则看板无法把它
                    -- 与「压根没读到这一档」区分开（口径缺陷 F2）。
                    -- 只写 rows、不写 rowList：rowList 是折算宝库开格金币用的，
                    -- 补 0 进度行不该增加可折算的格数。
                    if not out.rows[spec.key] then
                        out.rows[spec.key] = {
                            kind = spec.key, label = spec.label,
                            type = enum[ltName], slot = 1, level = 0,
                            progress = 0, threshold = spec.first,
                            observed = true, zero = true,
                        }
                    end
                    got = true
                end
            end
        end
    end
    if next(out.rows) then out.resolvedBy = "enum" end

    -- 兜底：无参取全部，再按阈值组合归位
    if not next(out.rows) then
        local acts = S(C_WeeklyRewards.GetActivities)
        if type(acts) == "table" then
            local groups = {}
            for _, a in ipairs(acts) do
                if type(a) == "table" then
                    local t = tostring(a.type)
                    if not groups[t] then groups[t] = {} end
                    local g = groups[t]
                    g[#g + 1] = a
                end
            end
            for _, g in pairs(groups) do
                local th, parts = {}, {}
                for _, a in ipairs(g) do th[#th + 1] = num(a.threshold) end
                sort(th)
                for _, v in ipairs(th) do parts[#parts + 1] = tostring(v) end
                local sig = VAULT_SIG[table.concat(parts, ",")]
                if sig then
                    for _, a in ipairs(g) do vaultPick(out, sig.key, sig.label, a) end
                    out.resolvedBy = "threshold-signature"
                else
                    local lab = VaultKindLabel(g[1].type)
                    for _, a in ipairs(g) do vaultPick(out, lab, lab, a) end
                    out.resolvedBy = "enum-type"
                end
            end
        end
    end

    if C_WeeklyRewards.GetNumCompletedDungeonRuns then
        local n = S(C_WeeklyRewards.GetNumCompletedDungeonRuns, 2)
        if type(n) == "number" then out.mplusRunsPlus2 = n end
    end
    return out
end
ns.ScanVault = scanVault      -- 导出供诊断与无头测试直接调

--==========================================================================
-- 宝库报告：把 scanVault() 的原始档位翻译成「还差几次」
--   口径（12.0 至暗之夜，客户端实测与官方攻略一致）：
--     团本 2/4/6 个 Boss · 大秘境 1/4/8 次 · 世界 2/4/8 次活动
--
--   ⚠ 世界行最容易踩的坑：「世界活动」不等于「世界任务」。
--     普通世界任务不计入宝库；算数的是 地下堡 / 狩猎(Prey) / 区域事件
--     （保护符文石、丰饶、考古那类蓝色感叹号周常）/ 周常任务 / 特别任务。
--     世界首领、收藏类周常也不算。很多人「做了一堆任务格子没动」就是这个原因。
--
--   返回：纯文本行数组（不带颜色码，方便无头测试断言；上色交给 UI）。
--==========================================================================
local VAULT_LINES = {
    { keys = { "Raid" },                     label = "团本",     unit = "个 Boss" },
    { keys = { "MythicPlus", "Activities" }, label = "大秘境",   unit = "次" },
    { keys = { "World" },                    label = "世界活动", unit = "次" },
}

function ns.VaultReport(vault)
    local lines = {}
    if type(vault) ~= "table" then
        lines[#lines + 1] = "没有读到宝库数据。"
        return lines
    end

    local rowList = vault.rowList
    if type(rowList) ~= "table" or #rowList == 0 then
        lines[#lines + 1] = "没有读到宝库档位（本周可能还没产生进度，或接口有变化）。"
    else
        for _, def in ipairs(VAULT_LINES) do
            local group = {}
            for _, r in ipairs(rowList) do
                if type(r) == "table" then
                    for _, k in ipairs(def.keys) do
                        if r.kind == k then group[#group + 1] = r; break end
                    end
                end
            end

            if #group == 0 then
                lines[#lines + 1] = string.format("%s：本周没有任何进度", def.label)
            else
                sort(group, function(a, b) return num(a.slot) < num(b.slot) end)

                local opened, best, nxt = 0, 0, nil
                for _, r in ipairs(group) do
                    local p, th = num(r.progress), num(r.threshold)
                    if p > best then best = p end
                    if th > 0 and p >= th then opened = opened + 1 end
                    if not nxt and p < th then nxt = r end
                end

                if nxt then
                    lines[#lines + 1] = string.format(
                        "%s：本周 %d %s · 已开 %d 格 · 还差 %d %s 开第 %d 格",
                        def.label, best, def.unit, opened,
                        num(nxt.threshold) - num(nxt.progress), def.unit, num(nxt.slot))
                else
                    lines[#lines + 1] = string.format(
                        "%s：本周 %d %s · 已开满 %d 格",
                        def.label, best, def.unit, opened)
                end

                -- 世界行额外报「档位」：第 3 格的奖励等级由「第 8 高」那次活动的
                -- 档次决定 —— 周常 / 区域事件 / 特别任务都只按 T1 折算，所以凑满
                -- 8 次也可能整行都是最低档；要让第 1/4/8 名都是 T8 地下堡才行。
                -- 未解锁的格子 level=0（拿不到档位），所以取「已解锁里最高的那格」。
                if def.keys[1] == "World" then
                    local lv = 0
                    for i = #group, 1, -1 do
                        local v = num(group[i].level)
                        if v > 0 then lv = v; break end
                    end
                    if lv > 0 then
                        lines[#lines + 1] = string.format("  世界档位 T%d%s", lv,
                            lv >= 8 and "（已封顶）" or "（打 T8 地下堡可以拉高）")
                    end
                end
            end
        end
    end

    if vault.hasRewards or vault.canClaim then
        lines[#lines + 1] = "上周的宝库奖励还没领 —— 去银行开一下。"
    end
    return lines
end

--==========================================================================
-- 采集：大秘境（本周）
--==========================================================================
local function scanMythicPlus()
    local cc = ns.CurrentContent()
    local out = {
        rating = 0, weeklyCount = 0, weeklyTimed = 0,
        weeklyHighest = 0, weeklyHighestTimed = 0,
        runs = {}, keystone = nil, degraded = false,
        seasonID = cc.seasonID, scopeKnown = (#cc.pool > 0),
        pool = {}, poolTimed = 0,
    }
    -- 本赛季副本池（来自客户端，随赛季自动更新）
    local poolByMap = {}
    for _, p in ipairs(cc.pool) do
        local rec = { mapID = p.mapID, name = p.name, timeLimit = num(p.timeLimit),
                      runs = 0, bestLevel = 0, timed = false }
        out.pool[#out.pool + 1] = rec
        poolByMap[p.mapID] = rec
    end
    if not C_MythicPlus then return out end

    local score = S(C_MythicPlus.GetOverallDungeonScore)
    if type(score) == "number" then out.rating = score end

    local kl = S(C_MythicPlus.GetOwnedKeystoneLevel)
    local km = S(C_MythicPlus.GetOwnedKeystoneChallengeMapID)
    if type(kl) == "number" and kl > 0 then
        out.keystone = { level = kl, mapID = km, mapName = MapName(km) }
    end

    -- 第一个参数 false = 只要本周；第二个 true = 含未限时的（黑了的也算次数）
    local runs = S(C_MythicPlus.GetRunHistory, false, true)
    if type(runs) ~= "table" then
        runs = S(C_MythicPlus.GetRunHistory)
        out.degraded = true
    end

    if type(runs) == "table" then
        for _, r in ipairs(runs) do
            if type(r) == "table" then
                local thisWeek = r.thisWeek
                if thisWeek == nil then thisWeek = true end
                if thisWeek then
                    local lvl  = num(r.level)
                    local done = (r.completed == true)
                    out.weeklyCount = out.weeklyCount + 1
                    if done then out.weeklyTimed = out.weeklyTimed + 1 end
                    if lvl > out.weeklyHighest then out.weeklyHighest = lvl end
                    if done and lvl > out.weeklyHighestTimed then out.weeklyHighestTimed = lvl end
                    local mapID = r.mapChallengeModeID
                    local name = MapName(mapID) or S(C_ChallengeMode.GetMapUIInfo, mapID) or "?"
                    out.runs[#out.runs + 1] = {
                        mapID = mapID, name = name, level = lvl,
                        completed = done, score = num(r.runScore),
                        inPool = (poolByMap[mapID] ~= nil),
                    }
                    -- 回填本赛季副本池覆盖情况
                    local p = poolByMap[mapID]
                    if p then
                        p.runs = p.runs + 1
                        if done then p.timed = true end
                        if lvl > p.bestLevel then p.bestLevel = lvl end
                    end
                end
            end
        end
    end

    sort(out.runs, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        return tostring(a.name) < tostring(b.name)
    end)
    sort(out.pool, function(a, b) return tostring(a.name) < tostring(b.name) end)
    for _, p in ipairs(out.pool) do
        if p.timed then out.poolTimed = out.poolTimed + 1 end
    end
    return out
end

--==========================================================================
-- 采集：团本 / 副本锁定 + 世界 Boss
--==========================================================================
local function scanRaids()
    local cc = ns.CurrentContent()
    local out = {
        instances = {}, worldBosses = {}, kills = 0, bosses = 0,
        scopeKnown = cc.detected, tierName = cc.tierName,
        legacyCount = 0, legacyNames = {},
    }

    -- ① 先铺上「当前梯队」的全部团本（来自冒险指南）：
    --    即使这个角色一次都没打过，也能显示 0/N，而不是整块消失
    local byName = {}
    if cc.detected then
        for _, r in ipairs(cc.raidNames) do
            local blist = {}
            for _, bn in ipairs(r.bossNames or {}) do
                blist[#blist + 1] = { name = bn, killed = false }
            end
            local rec = {
                name = r.name, journalInstanceID = r.id,
                isCurrent = true, fromJournal = true, isRaid = true,
                locked = false, extended = false, maxPlayers = 0, difficultyName = "",
                killed = 0, numEncounters = num(r.bossCount), encounterProgress = 0,
                resetText = "", resetSeconds = 0, difficulties = {},
                bosses = blist,
            }
            out.instances[#out.instances + 1] = rec
            byName[r.name] = rec
        end
    end

    -- ② 读取实际锁定，合并进对应记录；非当前版本的团本不计入统计
    local n = num(S(GetNumSavedInstances))
    for i = 1, n do
        local ok, name, lockoutId, reset, diffId, locked, extended, mostSig,
              isRaid, maxPlayers, diffName, numEnc, prog, extendDisabled, instanceId =
              pcall(GetSavedInstanceInfo, i)
        if ok and name then
            local bosses, killed = {}, 0
            local total = num(numEnc)
            if total > 0 and total < 40 then
                for j = 1, total do
                    local ok2, bname, fileDataID, isKilled = pcall(GetSavedInstanceEncounterInfo, i, j)
                    if ok2 and bname then
                        local k = (isKilled == true)
                        if k then killed = killed + 1 end
                        bosses[#bosses + 1] = { name = bname, killed = k, icon = fileDataID }
                    end
                end
            end

            local ra = (isRaid == true)
            -- 判定是否属于「当前版本」：本梯队团本名单里有没有它
            local isCurrent = true
            if cc.detected and ra then isCurrent = (cc.raidSet[name] == true) end

            local target = byName[name]
            if target then
                -- 命中本梯队团本：把实际进度填进去（多难度取已记录的这次）
                target.locked = (locked == true) or target.locked
                target.extended = (extended == true)
                target.difficultyName = diffName or target.difficultyName
                target.maxPlayers = num(maxPlayers)
                target.numEncounters = total
                target.encounterProgress = num(prog)
                target.resetText = ns.FormatDuration(num(reset))
                target.resetSeconds = num(reset)
                target.killed = killed
                target.bosses = bosses
                target.lockoutId = lockoutId
                target.instanceId = instanceId
                target.difficulties[#target.difficulties + 1] = {
                    difficultyName = diffName, killed = killed, numEncounters = total,
                    resetSeconds = num(reset), extended = (extended == true),
                }
                if locked == true and ra then
                    out.kills = out.kills + killed
                    out.bosses = out.bosses + total
                end
            elseif ra and locked == true and not isCurrent then
                -- 旧资料片的团本锁定：不计入，只登记名字供看板说明
                out.legacyCount = out.legacyCount + 1
                if #out.legacyNames < 12 then out.legacyNames[#out.legacyNames + 1] = name end
            else
                -- 其他副本（地下城等）或未识别：保留展示，不计入团本统计
                out.instances[#out.instances + 1] = {
                    name = name, lockoutId = lockoutId, reset = num(reset),
                    resetText = ns.FormatDuration(num(reset)),
                    difficultyId = diffId, difficultyName = diffName,
                    locked = (locked == true), extended = (extended == true),
                    isRaid = ra, isCurrent = isCurrent, fromJournal = false,
                    maxPlayers = num(maxPlayers), numEncounters = total,
                    encounterProgress = num(prog), killed = killed, bosses = bosses,
                    difficulties = {}, instanceId = instanceId,
                }
                if ra and locked == true then
                    out.kills = out.kills + killed
                    out.bosses = out.bosses + total
                end
            end
        end
    end

    local wb = num(S(GetNumSavedWorldBosses))
    for i = 1, wb do
        local ok, wname, wid, wreset = pcall(GetSavedWorldBossInfo, i)
        if ok and wname then
            out.worldBosses[#out.worldBosses + 1] = { name = wname, id = wid, reset = num(wreset) }
        end
    end
    return out
end

--==========================================================================
-- 采集：世界任务（账号级累积池）
--
--   为什么不是「一次性扫描」—— 三个硬约束：
--     ① C_TaskQuest.GetQuestsForPlayerByMapID 的任务数据是异步加载的，
--        刚登录时约 10~15 秒才就绪，调用后立即读会拿到空表（实测反馈）。
--     ② 世界任务按区域分布，玩家不可能同时站在所有地图上。
--     ③ 但 C_TaskQuest.GetQuestTimeLeftMinutes / GetQuestZoneID 只吃
--        questID，不依赖玩家所在地图 —— 只要曾经扫到过 questID，
--        之后任何时候都能用「剩余时间」权威判定它还活着没有。
--   所以流程是：预热地图 → 延迟读取 → 按口径入池 → 用剩余时间复核全池。
--
--   ★ 三层口径，别混（v0.9.7 明确）★
--     · 池 entries         → **账号级**：本周出现过、现在可能还在的世界任务。
--                            跨角色共享，是所有清单的唯一真相来源。
--     · 「还活着」e.live   → **账号级**：此刻还在世界上（与谁登录无关）。
--                            判死必须有证据：剩余时间归零，或「它所在的地图
--                            本轮数据加载出来了、却没读到它」。见 RefreshWqPool。
--     · 「做过了」completed→ **角色级**：只存在每个角色的 wqSeen 里，
--                            绝不能反过来影响账号级清单（这是行数漂移的老病根）。
--==========================================================================

local function wqPool()
    local p = db().wqPool
    p.entries = p.entries or {}
    p.raid    = p.raid or {}     -- 黄标团本任务独立区（不是世界任务，但每角色可做一次）
    p.sa      = p.sa or {}       -- 特别任务独立区（也不是世界任务，有解锁门槛）
    return p
end
ns.wqPool = wqPool

local function poolSize(pool)
    local n = 0
    for _ in pairs(pool.entries) do n = n + 1 end
    return n
end

-- v0.9.2 一次性迁移：解除老存档里的「奖励只读一次」锁。
--   不做这一步的话，已经被锁住的条目即使换了新代码也仍旧读不到钱 ——
--   锁是跟着池条目一起存盘的，不清掉就等于白改。
local function MigrateRewardLatch()
    local d = db()
    if d.wqRewardLatchFixed then return end
    d.wqRewardLatchFixed = true
    local p = d.wqPool
    if type(p) ~= "table" or type(p.entries) ~= "table" then return end
    local n = 0
    for _, e in pairs(p.entries) do
        if type(e) == "table" and e.rewardTried then
            e.rewardTried = nil
            n = n + 1
        end
    end
    if n > 0 then
        print(("|cff9ecbff[雷菌]|r 已解除 %d 条世界任务的奖励读取锁，本轮起会重新读取金币金额（金币任务数可能变多）。"):format(n))
    end
end
ns.MigrateRewardLatch = MigrateRewardLatch

local function hasAny(t)
    for _ in pairs(t or {}) do return true end
    return false
end

-- 当前版本涉及的大陆集合（当前梯队团本所在的大陆）
-- 12.0 实测：EJ_GetInstanceByIndex 给的 areaMapID 会是 0，
-- 导致仅靠团本反推大陆必失败。补一路兜底：用本赛季大秘境地图反推
-- （M+ 池必然是当前版本内容，mapID 就是 uiMapID，可直接向上追溯大陆）。
local function ContentContinents(cc)
    local conts = {}
    if type(cc) ~= "table" then return conts end
    for _, r in ipairs(cc.raidNames or {}) do
        local c = ContinentOf(r.areaMapID)
        if c then conts[c] = true end
    end
    if not hasAny(conts) then
        for _, m in ipairs(cc.pool or {}) do
            local c = ContinentOf(m.uiMapID or m.mapID)
            if c then conts[c] = true end
        end
    end
    return conts
end

-- 当前版本的所有区域 mapID；探测不到返回 nil（调用方退回全扫）
local function ContentZoneMapIDs(cc)
    local conts = ContentContinents(cc)
    if not hasAny(conts) then return nil end
    local ids = {}
    for _, mapID in ipairs(ZoneMapIDs()) do
        local c = ContinentOf(mapID)
        if c and conts[c] then ids[#ids + 1] = mapID end
    end
    if #ids == 0 then return nil end
    return ids
end

--==========================================================================
-- 世界任务接口兼容层（12.0 实测踩坑）
--   逐地图读任务列表的接口换过名字与字段，两处都会导致「静默返回空」：
--     · 函数名：旧 C_TaskQuest.GetQuestsForPlayerByMapID(uiMapID)
--               新 C_TaskQuest.GetQuestsOnMap(zoneID)
--               （本机能正常工作的 WorldQuestTab 用新名，WQT 用 A or B 兼容）
--     · 字段名：文档写 questId，但两个在用插件读的都是 questID
--   任何一处对不上 → 扫 348 张地图一条都拿不到、且不报错。所以这里全部兼容。
--==========================================================================
local function TaskQuestFn()
    if not C_TaskQuest then return nil end
    return C_TaskQuest.GetQuestsOnMap or C_TaskQuest.GetQuestsForPlayerByMapID
end
ns.TaskQuestFn = TaskQuestFn

-- 返回 (列表, 用了哪个签名)。列表可能是空表。
-- 参数先试双参（WorldQuestTracker 的做法），双参拿空再退单参
-- （WorldQuestTab 用的就是单参，两者对本机都可用）。
local function QueryMapQuests(mapID)
    local fn = TaskQuestFn()
    if not fn then return nil, "no-api" end

    local ok, r = pcall(fn, mapID, mapID)
    if ok and type(r) == "table" then
        if #r > 0 then return r, "dual" end
        local ok2, r2 = pcall(fn, mapID)
        if ok2 and type(r2) == "table" and #r2 > 0 then return r2, "single" end
        return r, "dual-empty"
    end

    local ok3, r3 = pcall(fn, mapID)
    if ok3 and type(r3) == "table" then
        return r3, (#r3 > 0) and "single" or "single-empty"
    end
    return {}, "error"
end
ns.QueryMapQuests = QueryMapQuests

-- 预热：对目标地图各调用一次，触发客户端内部加载任务数据（返回值丢弃）
local function WarmupMaps(ids)
    if not TaskQuestFn() then return 0 end
    local n = 0
    for _, mapID in ipairs(ids or {}) do
        n = n + 1
        QueryMapQuests(mapID)
    end
    return n
end
ns.WarmupMaps = WarmupMaps

-- 读一个任务的奖励（金币优先），写进池条目
--
--   ★ v0.9.2 修正（重要，别再改回去）★
--   这里以前是「读一次就永久钉死」：`if e.rewardTried then return end` +
--   `e.rewardTried = true`。而 e 是任务池条目，**整个池会被写进存档** ——
--   实测（2026-10-14）存档里 96 条池条目 **96 条都带 rewardTried = true**，
--   也就是「第一轮扫描没读到奖励」的任务，在之后**所有会话里都不再重读**。
--   后果：54 个场上任务里 38 个的奖励永远读不到 → 看板「金币任务 N 个」永远偏少。
--
--   正确做法：GetQuestLogRewardMoney 是纯本地调用，很便宜，**每轮扫描都重读**。
--   奖励数据是异步加载的，刚拿到 POI 那一刻经常还没到，读出来是 0；
--   所以「读到 0」只能算「这次没读到」，绝不能当成结论。
local function fillReward(e, qid)
    -- ★★ v0.9.5：先查「永久记忆库」★★
    --   世界任务的金币奖励在同一资料片内固定不变，读到过一次就没必要再读。
    --   命中就直接落值并返回 —— **不请求、不重试、不占限流额度**。
    --   这是「插件老是提示暴雪限流」的正解：不是少发请求，而是发过就不再发。
    --   注意 MemoGet 返回 0 也是「命中」，表示已确认这个任务没金币（不再请求）。
    --
    -- ★★ v0.9.35：记忆库按「角色+等级」分键 ★★
    --   池是账号级的，条目的 money 可能是**别的角色**扫出来的。那笔钱对当前
    --   角色不作数（同一个任务对不同角色金额可以不同，甚至一个是 0）：
    --   先清空，再按本角色重新查/读。清掉金额不会丢信息 —— 记忆库还留着
    --   那个角色的记录，切回去照样命中。
    local meChar = (ns.CharKey and ns.CharKey()) or nil
    if e.moneyChar and meChar and e.moneyChar ~= meChar then
        e.money, e.moneyKnown, e.moneyProbed = nil, nil, nil
        e.moneyChar = nil
    end

    local memo = MemoGet(qid)
    if memo ~= nil then
        e.money, e.moneyKnown, e.moneyProbed = memo, (memo > 0), true
        e.moneyChar = meChar
        e.rewardTried = nil
        return (memo > 0)
    end

    local m = num(S(GetQuestLogRewardMoney, qid))
    if m > 0 then
        e.money, e.moneyKnown, e.moneyProbed = m, true, true
        e.moneyChar = meChar
        e.rewardTried = nil                 -- 清掉旧存档留下的锁
        MemoPut(qid, m)
        return true
    end

    -- 兜底：奖励货币列表里 currencyID == 0 即金币
    -- （只在还没读到过钱时试，省掉每轮扫描的开销）
    if not e.moneyProbed then
        local getc = C_QuestInfoSystem and C_QuestInfoSystem.GetQuestRewardCurrencies
        local cur = S(getc, qid)
        if type(cur) == "table" then
            local sum = 0
            for _, c in ipairs(cur) do
                if type(c) == "table" then
                    local cid = c.currencyID or c.id
                    local amt = c.totalRewardAmount or c.amount or c.quantity
                    if cid == 0 and type(amt) == "number" then sum = sum + amt end
                end
            end
            if sum > 0 then
                e.money, e.moneyKnown, e.moneyProbed = sum, true, true
                e.moneyChar = meChar
                e.rewardTried = nil
                MemoPut(qid, sum)
                return true
            end
        end
    end
    return false
end

-- 把明显不属于当前版本的条目踢出池（口径保证）
function ns.PruneWqOutOfScope(conts)
    if not hasAny(conts) then return 0 end
    local pool = wqPool()
    local drop = {}
    for qid, e in pairs(pool.entries) do
        local zid = e.zoneID
        if zid then
            local c = ContinentOf(zid)
            if not (c and conts[c]) then drop[#drop + 1] = qid end
        end
    end
    for _, qid in ipairs(drop) do pool.entries[qid] = nil end
    return #drop
end

--==========================================================================
-- 「团本/首领任务」识别（重要）
--   12.x 实测：C_TaskQuest.GetQuestsOnMap 返回的是**所有 task 类任务**，
--   团本/首领任务也混在其中。这类任务命名形如「副本名：首领名」
--   （实例：「孢陨幽境：腐沼」= 12.0.7 单首领团本 + 它的菌类首领），
--   奖励常在 2000 金量级，于是被「金币任务」门槛误收进**世界任务**清单。
--   可它根本不是世界任务：世界地图上不会给出世界任务图钉，
--   玩家在地图上找不到，看板却列着 —— 这是「看板与地图对不上」的主因。
--   判据用冒险指南（EJ）里登记过的实例名 / 首领名，不依赖任何版本常数。
--==========================================================================
-- 性能红线（踩过坑）：
--   这里绝不能遍历全部梯队 + 对每个实例调 EJ_SelectInstance。
--   EJ_SelectInstance 会让冒险指南面板重建整套数据，30 梯队 × 60 实例
--   = 上千次重建 + 上万次 EJ 调用跑在主线程上，游戏会卡死几十秒——
--   表现就是「/wb 回车之后没反应」。
--   实际上从最新梯队往下扫就够了：当前版本的副本永远在最近的梯队里，
--   而「幽灵任务」也只可能出现在当前版本。再加上时间预算兜底，
--   就算 EJ 接口某天变慢也不会拖死客户端。
local EJ_TIERS_MAX   = 8      -- 只扫最新 8 个梯队（当前版本内容都在这里）
local EJ_INST_MAX    = 30     -- 每个梯队最多读 30 个实例
local EJ_BOSS_MAX    = 15     -- 每个实例最多读 15 个首领
local EJ_TIME_BUDGET = 200    -- 毫秒；debugprofilestop 的单位就是毫秒
local instNames, bossNames = nil, nil

local function EnsureInstanceNames()
    if instNames then return instNames, bossNames end
    instNames, bossNames = {}, {}
    if not (EJ_SelectTier and EJ_GetInstanceByIndex) then return instNames, bossNames end
    local t0 = debugprofilestop and debugprofilestop() or 0
    -- 梯队编号从老到新排（1 = 经典旧世），当前版本永远在**最大**编号那头。
    -- 之前写成 1..8 等于只扫了最老的 8 个梯队，12.x 的「孢陨幽境」之类
    -- 根本进不了副本名缓存，剔除逻辑形同虚设——必须从最新往回扫。
    local total = S(EJ_GetNumTiers)
    if type(total) ~= "number" or total < 1 then total = EJ_TIERS_MAX end
    for k = 1, EJ_TIERS_MAX do
        local ti = total - k + 1                 -- 最新 → 次新 → …
        if ti < 1 then break end
        S(EJ_SelectTier, ti)
        local any, added = false, 0
        for i = 1, EJ_INST_MAX do
            local ok, iid, iname = pcall(EJ_GetInstanceByIndex, i, true)
            if not ok or not iid then break end
            if iname then
                any = true
                if not instNames[iname] then added = added + 1 end
                instNames[iname] = true
                -- 首领名：直接把 instanceID 传给接口，**不要** EJ_SelectInstance
                if EJ_GetEncounterInfoByIndex then
                    for j = 1, EJ_BOSS_MAX do
                        local bok, bname = pcall(EJ_GetEncounterInfoByIndex, j, iid)
                        if not bok or not bname then break end
                        bossNames[bname] = true
                    end
                end
            end
            if t0 > 0 and (debugprofilestop() - t0) > EJ_TIME_BUDGET then break end
        end
        -- 该梯队没读到实例，或没带来任何新实例（说明接口没往前走/已到底）→ 收工
        if not any or added == 0 then break end
        if t0 > 0 and (debugprofilestop() - t0) > EJ_TIME_BUDGET then break end
    end
    return instNames, bossNames
end

-- 标题形如「副本名：首领名」→ 判为团本/首领任务（不是世界任务）
local function IsInstanceQuestTitle(title)
    if type(title) ~= "string" then return false end
    local head, tail = title:match("^(.-)[：:](.+)$")
    if not head or head == "" then return false end
    local inst, boss = EnsureInstanceNames()
    return (inst[head] == true) or (inst[tail] == true) or (boss[tail] == true)
end
ns.IsInstanceQuestTitle = IsInstanceQuestTitle

--==========================================================================
-- 「特别任务」（Special Assignment）识别（重要）
--   这一类跟世界任务**不是一回事**：
--     · 挂在一张区域地图上，需要先在该地图做完若干个世界任务才解锁
--     · 奖励是固定宝箱（满级约 2000 金），不是随机金币
--     · 客户端把它单独归一类（QuestInfo「顶点世界任务」），标题统一带前缀
--   可 12.x 的 C_TaskQuest.GetQuestsOnMap 会把**所有 task 类任务**一起返回，
--   特别任务也混在里面 —— 不分流的话它会顶着「世界任务」的名头进金币任务榜，
--   而玩家在地图上根本找不到（没解锁时地图上不显示）—— 又一次「看板与地图对不上」。
--
--   判定两条路，任一命中即认：
--     ① ns.SA_QUEST —— 由客户端 DB2 生成的已知任务表（Special.lua，随补丁重新生成）
--     ② 标题前缀 —— DB2 里这类任务共有的前缀（zhCN =「特别任务」）
--   有 ① 还有个额外好处：能主动查询「本图还没解锁所以没亮」的那些任务。
--   否则插件只有「扫到了才知道」，永远算不出「还差几个解锁」。
--==========================================================================
local function SAPrefix()
    local p = ns.SA_PREFIX
    if type(p) == "string" and p ~= "" then return p end
    return "特别任务"
end
ns.SAPrefix = SAPrefix

local function IsSpecialAssignment(qid, title)
    if type(qid) == "number" then
        local m = ns.SA_QUEST
        if type(m) == "table" and m[qid] then return true end
    end
    if type(title) == "string" then
        local pre = SAPrefix()
        -- 「解锁」类要排掉（实测踩过）：
        --   客户端给**每个角色**都挂了一个叫「特别任务解锁：顶点」的追踪任务
        --   （目标＝在该图做满 N 个世界任务，「顶点」是客户端内部对特别任务的叫法），
        --   它跟特别任务**同前缀但不同类**。不排掉就会被兜底判定误认成特别任务，
        --   于是这个「还差几个世界任务」的追踪任务自己跑进了特别任务清单里。
        --   ⚠ 这里按标题关键词排，是因为兜底分支本来就只能看标题；
        --     主判据（ns.SA_QUEST 任务 ID 表）不受影响。
        if title:sub(1, #pre) == pre and not title:find("解锁", 1, true) then
            return true
        end
    end
    return false
end
ns.IsSpecialAssignment = IsSpecialAssignment

--==========================================================================
-- 特别任务「解锁进度」的权威来源：客户端自己挂的追踪任务（重要）
--   背景：特别任务有解锁门槛 —— 在同一张图本周做满 N 个世界任务才解锁。
--   看板原先靠**代理指标**推导这个进度：数本图 wqSeen 里 completed 的条数。
--   为什么代理不可信（实测）：wqSeen 只覆盖「扫描时被地图接口报到过」的任务，
--     做完就从地图上消失的那些根本不会被报到 → 只少不多。
--     实例：同一角色，游戏内追踪任务显示祖阿曼 2/3，代理只数到 0 个。
--   权威来源：任务日志里那个「完成<区域>的世界任务」追踪任务，它就在角色身上，
--     读它的目标进度（numFulfilled/numRequired）＝游戏自己认的数，不用猜。
--   任务做完会从日志消失，所以把见过的 qid 记进 db，下一轮用
--     IsQuestFlaggedCompleted 判「本周期已完成＝已解锁」。
--   区域名 → 地图 ID 的对照直接用 Special.lua 的 ns.SA_MAPS[].n（同源，不会漂）。
--==========================================================================
ns.SA_TRACKER_KEY = "世界任务"          -- 追踪任务目标文案里必定出现这四个字

-- 解锁门槛（本图本周做满几个世界任务）。真值由 build.py 写进 Special.lua，
-- 这里只兜底 —— 万一目录没生成/是旧版，也不会算出个 nil。
local function SaUnlockNeed()
    local v = num(ns.SA_UNLOCK_WQ)
    return (v > 0) and v or 3
end
ns.SaUnlockNeed = SaUnlockNeed

-- 区域名 → UiMapID（惰性建一次；SA_MAPS 是静态表，不会有变动）
local function SaZoneIndex()
    local idx = ns._saZoneIndex
    if idx then return idx end
    idx = {}
    local maps = ns.SA_MAPS
    if type(maps) == "table" then
        for mid, meta in pairs(maps) do
            local n = (type(meta) == "table") and meta.n or nil
            if type(n) == "string" and n ~= "" then idx[n] = mid end
        end
    end
    ns._saZoneIndex = idx
    return idx
end
ns.SaZoneIndex = SaZoneIndex

-- 扫一遍任务日志 → { [mapID] = {wq, need, qid, unlocked, src} }
-- owner（可选）＝当前角色记录。追踪任务的 id **按等级段分**（同一张图 90 级是 94743、
-- 80 级是 94795），而 IsQuestFlaggedCompleted 又是逐角色的 —— 所以记住的 id
-- 必须跟角色走，不能塞进账号级存档，否则换号读的是别的角色的 id。
function ns.ScanUnlockTrackers(owner)
    local out = {}
    if type(C_QuestLog) ~= "table"
        or type(C_QuestLog.GetNumQuestLogEntries) ~= "function" then
        return out
    end
    local idx = SaZoneIndex()
    if not next(idx) then return out end       -- 没有特别任务目录时不瞎猜

    local store = (type(owner) == "table") and owner or db()
    store.saTrackers = store.saTrackers or {}   -- mapID -> 追踪任务ID（任务消失后还要查）

    local total = num(S(C_QuestLog.GetNumQuestLogEntries))
    for i = 1, total do
        local info = S(C_QuestLog.GetInfo, i)
        local qid = (type(info) == "table") and info.questID or nil
        if type(qid) == "number" and qid > 0 then
            local objs = S(C_QuestLog.GetQuestObjectives, qid)
            -- 世界任务自己也有「完成 X 个…」的目标文案，但它们不是解锁追踪任务。
            -- 一并排掉，免得把某条世界任务误当成解锁进度（宁可少报也不误报）。
            local isWQ = (S(C_QuestLog.IsWorldQuest, qid) == true)
            if type(objs) == "table" and not isWQ then
                local mids, got, need = {}, 0, 0
                for _, o in ipairs(objs) do
                    local txt = (type(o) == "table") and (o.text or o.description) or nil
                    if type(txt) == "string" and txt:find(ns.SA_TRACKER_KEY, 1, true) then
                        -- 目标文案里出现某张 SA 地图名 → 这条就是那张图的解锁追踪任务
                        local hit
                        for zn, m in pairs(idx) do
                            if txt:find(zn, 1, true) then hit = m; break end
                        end
                        if hit then
                            mids[hit] = true
                            got  = got  + num(o.numFulfilled)
                            need = need + num(o.numRequired)
                        end
                    end
                end
                -- 一条任务的目标横跨多张 SA 地图说明它不是「某一张图」的解锁追踪任务，
                -- 这种直接弃用 —— 解锁进度算错比算不出来更糟。
                local mid, n = nil, 0
                for m in pairs(mids) do mid = m; n = n + 1 end
                if mid and n == 1 then
                    if need <= 0 then need = SaUnlockNeed() end
                    out[mid] = { wq = got, need = need, qid = qid, src = "tracker" }
                    store.saTrackers[mid] = qid
                end
            end
        end
    end

    -- 追踪任务已完成、已从日志消失 → 用完成标记判「本周期已解锁」
    for mid, qid in pairs(store.saTrackers) do
        if not out[mid] and C_QuestLog.IsQuestFlaggedCompleted
            and S(C_QuestLog.IsQuestFlaggedCompleted, qid) == true then
            local need = SaUnlockNeed()
            out[mid] = { wq = need, need = need, qid = qid, unlocked = true,
                         src = "tracker-flag" }
        end
    end
    return out
end

-- 单次收集：读地图 → 按口径入池 → 复核全池
function ns.CollectWorldQuests(ids, scopeMode)
    local pool = wqPool()
    local now = time()
    local zones, found = 0, 0
    local seen = {}
    -- 本轮「数据真的加载出来了」的地图集合。
    --   为什么需要它：单次扫描是**部分读取** —— 任务数据是异步加载的，
    --   刚登录 / 刚换号 / 刚 reload 时大部分地图会静默返回空表。
    --   只有「返回过至少一条 POI 的地图」才证明它的数据到齐了；
    --   这种地图上没读到的任务，才算「真的没了」。见 ns.RefreshWqPool。
    local loaded = {}
    local rejected, rejectedTitles = 0, {}    -- 被剔掉的团本/首领任务（诊断用）
    local saFound = 0                         -- 本批读到的特别任务数（诊断用）
    local conts = ContentContinents(ns.CurrentContent())
    local filterOn = hasAny(conts)

    for _, mapID in ipairs(ids or {}) do
        local pois = QueryMapQuests(mapID)
        if type(pois) == "table" and #pois > 0 then
            zones = zones + 1
            loaded[mapID] = true
            for _, poi in ipairs(pois) do
                -- 字段名跨版本变过：文档写 questId，实测两个在用插件都读 questID
                local qid = (type(poi) == "table") and (poi.questID or poi.questId) or nil
                if type(qid) == "number" and not seen[qid] then
                    seen[qid] = true

                    local e = pool.entries[qid]
                    if not e then
                        e = { id = qid, firstSeen = now }
                        pool.entries[qid] = e
                    end
                    e.lastSeen  = now
                    e.lastMapID = mapID

                    -- 区域（口径过滤与展示都要用）
                    if not e.zoneID then
                        local z = S(C_TaskQuest.GetQuestZoneID, qid)
                        if type(z) == "number" and z > 0 then e.zoneID = z end
                    end
                    if not e.zoneName then
                        e.zoneName = MapName(e.zoneID) or MapName(mapID)
                    end

                    -- 口径：只收当前版本区域的任务
                    local inScope = true
                    if filterOn and e.zoneID then
                        local c = ContinentOf(e.zoneID)
                        inScope = (c ~= nil) and (conts[c] == true)
                    end

                    if inScope then
                        local title = e.title
                        if not title then
                            local t = S(C_QuestLog.GetTitleForQuestID, qid)
                            if type(t) ~= "string" or t == "" then
                                t = S(C_TaskQuest.GetQuestInfoByQuestID, qid)
                            end
                            if type(t) == "string" and t ~= "" then e.title, title = t, t end
                        end

                        if IsSpecialAssignment(qid, title) then
                            -- 特别任务：不是世界任务，搬进独立区。
                            -- 完成状态 / 是否亮着由 RefreshWqPool 持续复核（见那里说明）。
                            pool.entries[qid] = nil
                            local a = pool.sa[qid] or { id = qid, firstSeen = now }
                            a.title     = title or a.title
                            a.lastSeen  = now
                            a.lastMapID = mapID
                            a.zoneID    = e.zoneID or a.zoneID
                            a.zoneName  = e.zoneName or a.zoneName
                            if type(poi.x) == "number" then a.x = poi.x end
                            if type(poi.y) == "number" then a.y = poi.y end
                            fillReward(a, qid)
                            pool.sa[qid] = a
                            saFound = saFound + 1
                        elseif IsInstanceQuestTitle(title) then
                            -- 团本/首领任务（如 NPC 给的黄标团本任务）：不是世界任务，
                            -- 但每角色可做一次、奖励可观（实测 2049g），分流到独立区单独提示
                            pool.entries[qid] = nil
                            local r = pool.raid[qid] or { id = qid, firstSeen = now }
                            r.title    = title
                            r.lastSeen = now
                            r.zoneID   = e.zoneID or r.zoneID
                            r.zoneName = e.zoneName or r.zoneName
                            if type(poi.x) == "number" then r.x = poi.x end
                            if type(poi.y) == "number" then r.y = poi.y end
                            fillReward(r, qid)
                            pool.raid[qid] = r
                            rejected = rejected + 1
                            if #rejectedTitles < 6 then
                                rejectedTitles[#rejectedTitles + 1] = tostring(title)
                            end
                        else
                            if not e.wqTypeName and C_QuestLog and C_QuestLog.GetQuestTagInfo then
                                local ok, tagID, tagName, wt = pcall(C_QuestLog.GetQuestTagInfo, qid)
                                if ok then e.wqTypeName = WQTypeLabel(wt) end
                            end
                            fillReward(e, qid)
                            if type(poi.x) == "number" then e.x = poi.x end
                            if type(poi.y) == "number" then e.y = poi.y end
                            found = found + 1
                        end
                    else
                        pool.entries[qid] = nil    -- 非当前版本，不留
                    end
                end
            end
        end
    end

    -- 口径兜底（第三路）：EJ 与大秘境两条锚点都探不到大陆时（12.0 实测出现过），
    -- 用「本批读到的任务里，落在哪个大陆的最多」来判定当前版本大陆。
    -- 依据：当前资料片的世界任务必然集中在新大陆上，老资料片的残留任务
    -- （奖励目标 / 旧世界任务任务）只是零星几条，不会占多数。
    -- 加 60% 占比门槛，样本太少或过于分散时宁可不判定，避免误伤。
    local autoConts = nil
    if not hasAny(conts) then
        local cnt, tot = {}, 0
        for qid in pairs(seen) do
            local e = pool.entries[qid]
            local zid = e and e.zoneID
            local c = zid and ContinentOf(zid)
            if c then cnt[c] = (cnt[c] or 0) + 1; tot = tot + 1 end
        end
        local bestC, bestN = nil, 0
        for c, n in pairs(cnt) do
            if n > bestN then bestC, bestN = c, n end
        end
        if bestC and tot > 0 and bestN >= tot * 0.6 then
            conts = { [bestC] = true }
            autoConts = bestC
        end
    end

    -- 本轮是否「可信」：真的从地图上读到过任务才算数。
    -- 反例：世界地图没打开时 GetQuestsOnMap 会对所有地图静默返回空，
    -- 这种「假空」若当成权威，会把整池任务误判成已消失。
    local passGood = (found > 0)

    -- 记账必须在 RefreshWqPool 之前：后者要拿「最近一次可信扫描」判断存活。
    pool.lastScan     = now
    pool.lastZones    = zones
    pool.lastFound    = found
    pool.lastLoaded   = (function() local n = 0; for _ in pairs(loaded) do n = n + 1 end; return n end)()
    pool.scopeZones   = #(ids or {})
    pool.scopeMode    = scopeMode or "current"
    pool.lastPassGood = passGood
    pool.autoConts    = autoConts
    pool.rejectedN    = rejected
    pool.rejected     = rejectedTitles
    pool.saFound      = saFound
    if passGood then pool.lastGoodScan = now end

    ns.RefreshWqPool(now, loaded)
    ns.PruneWqOutOfScope(conts)
    ns.PruneWqPool()
    return pool
end

-- 「幽灵条目」上限（秒）—— 只在**没有证据可判断**时才用它。
--   背景：12.0 实测 GetQuestTimeLeftSeconds / GetQuestTimeLeftMinutes 对世界任务
--   常常两个都拿不到（前面两条路全 nil），于是存活判定只能退回「新鲜度」兜底。
--   只看「最近出现过」会把已经轮换掉的任务一直挂在池里（幽灵条目：看板列着、
--   地图上找不到）；但反过来只看「本轮扫描有没有重新读到」更糟 —— 见下。
--
--   ★ v0.9.7：判死必须要有证据，没证据就只看新鲜度 ★
--   实测（同一角色，6 分钟内三次扫描）：
--       02:26 读到  5 条  /  02:28 读到  3 条  /  02:31 读到 46 条
--   三批**互不重叠**。任务数据是异步加载 + 只读已缓存的地图，所以单次扫描
--   天生是部分读取；若要求「必须在本轮被重新读到」，后一次部分扫描会把前面
--   刚读到的整批判死 —— 表现就是看板上世界任务的行数一直变、每次换号/重载
--   都少几条。行数变动与「任务有没有轮换」无关，纯粹是读取时机问题。
--
--   所以改成：**只在「本轮真的把这张地图的数据读出来了」时才允许判死**，
--   其余情况一律按新鲜度兜底（TTL 给够，让多次部分扫描有机会把全池补齐）。
local GHOST_MAX_AGE = 45 * 60

-- 复核池中每一条：还有剩余时间吗？这个角色完成了没？
-- 关键：GetQuestTimeLeftSeconds/Minutes 只吃 questID，无需玩家在该地图上，
--       所以别的区域的任务也能被准确判定，不会因为"没去过"就被误判为已消失。
--
-- loaded = 本轮「数据真的加载出来了」的地图集合（见 ns.CollectWorldQuests）。
--          缺省为空 = 本轮没有任何可信证据，一律不判死。
function ns.RefreshWqPool(now, loaded)
    now = now or time()
    loaded = loaded or {}
    local pool = wqPool()
    local purge = nil

    -- ★ v0.9.15 修（真机崩溃点）★
    --   「最近一次可信扫描」的时间戳。下面 sa 区用 good > 0 / lastSeen >= good
    --   判断「这条在最近一次可信扫描里被地图接口报到过」。
    --   原先这里**漏了定义** → good 成了一个不存在的全局 = nil → 第一次比较就抛
    --     attempt to compare number with nil
    --   （Lua 把 a > b 编译成 b < a，所以报的是 number with nil；
    --     别被这个措辞带偏去怀疑「左值是 number」。诊断见 Logs/General.log）
    --
    --   后果远不止丢一条数据：异常会掀掉整个 ns.CollectWorldQuests，
    --   于是它后面的 db().worldQuests 落库、ns.StartPreloadPump()（奖励预载）
    --   全都不执行 —— 存档里的证据是 lastPassGood=false / lastFound=0 /
    --   lastZones=0，表现就是「世界任务区近乎空的、金币任务只有两三条」。
    --
    --   无头测试没抓到，是因为测试夹具里 pool.sa 是空的，这段循环一次都没进过；
    --   真机上 saCount=2 才触发。已在 test_wq_live 补了非空 sa 的场景。
    local good = num(pool.lastGoodScan)

    for qid, e in pairs(pool.entries) do
        -- 旧版插件时代混进池的团本/首领任务（如「孢陨幽境：腐沼」）：
        -- 复核时一经识别，搬进独立 raid 区（不删——那是每个角色能领一次的真实收益）
        if e.title and IsInstanceQuestTitle(e.title) then
            local r = pool.raid[qid] or { id = qid }
            r.title    = r.title or e.title
            r.zoneID   = r.zoneID or e.zoneID
            r.zoneName = r.zoneName or e.zoneName
            if not r.money and num(e.money) > 0 then r.money = e.money end
            r.lastSeen = r.lastSeen or e.lastSeen or now
            pool.raid[qid] = r
            purge = purge or {}
            purge[#purge + 1] = qid
        end
        local secs = S(C_TaskQuest.GetQuestTimeLeftSeconds, qid)
        local mins = S(C_TaskQuest.GetQuestTimeLeftMinutes, qid)
        if type(secs) == "number" and secs >= 0 then
            e.leftSeconds = secs
        elseif type(mins) == "number" and mins >= 0 then
            e.leftSeconds = mins * 60
        else
            e.leftSeconds = nil
        end

        local done = false
        if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
            done = (S(C_QuestLog.IsQuestFlaggedCompleted, qid) == true)
        end
        e.completed = done
        e.checkedAt = now

        -- 本轮有没有重新读到它（lastSeen 就是本轮时间戳 = 读到了）
        local reFound = (num(e.lastSeen) >= now)
        -- 允许判死的条件（三者缺一不可）：
        --   ① 本轮确实把**它所在的那张地图**的数据读出来了（loaded[e.lastMapID]）
        --   ② 本轮没有重新读到它
        --   ③ 本角色**没有完成过**它 —— 世界任务一旦被这个角色做完，
        --      地图上就不再显示它，本轮读不到是正常的，不能据此判死。
        --      （这条以前写成了「完成即判死」，等于让某个角色的进度去改账号级清单，
        --        是行数漂移的第二个来源。）
        local judged = (not reFound) and (not done)
            and e.lastMapID ~= nil and loaded[e.lastMapID] == true

        if e.leftSeconds ~= nil then
            e.live = (e.leftSeconds > 0)              -- 有剩余时间 = 权威判定
            e.verified = e.live
        elseif judged then
            e.live = false                            -- 有证据：地图读出来了，但没它
            e.verified = false
        else
            -- 没证据 → 只看新鲜度。不因为「本轮没读到」就判死。
            e.live = ((now - num(e.lastSeen)) <= GHOST_MAX_AGE)
            e.verified = reFound
        end
    end
    if purge then
        for _, qid in ipairs(purge) do pool.entries[qid] = nil end
    end

    -- 特别任务：老残留（插件升级前混在 entries 里的）搬进独立区。
    -- 同团本任务的处理方式 —— 搬走而不是删掉，它本身就是一类真实内容。
    local sa_purge = nil
    for qid, e in pairs(pool.entries) do
        if IsSpecialAssignment(qid, e.title) then
            local a = pool.sa[qid] or { id = qid }
            a.title    = a.title or e.title
            a.zoneID   = a.zoneID or e.zoneID
            a.zoneName = a.zoneName or e.zoneName
            a.lastSeen = max(num(a.lastSeen), num(e.lastSeen)) or e.lastSeen
            if not a.money and num(e.money) > 0 then a.money, a.moneyKnown = e.money, true end
            pool.sa[qid] = a
            sa_purge = sa_purge or {}
            sa_purge[#sa_purge + 1] = qid
        end
    end
    if sa_purge then
        for _, qid in ipairs(sa_purge) do pool.entries[qid] = nil end
    end

    -- 特别任务的状态判定（与团本任务的关键区别：它们有解锁门槛）
    --   「本角色完成没有」= IsQuestFlaggedCompleted（每周重置后自动变回 false）
    --   「当前亮着没有」  = 有剩余时间 且 没做完。**没亮 ≠ 没解锁** ——
    --                      可能就是本周已经做完了，也可能真的还没解锁，
    --                      所以这里只报事实，不给「解锁没解锁」下结论。
    for qid, a in pairs(pool.sa) do
        a.checkedAt = now
        local done = false
        if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
            done = (S(C_QuestLog.IsQuestFlaggedCompleted, qid) == true)
        end
        a.completed = done

        local secs = S(C_TaskQuest.GetQuestTimeLeftSeconds, qid)
        local mins = S(C_TaskQuest.GetQuestTimeLeftMinutes, qid)
        if type(secs) == "number" and secs >= 0 then
            a.leftSeconds = secs
        elseif type(mins) == "number" and mins >= 0 then
            a.leftSeconds = mins * 60
        else
            a.leftSeconds = nil
        end

        -- onMap：本条在「最近一次可信扫描」里被地图接口报到过
        a.onMap = (good > 0) and (num(a.lastSeen) >= good) or false
        a.live  = (a.leftSeconds ~= nil and a.leftSeconds > 0 and not done) or a.onMap
        a.verified = a.onMap
        if done then a.live = false end
    end

    -- 团本任务区：记录「本角色是否已完成」（每个角色能领一次，逐角色累积）
    -- 键走 ns.CharKey()（带服务器），以前只存裸角色名，跨服同名会串
    local me = ns.CharKey() or "?"
    for qid, r in pairs(pool.raid) do
        r.checkedAt = now
        local done = false
        if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
            done = (S(C_QuestLog.IsQuestFlaggedCompleted, qid) == true)
        end
        if done then
            r.done = r.done or {}
            if not r.done[me] then r.done[me] = now end
            r.doneByMe = true
        else
            r.doneByMe = false
        end
    end
end

--==========================================================================
-- 「金币任务」的分类口径（v0.9.34：金额门槛回归默认 700 金，等级联动保持删除）
--   历史：v0.9.5~v0.9.31 默认「满级 700 金、按角色等级线性缩放」，假设是
--   「低等级角色的世界任务奖励本来就低」。2026-10-18 用户推翻该假设：
--   83 级也能看到 900+ 金的任务，等级和奖励额无关 → 删掉的是**等级门槛**。
--   v0.9.32 误把金额门槛一起删了 → 池里出现所有带金币奖励的任务（不是本意）。
--   现在：默认金额门槛 = 700 金（固定值，不随角色等级缩放）；
--   /wb wqfloor <金> 可改，/wb wqfloor 0 清手动值回到默认 700。
--==========================================================================
local GOLD_WQ_FLOOR_DEFAULT = 700 * 10000 -- 700 金（铜）
ns.GOLD_WQ_FLOOR_DEFAULT = GOLD_WQ_FLOOR_DEFAULT
local function MaxPlayerLevel()
    local v = S(GetMaxLevelForPlayerExpansion)
    if type(v) == "number" and v > 0 then return v end
    if type(MAX_PLAYER_LEVEL) == "number" and MAX_PLAYER_LEVEL > 0 then return MAX_PLAYER_LEVEL end
    return 80
end
ns.MaxPlayerLevel = MaxPlayerLevel

function ns.GoldWqFloor()
    -- 金额门槛：默认 700 金（v0.9.34 恢复）；/wb wqfloor <金> 设手动值，
    -- /wb wqfloor 0 清手动值回到默认。等级联动已永久删除，不随角色等级缩放。
    local v = num(db().wqGoldFloor)
    if v > 0 then return v end
    return GOLD_WQ_FLOOR_DEFAULT
end

function ns.SetGoldWqFloor(goldAmount)
    local v = num(goldAmount)
    db().wqGoldFloor = (v > 0) and floor(v * 10000) or nil
    return ns.GoldWqFloor()
end

-- 「算不算金币任务」：奖励 ≥ 门槛（默认 700 金）才算；确认没金币的一律不算 ——
--   没有这条底线，奖励读到 0 的任务会被算进金币任务统计。
function ns.IsGoldWqMoney(moneyCopper)
    local m = num(moneyCopper)
    return m > 0 and m >= ns.GoldWqFloor()
end

-- 池瘦身：只保留最近出现过的 500 条
function ns.PruneWqPool()
    local pool = wqPool()
    if poolSize(pool) <= 800 then return end
    local arr = {}
    for qid, e in pairs(pool.entries) do
        arr[#arr + 1] = { qid = qid, ts = num(e.lastSeen) }
    end
    sort(arr, function(a, b) return a.ts > b.ts end)
    local keep = {}
    for i = 1, min(#arr, 500) do
        if arr[i] then keep[arr[i].qid] = pool.entries[arr[i].qid] end
    end
    pool.entries = keep
end

-- 池 → 看板快照
--
--   ★ v0.9.7：清单口径改成**纯账号级** ★
--   世界任务的**清单**是所有角色共享的（系统级刷新），角色之间只差「做没做过」。
--   所以这里输出的 `list` / `goldList` / `smallList` 一律是「**此刻还活着**」的
--   任务，**不再按「当前登录角色完成了没」过滤** —— 以前带着 `not e.completed`，
--   等于拿某个角色的进度去打薄账号级清单：在 A 号上做完几个金币世界任务，
--   切到 B 号重新扫描，这几行就从看板上消失了，看起来像"行数在变"。
--   现在每条 item 带 `doneByMe`（本角色完成没有），由调用方自己决定怎么显示。
--
--   注意 `verified=false` 的条目是「本轮没重新读到、靠新鲜度兜底」的，
--   它们**可能**已经轮换掉，看板可以淡显 —— 但不再因此把它们从行里删掉：
--   删除必须要有证据（见 ns.RefreshWqPool 的 judged 判据）。
function ns.WqPoolSnapshot()
    local pool = wqPool()
    local now = time()
    local floorCopper = ns.GoldWqFloor()
    local list, goldList, smallList, byZone = {}, {}, {}, {}
    local unreadList, noMoney = {}, 0          -- 未读到奖励 / 已确认无金币（两者不同）
    local total, gold, goldCopper, unknown = 0, 0, 0, 0
    local moneyAny, moneyAnyCopper, moneyMax = 0, 0, 0
    local doneByMeN = 0
    -- v0.9.35：金额归属。别的角色扫出来的金额对当前角色不作数 —— 只认当前角色
    --   （同一个任务对不同角色可以是 1010 金 / 0 金两种结果）。
    --   moneyChar 为 nil = v0.9.35 之前的旧条目，没有归属信息，暂时按本角色算，
    --   等这轮扫描重读后就会打上正确的归属。
    local meChar = (ns.CharKey and ns.CharKey()) or nil

    for _, e in pairs(pool.entries) do
        if e.live then
            total = total + 1
            if e.completed == true then doneByMeN = doneByMeN + 1 end
            local foreign = (meChar ~= nil) and (e.moneyChar ~= nil) and (e.moneyChar ~= meChar)
            local item = {
                id = e.id, title = e.title or ("任务#" .. tostring(e.id)),
                zone = e.zoneName or "?", zoneID = e.zoneID,
                -- foreign：这笔金额是别的角色读到的 → 金额与「已确认无金币」都不采信，
                --   按「还没读到」处理（看板会把它算进未读/待刷新，而不是当成 0 金）。
                money = foreign and 0 or num(e.money),
                moneyKnown = (not foreign) and (e.moneyKnown == true),
                -- moneyProbed：奖励数据已经加载完（读到过 0 或具体金额）。
                -- 为 false = 根本还没读到，不能当作「没有金币」。
                moneyProbed = (not foreign) and (e.moneyProbed == true),
                foreignMoneyChar = foreign and e.moneyChar or nil,
                wqTypeName = e.wqTypeName or "Unknown",
                leftSeconds = e.leftSeconds,
                leftText = e.leftSeconds and ns.FormatDuration(e.leftSeconds) or nil,
                lastSeenAgo = now - num(e.lastSeen),
                -- doneByMe：「当前登录角色」本周完成过没有。清单是账号级的，
                -- 只有这个标记是角色级的。
                doneByMe = (e.completed == true),
                -- verified：本条是否在**本轮扫描**里被客户端重新报过。
                -- 为 false = 靠新鲜度兜底（可能已轮换），看板可作淡显处理。
                verified = (e.verified == true),
                -- ★ mapID 必须与 x / y 同源 ★
                --    x / y 是「扫描时那张地图」上的 POI 坐标（见 CollectWorldQuests），
                --    而上面的 zoneID 是 C_TaskQuest.GetQuestZoneID 给的「任务所属区域」，
                --    后者经常是子区域（「屠戮者高地」属于「哈籁恩达尔」）。
                --    所以导航（TomTom 路点 / C_Map.SetUserWaypoint）要用这一对
                --    (mapID, x, y)；拿 zoneID 配 x/y 会打到错的地图上去。
                --    这是 Route.lua 唯一依赖的坐标口径，别删。
                mapID = e.lastMapID,
                x = e.x, y = e.y,
            }
            list[#list + 1] = item

            local z = byZone[item.zone]
            if not z then
                z = { total = 0, gold = 0, goldCopper = 0, small = 0, smallCopper = 0 }
                byZone[item.zone] = z
            end
            z.total = z.total + 1

            if item.money > 0 then
                moneyAny = moneyAny + 1
                moneyAnyCopper = moneyAnyCopper + item.money
                if item.money > moneyMax then moneyMax = item.money end
            end

            -- 金币任务：确认有金币且达到门槛（v0.9.32 起默认不限金额）
            if ns.IsGoldWqMoney(item.money) then
                gold = gold + 1
                goldCopper = goldCopper + item.money
                z.gold = z.gold + 1
                z.goldCopper = z.goldCopper + item.money
                goldList[#goldList + 1] = item
            elseif item.money > 0 then
                -- 只是普通任务带的零钱，单独归堆（看板上不算「金币任务」）
                smallList[#smallList + 1] = item
                z.small = z.small + 1
                z.smallCopper = z.smallCopper + item.money
            elseif item.moneyProbed then
                -- 数据已加载、读出来确实没金币 → 不是漏读，不计入告警
                noMoney = noMoney + 1
            else
                -- 真的还没读到：看板要把它标出来（可能里面就藏着金币任务）
                unknown = unknown + 1
                unreadList[#unreadList + 1] = item
            end
        end
    end

    sort(list, function(a, b)
        if (a.money > 0) ~= (b.money > 0) then return a.money > 0 end
        if num(a.money) ~= num(b.money) then return num(a.money) > num(b.money) end
        return tostring(a.title) < tostring(b.title)
    end)
    sort(goldList, function(a, b)
        if num(a.money) ~= num(b.money) then return num(a.money) > num(b.money) end
        return tostring(a.title) < tostring(b.title)
    end)
    sort(smallList, function(a, b)
        if num(a.money) ~= num(b.money) then return num(a.money) > num(b.money) end
        return tostring(a.title) < tostring(b.title)
    end)
    sort(unreadList, function(a, b)
        if tostring(a.zone) ~= tostring(b.zone) then return tostring(a.zone) < tostring(b.zone) end
        return tostring(a.title) < tostring(b.title)
    end)

    -- 黄标团本任务独立清单（不是世界任务；每角色可做一次，逐角色累积完成数）
    local me = UnitName("player") or "?"
    local raidList, raidGold, raidDoneByMe = {}, 0, 0
    for qid, r in pairs(pool.raid or {}) do
        local fr = (meChar ~= nil) and (r.moneyChar ~= nil) and (r.moneyChar ~= meChar)
        local item = {
            id = qid,
            title = r.title or ("任务#" .. tostring(qid)),
            zone = r.zoneName or "?",
            money = fr and 0 or num(r.money), moneyKnown = (not fr) and (r.moneyKnown == true),
            doneByMe = (r.done and r.done[me] ~= nil),
            doneCount = (function()
                local n = 0
                for _ in pairs(r.done or {}) do n = n + 1 end
                return n
            end)(),
            lastSeenAgo = now - num(r.lastSeen),
            x = r.x, y = r.y,
        }
        raidGold = raidGold + item.money
        if item.doneByMe then raidDoneByMe = raidDoneByMe + 1 end
        raidList[#raidList + 1] = item
    end
    sort(raidList, function(a, b)
        if a.doneByMe ~= b.doneByMe then return b.doneByMe end   -- 没做过的排前面
        return num(a.money) > num(b.money)
    end)

    -- 特别任务独立清单（不是世界任务；有解锁门槛，见 ns.RefreshWqPool 的说明）
    local saList, saOnMap, saDone = {}, 0, 0
    for qid, a in pairs(pool.sa or {}) do
        local fa = (meChar ~= nil) and (a.moneyChar ~= nil) and (a.moneyChar ~= meChar)
        local item = {
            id = qid,
            title = a.title or ("任务#" .. tostring(qid)),
            zone = a.zoneName or "?", zoneID = a.zoneID,
            money = fa and 0 or num(a.money), moneyKnown = (not fa) and (a.moneyKnown == true),
            leftSeconds = a.leftSeconds,
            live = (a.live == true), onMap = (a.onMap == true),
            completed = (a.completed == true),
            lastSeenAgo = now - num(a.lastSeen),
            x = a.x, y = a.y,
        }
        if item.onMap then saOnMap = saOnMap + 1 end
        if item.completed then saDone = saDone + 1 end
        saList[#saList + 1] = item
    end
    sort(saList, function(a, b)
        if a.completed ~= b.completed then return not a.completed end
        return tostring(a.title) < tostring(b.title)
    end)

    return {
        total = total, gold = gold, goldCopper = goldCopper, unknownReward = unknown,
        noMoney = noMoney, unreadList = unreadList,
        goldFloor = floorCopper,
        moneyAny = moneyAny, moneyAnyCopper = moneyAnyCopper, moneyMax = moneyMax,
        smallCopper = moneyAnyCopper - goldCopper,
        list = list, goldList = goldList, smallList = smallList, byZone = byZone,
        -- doneByMe：清单是账号级的，这一项 = 「当前登录角色做掉了几个」（角色级）
        doneByMe = doneByMeN,
        raidList = raidList, raidCount = #raidList,
        raidGold = raidGold, raidDoneByMe = raidDoneByMe,
        saList = saList, saCount = #saList, saOnMap = saOnMap, saDone = saDone,
        poolSize = poolSize(pool),
        scopeMode = pool.scopeMode, scopeZones = pool.scopeZones,
        lastZones = pool.lastZones, lastFound = pool.lastFound,
        -- lastLoaded：本轮数据真的加载出来的地图数。远小于 lastZones 就说明
        -- 这次是部分读取 —— 幽灵判定会因此自动收紧（见 RefreshWqPool）。
        lastLoaded = pool.lastLoaded,
        lastScan = pool.lastScan, scanTime = now,
        lastGoodScan = pool.lastGoodScan, lastPassGood = pool.lastPassGood,
        autoConts = pool.autoConts,
        rejectedN = num(pool.rejectedN), rejected = pool.rejected,
    }
end

-- 两段式驱动：预热 → 延迟读取（数据是异步加载的，必须等一下再读）
function ns.ScanWorldQuests(delay, opts)
    opts = opts or {}
    local cc = ns.CurrentContent()

    local ids, mode
    if opts.all then
        ids, mode = ZoneMapIDs(), "all"
    else
        ids = ContentZoneMapIDs(cc)
        mode = ids and "current" or "all"
        if not ids then ids = ZoneMapIDs() end
    end

    WarmupMaps(ids)

    MigrateRewardLatch()

    local function run()
        ns.CollectWorldQuests(ids, mode)
        -- 按当前版本区域扫完全空 → 退回全区域（宁可多扫也不漏；口径过滤仍然生效）
        if mode == "current" and num(wqPool().lastFound) == 0 then
            ns.CollectWorldQuests(ZoneMapIDs(), "all-fallback")
        end
        db().worldQuests = ns.WqPoolSnapshot()
        -- 奖励是异步预载的，交给泵去小批次持续补发（见 StartPreloadPump 的说明）
        ns.StartPreloadPump()
    end

    local d = delay or 0.8
    if d > 0 and C_Timer and C_Timer.After then
        C_Timer.After(d, run)      -- 异步：等客户端把任务数据加载完
    else
        run()                      -- 同步：诊断命令 / 退出存档时用
    end
end

-- 对池里「还活着但奖励未知」的任务请求预载，结果经 QUEST_DATA_LOAD_RESULT 回填。
--
--   ★ v0.9.5 修正（重要，别再改回去）★
--   在 v0.9.2 的「小批次 + 冷却」之上，再加两道闸：
--     ① **记忆库短路**：已经有记录的 qid 直接跳过 —— 一个请求都不发。
--        世界任务奖励在同一资料片内固定，读到过就没必要再读。这是把请求量
--        从「每周全池」压到「每周只有新任务」的关键。
--     ② **跨会话放弃名单**：同一个 qid 累计请求 GIVEUP_AFTER 次还没回来，
--        暂停 GIVEUP_TTL 不再发。没有它，读不到的任务会天天重试，限流永不停。
--   两道闸都只为同一个目标：让「暴雪限流」这行提示自己消失，而不是靠多试几次。
local PRELOAD_PER_CALL  = 6      -- 单次最多发几条（发多了会被限流整批丢弃）
local PRELOAD_COOLDOWN  = 3      -- 同一条任务两次请求的最小间隔（秒）
local PRELOAD_MAX_TRIES = 20     -- 单会话单任务上限，兜底防止无限重试
local preloadTries, preloadAt = {}, {}

function ns.PreloadWqRewards()
    if not (C_TaskQuest and C_TaskQuest.RequestPreloadRewardData) then return 0 end
    local pool = wqPool()
    local giveup = giveUpMap()
    local now, n = time(), 0
    for qid, e in pairs(pool.entries) do
        if e.live and not e.moneyKnown
           and MemoGet(qid) == nil                       -- ① 记忆库已有 → 永不重发
           and not GiveUpBlocked(giveup, qid, now)       -- ② 已放弃的 → 这轮不发
           and (preloadTries[qid] or 0) < PRELOAD_MAX_TRIES
           and (now - num(preloadAt[qid])) >= PRELOAD_COOLDOWN then
            if n >= PRELOAD_PER_CALL then break end
            n = n + 1
            preloadTries[qid] = (preloadTries[qid] or 0) + 1
            preloadAt[qid] = now
            local g = giveup[qid]
            if type(g) ~= "table" then g = { n = 0 }; giveup[qid] = g end
            g.n = num(g.n) + 1
            g.ts = now
            pcall(C_TaskQuest.RequestPreloadRewardData, qid)
        end
    end
    return n
end

-- 预载泵：把小批次请求铺开到时间轴上去。
--   没有它的话，一轮扫描只发 6 条，38 个未知任务要等好几次扫描
--   （只有换区域 / 开地图才触发）才可能补齐 —— 玩家根本等不到。
--
--   ★ v0.9.5：改成「安静模式」★
--   以前每轮结束都往聊天框打一行「还剩 N 个没读到（暴雪限流…）」，用户被这行
--   刷屏，还以为插件坏了 —— 其实那只是「还有任务在排队读」。现在：
--     · 全部读到 → 不吭声（正常状态没什么好说的）
--     · 还有没读到的 → **只提示一次**（本次会话），且措辞说清「不影响用、下次会自动补」
--   配合记忆库，多数会话根本走不到这一步。
local preloadPumpOn = false
local preloadPumpNotified = false
local PRELOAD_PUMP_ROUNDS = 40   -- 最多补 40 轮 × 3 秒 ≈ 2 分钟，够把全池刷一遍
function ns.StartPreloadPump()
    if preloadPumpOn then return end
    if not (C_Timer and C_Timer.After
            and C_TaskQuest and C_TaskQuest.RequestPreloadRewardData) then return end
    preloadPumpOn = true
    local rounds = 0
    local function step()
        rounds = rounds + 1
        local n = ns.PreloadWqRewards()
        if n > 0 and rounds < PRELOAD_PUMP_ROUNDS then
            C_Timer.After(3, step)
        else
            preloadPumpOn = false
            -- 补齐后刷一次快照，别让看板停在半读状态
            if rounds > 1 then
                db().worldQuests = ns.WqPoolSnapshot()
                local still, got = 0, 0
                for _, e in pairs(wqPool().entries) do
                    if e.live then
                        if e.moneyKnown then got = got + 1 else still = still + 1 end
                    end
                end
                -- 只在「真读不到」且整局还没说过时提一句；读到全了就不吭声
                if still > 0 and not preloadPumpNotified then
                    preloadPumpNotified = true
                    print(("|cff9ecbff[雷菌]|r 世界任务奖励已读到 %d 个，余下 %d 个暴雪暂时不给读（限流）。"
                        .. "不影响看板，下次登录会自动接着补；已读到的金额已永久记住，不会再重复请求。"):format(got, still))
                end
            end
        end
    end
    step()
end
ns.ResetPreloadNotify = function() preloadPumpNotified = false end

--==========================================================================
-- 世界任务接口自检（/wb wqdiag）
--   一条命令看清三件事：接口名有没有变 / 字段名有没有变 / 扫描到底命中没有。
--   12.0 实测这两个地方都会导致「静默返回空」——扫几百张地图也一条拿不到，
--   而且不报任何错，光看日志无从判断。所以把这个自检做进插件。
--==========================================================================
local diagScope = {}
-- 本轮扫描命中的全部 questID（集合，不设上限）。
-- 用途：与「任务池」对账 —— 池里还挂着、但本轮扫描没读到的，就是幽灵条目。
local diagSeen = {}

-- 第二段复核：diag 第一段已对范围内「没取到奖励」的任务请求过预载，
-- 延迟 2.5 秒后由 UI 层调用本函数，把**当前版本所有地图**上的金币任务列出来。
-- 这样「地图上看到几个金币任务」与「这里报几个」可以直接对照，
-- 而不是只看玩家脚下那一张图。
function ns.DiagWorldQuestFollowup()
    local out = {}
    if #diagScope == 0 then return out end

    local floorCopper = ns.GoldWqFloor()
    local gold, smallN, unknown = {}, 0, 0
    local instN, instTitles = 0, {}
    for _, e in ipairs(diagScope) do
        local m = num(S(GetQuestLogRewardMoney, e.id))
        e.money = m
        e.title = S(C_QuestLog and C_QuestLog.GetTitleForQuestID, e.id) or ("#" .. tostring(e.id))
        if ns.IsInstanceQuestTitle and ns.IsInstanceQuestTitle(e.title) then
            -- 团本/首领任务：金额再大也不是世界任务，不进金币清单
            instN = instN + 1
            if #instTitles < 6 then instTitles[#instTitles + 1] = e.title end
        elseif ns.IsGoldWqMoney(m) then
            gold[#gold + 1] = e
        elseif m > 0 then
            smallN = smallN + 1
        else
            unknown = unknown + 1
        end
    end
    sort(gold, function(a, b) return a.money > b.money end)

    local cc = ns.CurrentContent()
    local conts = ContentContinents(cc)
    local contList = {}
    for c in pairs(conts) do contList[#contList + 1] = tostring(c) end

    out[#out + 1] = string.format("金币任务清单（当前版本范围 · 口径大陆 %s · 门槛 %.0f 金）",
        (#contList > 0 and table.concat(contList, ",") or "未探到（本次为全图）"),
        floorCopper / 10000)
    if #gold == 0 then
        out[#out + 1] = "    （范围内暂时没有识别到金币任务）"
    end
    for i = 1, min(20, #gold) do
        local e = gold[i]
        local title = S(C_QuestLog and C_QuestLog.GetTitleForQuestID, e.id) or "?"
        local left = S(C_TaskQuest and C_TaskQuest.GetQuestTimeLeftSeconds, e.id)
        local leftTxt = (type(left) == "number" and left > 0)
                       and (" · 剩 " .. ns.FormatDuration(left)) or ""
        out[#out + 1] = string.format("    %s · %s → %.0f 金 ✓%s",
            tostring(e.zone), tostring(title), e.money / 10000, leftTxt)
    end
    if #gold > 20 then out[#out + 1] = string.format("    …另 %d 个", #gold - 20) end
    out[#out + 1] = string.format("  → 合计：金币任务 %d 个 · 零钱任务 %d 个 · 奖励未取到 %d 个 · 团本/首领任务 %d 个",
        #gold, smallN, unknown, instN)
    if unknown > 0 then
        out[#out + 1] = "    （未取到的是预载还没回来，过几秒再打一次 /wb wqdiag）"
    end
    if instN > 0 then
        out[#out + 1] = " 已剔除的团本/首领任务（不是世界任务，故不计入上表）："
        for _, t in ipairs(instTitles) do
            out[#out + 1] = "    ✗ " .. tostring(t)
        end
        if instN > #instTitles then
            out[#out + 1] = string.format("    …另 %d 个", instN - #instTitles)
        end
    end

    -- 与任务池对账：池里还挂着的金币任务，本轮扫描却没读到 → 陈旧条目。
    -- 这正是「看板上列着、世界地图上找不到」的来源：
    -- 要么已轮换掉，要么根本不属于当前版本（老资料片的奖励目标也会被地图接口报出来）。
    local pool = wqPool()
    local stale = {}
    for _, e in pairs(pool.entries) do
        if e.live and not e.completed and ns.IsGoldWqMoney(e.money) and not diagSeen[e.id] then
            stale[#stale + 1] = e
        end
    end
    sort(stale, function(a, b) return num(a.money) > num(b.money) end)
    out[#out + 1] = string.format("与任务池对账：池内金币任务 %d 个，其中本轮扫描未读到 %d 个",
        (function()
            local n = 0
            for _, e in pairs(pool.entries) do
                if e.live and ns.IsGoldWqMoney(e.money) then n = n + 1 end
            end
            return n
        end)(), #stale)
    for i = 1, min(8, #stale) do
        local e = stale[i]
        out[#out + 1] = string.format("    ✗ %s · %s → %.0f 金 · 最后读到 %s前",
            tostring(e.zoneName or "?"), tostring(e.title or ("#" .. tostring(e.id))),
            num(e.money) / 10000, ns.FormatDuration(time() - num(e.lastSeen)))
    end
    if #stale > 8 then out[#out + 1] = string.format("    …另 %d 个", #stale - 8) end
    if #stale > 0 then
        out[#out + 1] = "    （这些会在下一次可信扫描后自动从看板移除）"
    end
    return out
end

--==========================================================================
-- 任务台诊断（/wb taskdiag）
--   为什么要有它：12.x 的 C_QuestLog / 任务池结构没有公开文档，字段名和
--   枚举值都可能随客户端变。本项目已经因为「猜」吃过两次亏 ——
--   string.format("%d", 小数) 在 5.3+ 直接报错、do 是 Lua 保留字差点让
--   /wb 全线瘫痪。所以「周常任务」到底怎么认，不猜，先实测。
--
--   这个函数把后面实现「今天」页要用到的判据全部打出来：
--     ① Enum.QuestFrequency 有没有暴露（决定 frequency 判据能不能用）
--     ② C_QuestLog.GetInfo 返回哪些字段（不猜键名，直接列）
--     ③ 逐条任务日志的 frequency / bounty / worldQuest / tagID / 目标进度
--     ④ 任务池条目的真实字段名 + 一条样例（剩余时长字段名从这里看）
--     ⑤ 特别任务解锁追踪进度（「差一点解锁」那块的依据）
--   跑一次就知道该用哪套判据，避免盲写。
--==========================================================================
function ns.DiagTasks()
    local out = {}
    local function L(s) out[#out + 1] = tostring(s) end

    -- 当前角色 / 本周（「今天」页的标题栏要用）
    local name, realm = S(UnitName, "player"), S(GetRealmName)
    local wi = ns.GetWeek()
    L("当前角色 = " .. tostring(name) .. " · " .. tostring(realm))
    L("本周 " .. wi.key .. " → 重置 " .. wi.resetKey .. "（" .. wi.leftText .. "后）")

    -- ① 枚举是否暴露
    local eq = Enum and Enum.QuestFrequency
    if type(eq) == "table" then
        local ks = {}
        for k, v in pairs(eq) do ks[#ks + 1] = tostring(k) .. "=" .. tostring(v) end
        table.sort(ks)
        L("Enum.QuestFrequency 存在：" .. table.concat(ks, " "))
    else
        L("Enum.QuestFrequency 不存在")
    end

    -- ② 接口可用性
    if type(C_QuestLog) ~= "table" then
        L("C_QuestLog 不可用 —— 任务台无法实现")
        return out
    end
    L(string.format("接口 GetInfo=%s  GetQuestObjectives=%s  IsQuestBounty=%s  GetQuestTagInfo=%s  IsWorldQuest=%s",
        tostring(type(C_QuestLog.GetInfo) == "function"),
        tostring(type(C_QuestLog.GetQuestObjectives) == "function"),
        tostring(type(C_QuestLog.IsQuestBounty) == "function"),
        tostring(type(C_QuestLog.GetQuestTagInfo) == "function"),
        tostring(type(C_QuestLog.IsWorldQuest) == "function")))

    -- ③ 逐条任务日志
    local totalN = num(S(C_QuestLog.GetNumQuestLogEntries))
    L("任务日志条目 = " .. totalN)

    local dumped, wkCount, rows = false, 0, {}
    for i = 1, totalN do
        local info = S(C_QuestLog.GetInfo, i)
        if type(info) == "table" and not info.isHeader then
            -- 字段名只打第一条 —— 不猜键名，直接看客户端给了什么
            if not dumped then
                local ks = {}
                for k in pairs(info) do ks[#ks + 1] = tostring(k) end
                table.sort(ks)
                L("GetInfo 字段 = " .. table.concat(ks, ", "))
                dumped = true
            end

            local qid   = num(info.questID)
            local title = tostring(info.title or ("#" .. tostring(qid)))
            local freq  = info.frequency
            local isB   = (S(C_QuestLog.IsQuestBounty, qid) == true)
            local isW   = (S(C_QuestLog.IsWorldQuest, qid) == true)

            local tag
            if C_QuestLog.GetQuestTagInfo then
                local ok, t = pcall(C_QuestLog.GetQuestTagInfo, qid)
                if ok and type(t) == "table" then tag = t.tagID end
            end

            local got, need = 0, 0
            local objs = S(C_QuestLog.GetQuestObjectives, qid)
            if type(objs) == "table" then
                for _, o in ipairs(objs) do
                    got  = got  + num(o.numFulfilled)
                    need = need + num(o.numRequired)
                end
            end

            local isWeekly = (type(eq) == "table" and eq.Weekly ~= nil and freq == eq.Weekly)
            if isWeekly or isB then wkCount = wkCount + 1 end

            rows[#rows + 1] = string.format("%s %s | freq=%s bounty=%s wq=%s tag=%s | %d/%d",
                (isWeekly or isB) and "★" or " ", title, tostring(freq),
                tostring(isB), tostring(isW), tostring(tag), floor(got), floor(need))
        end
    end
    L("疑似周常（frequency=Weekly 或 bounty）= " .. wkCount .. " 条")
    for i = 1, min(#rows, 24) do L("  " .. rows[i]) end

    -- ④ 池条目的真实结构（剩余时长字段叫什么，从这里看）
    local pool = wqPool()
    local sample = nil
    for _, e in pairs(pool.entries or {}) do
        if type(e) == "table" and e.live then sample = e; break end
    end
    if sample then
        local ks = {}
        for k in pairs(sample) do ks[#ks + 1] = tostring(k) end
        table.sort(ks)
        local parts = {}
        for _, k in ipairs(ks) do
            local v = sample[k]
            local tv = type(v)
            if tv == "table" then v = "table"
            elseif tv == "string" then v = '"' .. tostring(v):sub(1, 20) .. '"'
            else v = tostring(v) end
            parts[#parts + 1] = k .. "=" .. tostring(v)
        end
        L("池条目字段 = " .. table.concat(ks, ", "))
        L("池条目样例 = " .. table.concat(parts, "  "))

        -- 剩余时长分布：≤26h 当日常、26h~8d 当周常（反推周期的兜底判据）
        local daily, weekly, long, unknown = 0, 0, 0, 0
        for _, e in pairs(pool.entries or {}) do
            if type(e) == "table" and e.live then
                local sec = num(e.leftSeconds)
                if sec <= 0 then unknown = unknown + 1
                elseif sec <= 26 * 3600 then daily = daily + 1
                elseif sec <= 8 * 86400 then weekly = weekly + 1
                else long = long + 1 end
            end
        end
        L(string.format("场上存活剩余时长：≤26时 %d · 26时~8天 %d · >8天 %d · 拿不到 %d",
            daily, weekly, long, unknown))
    else
        L("池里没有存活任务（先 /wb scan 或进游戏走一圈）")
    end

    -- ⑤ 特别任务解锁进度（「差一点解锁」块的依据）
    if ns.ScanUnlockTrackers then
        local ok, r = pcall(ns.ScanUnlockTrackers)
        if ok and type(r) == "table" then
            local n = 0
            for mid, v in pairs(r) do
                n = n + 1
                if n <= 8 and type(v) == "table" then
                    L(string.format("  解锁追踪 map=%s  %d/%d  src=%s",
                        tostring(mid), floor(num(v.wq)), floor(num(v.need)), tostring(v.src)))
                end
            end
            if n == 0 then L("  解锁追踪：本角色当前没有在做任何解锁任务") end
        end
    else
        L("ScanUnlockTrackers 不可用")
    end

    -- ⑥ 判据建议
    local freqOk = (type(eq) == "table" and eq.Weekly ~= nil)
    L("── 判据建议 ──")
    if freqOk then
        L("frequency 可用 → 周常优先用 info.frequency == Enum.QuestFrequency.Weekly")
    else
        L("frequency 不可用 → 周常改用 IsQuestBounty + tagID + 剩余时长反推")
    end

    -- ⑥' 周常追踪器完成度（v0.9.11，种子表来自 SavedInstances）
    L("── 周常追踪器（SavedInstances 种子表）──")
    if type(ns.WEEKLY_TRACKERS) == "table" and #ns.WEEKLY_TRACKERS > 0 then
        local name, realm = UnitName("player"), GetRealmName()
        local c = name and realm and db().chars[ns.CharKey(name, realm)]
        local q = c and type(c.weeklyQuests) == "table" and c.weeklyQuests
        if type(q.trackers) ~= "table" then
            local n = ns.ScanWeeklyDone and ns.ScanWeeklyDone(c) or 0
            L(string.format("本周还没有全量扫描记录 → 现场补扫（完成 %d 项）", n))
            q = c and type(c.weeklyQuests) == "table" and c.weeklyQuests
        end
        if type(q) == "table" and type(q.trackers) == "table" then
            local rows, doneSum, totalSum = {}, 0, 0
            for _, t in ipairs(ns.WEEKLY_TRACKERS) do
                local tr = q.trackers[t.id]
                if tr then
                    doneSum = doneSum + num(tr.done)
                    totalSum = totalSum + num(tr.total)
                    if num(tr.done) > 0 then
                        rows[#rows + 1] = { n = t.name, d = num(tr.done), m = num(tr.total) }
                    end
                end
            end
            table.sort(rows, function(a, b) return a.d > b.d end)
            L(string.format("追踪器 %d 个（种子表共 %d 个）· 本角色完成 %d / %d 项任务",
                #rows, #ns.WEEKLY_TRACKERS, doneSum, totalSum))
            for i, r in ipairs(rows) do
                if i <= 10 then L(string.format("  ✓ %s  %d/%d", r.n, r.d, r.m)) end
            end
            if #rows > 10 then L(string.format("  …另有 %d 个追踪器有进度", #rows - 10)) end
            L("IsQuestFlaggedCompleted 有效性 = 上面有非零行即为有效")
        else
            L("weeklyQuests 尚未建立（本轮扫描会自动建）")
        end
    else
        L("ns.WEEKLY_TRACKERS 未加载（检查 WeeklyQuests.lua 是否在 toc）")
    end
    return out
end

function ns.DiagWorldQuest()
    local out = {}
    local function add(s) out[#out + 1] = s end

    local hasOld = (C_TaskQuest and C_TaskQuest.GetQuestsForPlayerByMapID) and true or false
    local hasNew = (C_TaskQuest and C_TaskQuest.GetQuestsOnMap) and true or false
    add("GetQuestsForPlayerByMapID = " .. (hasOld and "存在" or "不存在（旧名已弃用）"))
    add("GetQuestsOnMap            = " .. (hasNew and "存在" or "不存在"))
    add("实际使用 = " .. (hasNew and "GetQuestsOnMap"
                        or (hasOld and "GetQuestsForPlayerByMapID" or "无可用接口")))

    local cur = C_Map and C_Map.GetBestMapForUnit and S(C_Map.GetBestMapForUnit, "player")
    add("玩家当前地图 ID = " .. tostring(cur) .. " · 区域 = " .. tostring(S(GetRealZoneText)))

    -- 口径范围：当前版本的所有地图（不是只有玩家脚下这张）
    local cc = ns.CurrentContent()
    local conts = ContentContinents(cc)
    local scopeIds = ContentZoneMapIDs(cc)
    local contList = {}
    for c in pairs(conts) do contList[#contList + 1] = tostring(c) end
    add("版本口径：梯队 #" .. tostring(cc.tierIndex) .. " " .. tostring(cc.tierName or "?")
        .. " · 团本 " .. #(cc.raidNames or {}) .. " 个 · 大秘境 " .. #(cc.pool or {}) .. " 本")
    add("  口径大陆 = " .. (#contList > 0 and table.concat(contList, ", ")
        or "空（摊不开 → 只能全图扫描，范围会偏大）"))
    if not hasAny(conts) then
        add("  口径兜底 = " .. (wqPool().autoConts
            and ("大陆 " .. tostring(wqPool().autoConts) .. "（按任务数占多数自动判定）")
            or "未判定（本批任务太分散/太少，本次不启用口径过滤）"))
    end
    if cc.raidNames and cc.raidNames[1] then
        add("  团本锚点：" .. tostring(cc.raidNames[1].name)
            .. " → areaMapID " .. tostring(cc.raidNames[1].areaMapID)
            .. " → 大陆 " .. tostring(ContinentOf(cc.raidNames[1].areaMapID)))
    end
    for i = 1, min(4, #(cc.pool or {})) do
        local m = cc.pool[i]
        add("  大秘境锚点：" .. tostring(m.name) .. " → uiMapID " .. tostring(m.uiMapID)
            .. " → 大陆 " .. tostring(ContinentOf(m.uiMapID or m.mapID)))
    end

    -- 扫描范围 = 当前版本的 Zone 地图；口径探不到时退回全图（并显式标注）
    local ids, scopeNote
    if scopeIds and #scopeIds > 0 then
        ids, scopeNote = scopeIds, "当前版本区域"
    else
        ids, scopeNote = ZoneMapIDs(), "全图（口径未探到）"
    end
    add(string.format("扫描范围 = %s · %d 张地图（全服 Zone 地图共 %d 张）",
        scopeNote, #ids, #ZoneMapIDs()))

    if type(cur) == "number" and cur > 0 then
        local r, mode = QueryMapQuests(cur)
        add(string.format("  其中玩家脚下这张 %d 条（签名 %s）", #(r or {}), tostring(mode)))
    end

    -- 逐张扫「当前版本的地图」：统计命中、攒样本、给没奖励的任务请求预载
    -- （第二段「预载复核」会在 2.5 秒后报出这些任务的金币判定）
    local hitMaps, total, samples = 0, 0, {}
    local preloadN = 0
    diagScope = {}
    diagSeen = {}
    for _, mapID in ipairs(ids) do
        local r = QueryMapQuests(mapID)
        if type(r) == "table" and #r > 0 then
            hitMaps = hitMaps + 1
            total = total + #r
            for _, poi in ipairs(r) do
                local qid = (type(poi) == "table") and (poi.questID or poi.questId) or nil
                if type(qid) == "number" then
                    diagSeen[qid] = true
                    if #diagScope < 400 then
                        diagScope[#diagScope + 1] = {
                            id = qid, zone = MapName(mapID) or "?", mapID = mapID,
                        }
                    end
                    local memoed = MemoGet(qid)
                    local m = (memoed ~= nil) and num(memoed) or num(S(GetQuestLogRewardMoney, qid))
                    -- 记忆库已知的不再请求（省额度）；只对真正未知的发预载
                    if memoed == nil and m == 0 and preloadN < 200 then
                        preloadN = preloadN + 1
                        S(C_TaskQuest and C_TaskQuest.RequestPreloadRewardData, qid)
                    end
                    if #samples < 6 then
                        local t = S(C_QuestLog.GetTitleForQuestID, qid) or "?"
                        local tag = ns.IsGoldWqMoney(m) and " [金币任务]" or ""
                        samples[#samples + 1] = string.format("    #%d %s%s%s", qid, tostring(t),
                            m > 0 and string.format("  奖励 %.2f金", m / 10000)
                                  or "  （奖励未取到）", tag)
                    end
                end
            end
        end
    end
    add(string.format("扫描 %d 张地图 → 命中 %d 张 · 任务 %d 条 · 已请求预载 %d 条",
        #ids, hitMaps, total, preloadN))
    for _, s in ipairs(samples) do add(s) end

    -- 金币任务口径：v0.9.32 起默认不限金额（0 = 只要确认有金币就算），
    -- 这里把门槛和池里真实的奖励分布一起打出来，方便核对。
    local floorCopper = ns.GoldWqFloor()
    add(string.format("金币任务门槛 = %.0f 金（0 = 不限金额 · /wb wqfloor 可设）",
        floorCopper / 10000))

    local vals = {}
    for _, e in pairs(wqPool().entries) do
        if e.moneyKnown and num(e.money) > 0 then
            vals[#vals + 1] = { money = num(e.money), title = e.title or ("#" .. tostring(e.id)) }
        end
    end
    sort(vals, function(a, b) return a.money > b.money end)
    local n500, n300, n100 = 0, 0, 0
    for _, v in ipairs(vals) do
        if v.money >= 500 * 10000 then n500 = n500 + 1 end
        if v.money >= 300 * 10000 then n300 = n300 + 1 end
        if v.money >= 100 * 10000 then n100 = n100 + 1 end
    end
    add(string.format("奖励分布（池内已知 %d 条）：≥500金 %d · ≥300金 %d · ≥100金 %d",
        #vals, n500, n300, n100))
    for i = 1, min(8, #vals) do
        add(string.format("    %.0f 金 · %s", vals[i].money / 10000, tostring(vals[i].title)))
    end
    if #vals == 0 then
        add("    （池内还没有已知奖励的任务：先 /wb wq 全量入池，等预载回填）")
    end

    -- 池的「可信度」：本轮到底读到了没有。
    -- 「扫描 348 张地图 → 命中 0 张」通常不是真的没任务，而是世界地图没打开时
    -- 接口对所有地图静默返回空（假空）。这种情况没有任何可判死的证据，
    -- 池里已有条目一律按新鲜度保留，不会被误清。
    local pool = wqPool()
    local good = num(pool.lastGoodScan)
    add(string.format("任务池 %d 条 · 池内金币任务 %d 个 · 本轮扫描%s",
        poolSize(pool), (function()
            local n = 0
            for _, e in pairs(pool.entries) do
                if e.live and ns.IsGoldWqMoney(e.money) then n = n + 1 end
            end
            return n
        end)(),
        (hitMaps > 0) and "有命中" or "命中 0 张（假空，池内条目暂不清理）"))
    -- v0.9.7：判死只看「数据真的加载出来的地图」。这一行就是判据本身 ——
    -- 加载数远小于扫描数 = 本轮是部分读取，没读到的任务不会被判死。
    add(string.format("  本轮数据加载出来的地图 = %d / 扫描 %d 张%s",
        num(pool.lastLoaded), num(pool.scopeZones),
        (num(pool.lastLoaded) < num(pool.scopeZones) * 0.5)
            and "  ← 部分读取，本轮不作存活判定" or ""))
    add("  最近一次可信扫描 = " .. (good > 0
        and (ns.FormatDuration(time() - good) .. "前") or "无（本会话还没读到过任务）"))
    if num(pool.rejectedN) > 0 then
        add(string.format("  已剔除的团本/首领任务 = %d 个", num(pool.rejectedN)))
        for i = 1, min(5, #(pool.rejected or {})) do
            add("      ✗ " .. tostring(pool.rejected[i]))
        end
    end
    return out
end

-- 兼容旧调用点（同样先过记忆库：已知金额的一律不发请求）
function ns.RequestPreloads(wqList)
    for _, e in ipairs(wqList or {}) do
        if e and e.id and not e.moneyKnown
           and MemoGet(e.id) == nil
           and (preloadTries[e.id] or 0) < PRELOAD_MAX_TRIES then
            preloadTries[e.id] = (preloadTries[e.id] or 0) + 1
            S(C_TaskQuest and C_TaskQuest.RequestPreloadRewardData, e.id)
        end
    end
end

--==========================================================================
-- 主采集入口
--==========================================================================
ns.lastScan = 0

--==========================================================================
-- 角色键 —— 全插件唯一的角色身份（v0.9.10 统一）
--   ★ 统一前，同一个角色在三处各叫各的名字：
--       chars["服务器-角色名"]      （Core：快照 / 会话 / 历史）
--       bag.chars["服务器|角色名"]  （Catalog：背包银行）—— 竖线
--       raid.done["角色名"]         （裸名字，连服务器都没有）
--     三者互不认识，「账号级 = 把各角色档案合并」这件事必然串档。
--     现在唯一入口就是 ns.CharKey()。
--   格式：realm .. "-" .. name，例「死亡之翼-雷霆米拉」。
--   ⚠ 这不是 GUID —— 暴雪不提供角色级稳定 ID。服务器合并 / 角色改名后，
--     旧键会变成孤儿（看板上显示成一个「已消失的角色」）。已知限制。
--==========================================================================
function ns.CharKey(name, realm)
    name  = name  or (UnitName and UnitName("player"))
    realm = realm or (GetRealmName and GetRealmName())
    if not name or not realm then return nil end
    return realm .. "-" .. name
end

--==========================================================================
-- 存量键迁移（v0.9.10，幂等）
--   把历史遗留的旧格式键改写成 ns.CharKey() 格式，跑过的部分下次自动跳过：
--     1) bag.chars["服务器|角色名"] → bag.chars["服务器-角色名"]
--        两套键并存时保留采集时间更新的那份（pocketTs/bankTs 取大）
--     2) wqPool.raid[*].done["角色名"] → done["服务器-角色名"]
--        裸名字用 db().chars 里已知的角色反查服务器；查不到的保持原样不动
--   放在 MarkSession 里每次扫描尾部跑一次，是为了让 raid 那部分能等
--   db().chars 建起来之后再补迁移（第一次登录时可能还查不到服务器）。
--   开销：遍历几十个键，微秒级，可忽略。
--==========================================================================
function ns.MigrateCharKeys()
    local d = db()
    local moved = 0

    -- 1) 背包 / 银行：竖线键 → 横杠键
    local bag = d.bag
    if type(bag) == "table" and type(bag.chars) == "table" then
        local todo = {}
        for k in pairs(bag.chars) do
            if type(k) == "string" and k:find("|", 1, true) then
                todo[#todo + 1] = k
            end
        end
        for _, k in ipairs(todo) do
            local v = bag.chars[k]
            local nk = k:gsub("|", "-", 1)      -- Lua 的 pattern 里 | 不是魔法字符
            if nk ~= k and v ~= nil then
                local old = bag.chars[nk]
                if type(old) ~= "table" then
                    bag.chars[nk] = v
                else
                    local ta = math.max(num(old.pocketTs), num(old.bankTs))
                    local tb = math.max(num(v.pocketTs),   num(v.bankTs))
                    if tb > ta then bag.chars[nk] = v end
                end
                bag.chars[k] = nil
                moved = moved + 1
            end
        end
    end

    -- 2) 团本周常的「谁做过」名单：裸角色名 → 带服务器
    local name2realm = {}
    for _, c in pairs(d.chars or {}) do
        if type(c) == "table" and type(c.name) == "string" and type(c.realm) == "string" then
            name2realm[c.name] = c.realm
        end
    end
    local pool = d.wqPool
    if type(pool) == "table" and type(pool.raid) == "table" then
        for _, r in pairs(pool.raid) do
            if type(r) == "table" and type(r.done) == "table" then
                local todo = {}
                for n in pairs(r.done) do
                    -- 只迁移「能反查出服务器」的裸名字；已是新格式的查不到，天然跳过
                    if type(n) == "string" and name2realm[n] then
                        todo[#todo + 1] = n
                    end
                end
                for _, n in ipairs(todo) do
                    local nk = name2realm[n] .. "-" .. n
                    if r.done[nk] == nil then r.done[nk] = r.done[n] end
                    r.done[n] = nil
                    moved = moved + 1
                end
            end
        end
    end

    if moved > 0 then d.keyScheme = 2 end
    return moved
end

--==========================================================================
-- 当前登录角色 —— 看板顶部「我现在是谁、这个号还剩什么没做」的依据
--   SavedVariables 只在登出 / reload / 换角色时落盘，所以看板读到的必然是
--   「最后一次落盘时登录的那个角色」（不是实时在线状态，这是暴雪机制，绕不过）。
--   每次扫描记一笔：换号后新角色的登录会覆盖它。
--   d.sessions 记「角色 → 最后登录时间」，用来在看板上标出最近登过的号。
--==========================================================================
function ns.MarkSession()
    if not (UnitName and GetRealmName) then return nil end
    local name  = UnitName("player")
    local realm = GetRealmName()
    if not name or not realm then return nil end
    local d   = db()
    local key = ns.CharKey(name, realm)
    local now = time()
    d.session = { key = key, name = name, realm = realm, ts = now }
    if type(d.sessions) ~= "table" then d.sessions = {} end
    d.sessions[key] = now
    ns.PruneSessions()
    -- 顺手把存量旧键（竖线 / 裸名字）迁到统一格式；幂等，跑完就 no-op
    ns.MigrateCharKeys()
    return key
end

function ns.PruneSessions()
    local d = db()
    local arr = {}
    for k, v in pairs(d.sessions or {}) do
        if type(k) == "string" then arr[#arr + 1] = { k = k, ts = num(v) } end
    end
    if #arr <= 40 then return end
    sort(arr, function(a, b) return a.ts > b.ts end)
    local keep = {}
    for i = 1, 30 do
        if arr[i] then keep[arr[i].k] = arr[i].ts end
    end
    d.sessions = keep
end

function ns.Scan(opts)
    opts = opts or {}
    if not UnitName or not UnitName("player") then return nil end
    local name = UnitName("player")
    local realm = GetRealmName() or S(GetNormalizedRealmName)
    if not name or not realm then return nil end

    local d = db()
    local wi = ns.GetWeek()
    local key = ns.CharKey(name, realm)

    local c = d.chars[key]
    if not c then c = { key = key }; d.chars[key] = c end

    -- 跨周：把上周快照归档，清空本周累计
    if c.week and type(c.week) == "table" and c.week.key and c.week.key ~= wi.key then
        d.history[c.week.key] = d.history[c.week.key] or {}
        d.history[c.week.key][key] = {
            archivedTs    = time(),     -- 归档时刻（跨周后该角色首次登录时回填）
            week          = c.week,
            vault         = c.vault,
            mythicPlus    = c.mythicPlus,
            raids         = c.raids,
            worldQuests   = c.worldQuests,
            wqWeek        = c.wqWeek,
            weeklyQuests  = c.weeklyQuests,
            ilvl          = c.ilvl,
            money         = c.money,
            scanTime      = c.scanTime,
        }
        c.weeklyQuests = nil
        c.wqSeen = nil
        c.worldQuests = nil
        ns.PruneHistory()
    end
    c.week = wi

    -- 角色元信息
    local dispName, classFile = UnitClass("player")
    local colors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
    c.name       = name
    c.realm      = realm
    c.key        = key
    c.level      = num(UnitLevel("player"))
    c.class      = classFile
    c.className  = dispName
    c.classColor = (colors and colors[classFile] and colors[classFile].colorStr) or nil
    c.faction    = S(UnitFactionGroup, "player")
    -- 只在金币可读之后才动 money 字段（见 ns.moneyReady 处的说明）。
    -- 未就绪时保持原值不动，避免把已记录的真实金额擦成 0。
    if ns.moneyReady then
        local m = num(S(GetMoney))
        if m > 0 or c.money == nil then
            c.money   = m
            c.moneyTs = time()
        end
    end
    c.zone       = S(GetRealZoneText)
    c.guild      = S(GetGuildInfo, "player")

    if GetAverageItemLevel then
        local ok, equipped, overall = pcall(GetAverageItemLevel)
        if ok then
            if type(overall) == "number" and overall > 0 then c.ilvl = floor(overall * 10) / 10 end
            if type(equipped) == "number" and equipped > 0 then c.ilvlEquipped = floor(equipped * 10) / 10 end
        end
    end

    if GetSpecialization and GetSpecializationInfo then
        local si = S(GetSpecialization)
        if type(si) == "number" and si > 0 then
            local sname, _, _, _, role = GetSpecializationInfo(si)
            c.spec = sname
            c.role = role
        end
    end

    -- 版本口径（账号级，所有角色一致）：看板据此标注"当前版本"，
    -- 也用于说明哪些旧内容被排除在统计之外
    local cc = ns.CurrentContent()
    local raidNamesT, poolT = {}, {}
    for _, r in ipairs(cc.raidNames) do raidNamesT[#raidNamesT + 1] = r.name end
    for _, p in ipairs(cc.pool) do poolT[#poolT + 1] = p.name end
    d.content = {
        detected      = cc.detected,
        tierIndex     = cc.tierIndex,
        tierName      = cc.tierName,
        raidNames     = raidNamesT,
        seasonID      = cc.seasonID,
        pool          = poolT,
        continentName = cc.continentName,
        updatedAt     = wi.now,
    }

    -- 各模块采集
    c.vault      = scanVault()
    c.mythicPlus = scanMythicPlus()
    c.raids      = scanRaids()

    -- 周常追踪器完成度：本周首扫做一次全量标记查询（见 ScanWeeklyDone 的说明）
    if type(c.weeklyQuests) ~= "table" or not c.weeklyQuests.doneTs then
        ns.ScanWeeklyDone(c)
    end

    -- 世界任务：账号级池。这里只负责「预热 + 延迟扫描」的触发，
    -- 因为是异步的，本次读到的会是上一次的快照（连续两次扫描后即最新）。
    if opts.maps then
        ns.ScanWorldQuests(opts.wqDelay or 0.8, { all = opts.wqAll })
    end

    -- 账号级快照：所有角色看到的是同一批世界任务，不重复存
    d.worldQuests = ns.WqPoolSnapshot()

    -- 角色级：本周出现过的世界任务（数据源＝账号级池），用于统计"已完成"
    local snap = d.worldQuests
    c.wqSeen = c.wqSeen or {}
    for _, e in ipairs(snap.list or {}) do
        local s = c.wqSeen[e.id]
        if not s then
            s = { title = e.title, zone = e.zone, money = 0, moneyKnown = false,
                  wqTypeName = e.wqTypeName, firstTs = wi.now }
            c.wqSeen[e.id] = s
        end
        if e.money > 0 then s.money = e.money; s.moneyKnown = true end
        if not s.title then s.title = e.title end
        if not s.zone  then s.zone  = e.zone  end
        -- 地图 ID（UiMap）也存一份：算「这个图本周做了几个世界任务」要用它当键，
        -- 光靠区域名会被同名/改名坑到。
        if not s.zid and e.zoneID then s.zid = e.zoneID end
        s.lastTs = wi.now
    end
    ns.PruneWqSeen(c)

    -- 本周世界任务完成度
    --   ★ v0.9.7：每条记录带周次戳（wk）★
    --   「做没做过」是**查询时刻**的权威状态，而查询只发生在「这个号登录时」。
    --   跨周之后，没再登录的号其 wqSeen 里还躺着**上周**的 completed —— 看板若
    --   照单全收，就会显示成「本周已完成」，与实际不符（实测症状：换号后
    --   其他号的 ✓ 忽有忽无）。给每条记录盖上查询时的周次 key，看板侧只信
    --   「wk == 本周」的记录；旧的 wk 视为过期观测，宁可靠「·」也不猜。
    local seenN, doneN, doneGold, doneGoldMoney = 0, 0, 0, 0
    local doneList = {}
    for qid, s in pairs(c.wqSeen or {}) do
        seenN = seenN + 1
        local flag = false
        if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
            flag = (S(C_QuestLog.IsQuestFlaggedCompleted, qid) == true)
        end
        s.completed = flag
        s.wk = wi.key
        if flag then
            doneN = doneN + 1
            if s.moneyKnown and s.money > 0 then
                doneGold = doneGold + 1
                doneGoldMoney = doneGoldMoney + s.money
                doneList[#doneList + 1] = { id = qid, title = s.title, zone = s.zone, money = s.money }
            end
        end
    end
    sort(doneList, function(a, b) return num(a.money) > num(b.money) end)
    c.wqWeek = {
        seen = seenN, done = doneN,
        doneGold = doneGold, doneGoldMoney = doneGoldMoney,
        doneGoldList = doneList,
    }

    c.scanTime = wi.now
    c.hasData = true

    -- 特别任务（角色级）--------------------------------------------------------
    -- 为什么要「问一遍全部已知特别任务」而不是只用扫到的：
    --   特别任务有解锁门槛 —— 没解锁时它**根本不会出现在地图上**，
    --   地图接口自然也读不到。只靠扫描就成了「解锁之后才看得见」，
    --   而看板要回答的恰恰是「还没解锁的还差几个」。
    --   所以这里对目录（Special.lua，客户端 DB2 生成）里的每个任务直接查完成状态；
    --   目录覆盖当前 + 历史版本，顺便能让看板把旧版本的也标出来。
    c.saSeen = c.saSeen or {}
    local saMap = ns.SA_QUEST
    if type(saMap) == "table" then
        for qid, meta in pairs(saMap) do
            local done = false
            if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
                done = (S(C_QuestLog.IsQuestFlaggedCompleted, qid) == true)
            end
            local s = c.saSeen[qid]
            if not s then s = { firstTs = wi.now }; c.saSeen[qid] = s end
            s.t   = meta.t  or s.t
            s.z   = meta.z  or s.z
            s.zn  = meta.zn or s.zn
            s.cur = (meta.cur == true)
            s.done = done
            s.ts  = wi.now
        end
    end

    -- 每张地图「本周完成的世界任务数」——「还差几个解锁」就靠它算。
    -- 两个来源，权威优先（为什么权威那个更可信见 ns.ScanUnlockTrackers 的说明）：
    --   ① 解锁追踪任务（游戏自己挂在角色身上的，进度就是游戏认的数）→ src="tracker"
    --   ② 回退：数本图 wqSeen 里 completed 的条数 → src="proxy"（只少不多）
    local zoneDone = {}
    for _qid, s in pairs(c.wqSeen or {}) do
        if s.zid and s.completed then
            zoneDone[s.zid] = (zoneDone[s.zid] or 0) + 1
        end
    end
    local trackers = ns.ScanUnlockTrackers(c)
    c.saUnlock = {}
    for mid, t in pairs(trackers) do
        c.saUnlock[mid] = { wq = num(t.wq), need = num(t.need), qid = t.qid,
                            unlocked = (t.unlocked == true), src = t.src }
        zoneDone[mid] = num(t.wq)      -- 权威值覆盖代理值
    end
    c.saZoneWq = zoneDone

    ns.lastScan = wi.now
    ns.MarkSession()   -- 当前登录角色：换号后会被新登录的角色覆盖
    return c
end

function ns.PruneWqSeen(c)
    if not c or type(c.wqSeen) ~= "table" then return end
    local n = 0
    for _ in pairs(c.wqSeen) do n = n + 1 end
    if n <= 600 then return end
    local arr = {}
    for qid, s in pairs(c.wqSeen) do arr[#arr + 1] = { qid = qid, ts = num(s.lastTs) } end
    sort(arr, function(a, b) return a.ts > b.ts end)
    local keep = {}
    for i = 1, 400 do if arr[i] then keep[arr[i].qid] = c.wqSeen[arr[i].qid] end end
    c.wqSeen = keep
end

function ns.PruneHistory()
    local d = db()
    local keys = {}
    for k in pairs(d.history) do keys[#keys + 1] = k end
    if #keys <= 12 then return end
    sort(keys)  -- 升序，删最旧
    for i = 1, #keys - 12 do d.history[keys[i]] = nil end
end

--==========================================================================
-- 事件回调
--==========================================================================
function ns.OnQuestData(questID, success)
    if type(questID) ~= "number" or not success then return end

    local r = ns.QuestRewards(questID)
    local rc = rewardCache()
    if not rc[questID] then r.ts = time(); rc[questID] = r end

    -- ★ v0.9.5：预载成功 = 这个任务的奖励数据已经被客户端算出来了，无论是
    --   有钱（>0）还是确认没钱（0），都写进永久记忆库。
    --   写 0 同样重要：它表示「已确认这个任务不给金币」，以后**不再为它发请求**。
    --   不写 0 的话，这类任务每周都会被重新请求一遍 —— 正是限流的另一半来源。
    MemoPut(questID, num(r.money))
    -- 直接回填进池：预载结果比等下一轮扫描更快点亮金币金额
    local e = wqPool().entries[questID]
    if e then
        if num(r.money) > 0 then e.money, e.moneyKnown = num(r.money), true end
        -- v0.9.35：这笔金额是**当前角色**读到的，打上归属，换角色时会被判为
        -- 「不作数」并重读（见 fillReward）
        e.moneyChar = (ns.CharKey and ns.CharKey()) or nil
        -- 这条奖励数据已经加载完了：此时读出来还是 0，就说明它**真的没有金币**，
        -- 而不是「还没读到」。两者必须在看板上分开 —— 否则「未读到」这个数字
        -- 会永远虚高，用户没法判断到底是漏扫了还是真没金币。
        e.moneyProbed = true
        e.rewardTried = nil
        -- 读到了就清掉「放弃名单」计数，免得被历史失败计数误伤
        local gm = giveUpMap()
        if gm[questID] then gm[questID] = nil end
        if type(r.currencies) == "table" and #r.currencies > 0 then e.currencies = r.currencies end
        if type(r.items) == "table" and #r.items > 0 then
            local items, n = {}, min(#r.items, 3)
            for i = 1, n do items[i] = r.items[i] end
            e.items = items
        end
        db().worldQuests = ns.WqPoolSnapshot()
    end
    ns.ThrottledScan(20)
end

--==========================================================================
-- 周常追踪器完成度（v0.9.11）
--   种子表来自 SavedInstances（ns.WEEKLY_TRACKERS，由 tools/si_extract.py 生成：
--   83 个追踪器 / 542 个任务 ID，随 SI 升级重跑即可）。
--
--   为什么完成记录必须自己记：SavedInstances 只在「当前角色交任务那一刻」
--   （hook GetQuestReward）写入当前角色的存档，别号这周的完成态它没有——
--   实测 36 个号只有当晚在线的那个有记录，其余全空（周重置时被清）。
--   我们两条腿：
--     1) 本周首扫全量过一遍全部任务 ID —— IsQuestFlaggedCompleted 查的是
--        服务器端完成标记，任务不在日志里也查得到；
--     2) QUEST_TURNED_IN 增量记一笔。
--   存放：c.weeklyQuests.done / .trackers / .doneTs。跨周时整个
--   weeklyQuests 块随归档清空，天然符合「周期层」口径。
--==========================================================================
local weeklyQSet, weeklyQTrack   -- 惰性建立（WeeklyQuests.lua 晚于 Core 加载）

local function ensureWeeklySets()
    if weeklyQSet then return true end
    if type(ns.WEEKLY_TRACKERS) ~= "table" then return false end
    weeklyQSet, weeklyQTrack = {}, {}
    for _, t in ipairs(ns.WEEKLY_TRACKERS) do
        for _, qid in ipairs(t.quests or {}) do
            weeklyQSet[qid] = true
            weeklyQTrack[qid] = t.id
        end
    end
    return true
end

-- 增量记账用的两个小工具（OnQuestTurnedIn 也会用到）
local function questInWeeklyTracker(qid)
    return ensureWeeklySets() and weeklyQSet[qid] or false
end

local function bumpTrackerDone(q, qid)
    local slug = ensureWeeklySets() and weeklyQTrack[qid]
    if not slug then return end
    q.trackers = q.trackers or {}
    local tr = q.trackers[slug]
    if not tr then
        -- 增量先到、全量还没跑：从种子表补出 total
        for _, t in ipairs(ns.WEEKLY_TRACKERS) do
            if t.id == slug then
                tr = { done = 0, total = #t.quests }
                q.trackers[slug] = tr
                break
            end
        end
    end
    if tr then tr.done = num(tr.done) + 1 end
end

-- 全量扫描：过一遍全部追踪器任务 ID，重建 done / trackers 两张表。
-- 返回完成总数（诊断用）。毫秒级（542 次本地完成标记查询）。
function ns.ScanWeeklyDone(c)
    if not c then return 0 end
    if not ensureWeeklySets() then return 0 end
    if not (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) then return 0 end
    local q = c.weeklyQuests
    if type(q) ~= "table" then q = { turnedIn = {}, totals = {} }; c.weeklyQuests = q end
    q.done, q.trackers = {}, {}
    for _, t in ipairs(ns.WEEKLY_TRACKERS) do
        q.trackers[t.id] = { done = 0, total = #t.quests }
        for _, qid in ipairs(t.quests) do
            if S(C_QuestLog.IsQuestFlaggedCompleted, qid) == true then
                q.done[qid] = true
            end
        end
    end
    -- 两遍数：避免同一任务 ID 出现在多个追踪器时重复计数
    local doneTotal = 0
    for _ in pairs(q.done) do doneTotal = doneTotal + 1 end
    for slug, tr in pairs(q.trackers) do
        for _, t in ipairs(ns.WEEKLY_TRACKERS) do
            if t.id == slug then
                for _, qid in ipairs(t.quests) do
                    if q.done[qid] then tr.done = tr.done + 1 end
                end
                break
            end
        end
    end
    q.doneTs = time()
    return doneTotal
end

function ns.OnQuestTurnedIn(questID, xpReward, moneyReward)
    if type(questID) ~= "number" then return end
    local d = db()
    local wi = ns.GetWeek()
    local name, realm = UnitName("player"), GetRealmName()
    if not name or not realm then return end
    local c = d.chars[ns.CharKey(name, realm)]
    if not c or type(c.week) ~= "table" or c.week.key ~= wi.key then
        -- 本周快照还没建立，先建
        c = ns.Scan({ maps = false })
        if not c then return end
    end

    local isWQ = false
    if C_QuestLog and C_QuestLog.IsWorldQuest then isWQ = (S(C_QuestLog.IsWorldQuest, questID) == true) end
    local isBounty = false
    if C_QuestLog and C_QuestLog.IsQuestBounty then isBounty = (S(C_QuestLog.IsQuestBounty, questID) == true) end

    local money = num(moneyReward)
    local xp = num(xpReward)
    local title = S(C_QuestLog.GetTitleForQuestID, questID)

    local q = c.weeklyQuests
    if type(q) ~= "table" then q = { turnedIn = {}, totals = {} }; c.weeklyQuests = q end
    q.turnedIn = q.turnedIn or {}
    q.totals = q.totals or {}
    q.ts = time()      -- 最后一次上交任务的时刻（weeklyQuests 这块数据的新鲜度依据）

    -- 周常追踪器增量记账（全量扫描见 ns.ScanWeeklyDone 的说明）
    if questInWeeklyTracker(questID) then
        q.done = q.done or {}
        if not q.done[questID] then
            q.done[questID] = true
            bumpTrackerDone(q, questID)
        end
    end

    local e = q.turnedIn[questID]
    if not e then
        e = { title = title, count = 0, money = 0, xp = 0, isWQ = isWQ, isBounty = isBounty }
        q.turnedIn[questID] = e
        q.totals.distinct = num(q.totals.distinct) + 1
    end
    e.title    = e.title or title
    e.count    = num(e.count) + 1
    e.money    = num(e.money) + money
    e.xp       = num(e.xp) + xp
    e.lastTs   = wi.now
    e.isWQ     = e.isWQ or isWQ
    e.isBounty = e.isBounty or isBounty

    local t = q.totals
    t.handins = num(t.handins) + 1
    t.gold    = num(t.gold) + money
    if isWQ then
        t.wq = num(t.wq) + 1
        t.wqGold = num(t.wqGold) + money
        -- 只有达到金币任务门槛的才算「金币任务」（零钱任务不计）
        if money >= ns.GoldWqFloor() then
            t.goldWQ = num(t.goldWQ) + 1
            t.goldWQMoney = num(t.goldWQMoney) + money
        end
    end
    if isBounty then t.bounty = num(t.bounty) + 1 end

    ns.ThrottledScan(10)
end

-- 节流：频繁事件（任务上交/预载回调/任务日志变化）不要每次都全量扫地图
local pendingScan
function ns.ThrottledScan(delay, withMaps)
    if pendingScan then return end
    pendingScan = true
    local d = delay or 8
    if C_Timer and C_Timer.After then
        C_Timer.After(d, function()
            pendingScan = nil
            ns.Scan({ maps = withMaps and true or false, silent = true, wqDelay = 0.8 })
        end)
    else
        pendingScan = nil
    end
end

--==========================================================================
-- 事件注册
--==========================================================================
--==========================================================================
-- 金币跟踪
--   GetMoney() 在 PLAYER_ENTERING_WORLD 之前恒返回 0（暴雪已知行为，文档写明
--   "Available after PLAYER_ENTERING_WORLD"），而登录早期那次扫描早于此，
--   所以之前采到的金币全是 0。这里在正确时点补采，并跟随金币变化持续更新。
--==========================================================================
-- 当前角色携带的金币
function ns.UpdateMoney()
    if not ns.moneyReady then return false end
    if not (UnitName and GetRealmName) then return false end
    local name, realm = UnitName("player"), GetRealmName()
    if not name or not realm then return false end
    local key = ns.CharKey(name, realm)
    local d = db()
    local c = d.chars[key]
    if not c then c = { key = key, name = name, realm = realm }; d.chars[key] = c end
    local m = num(S(GetMoney))
    if m > 0 then
        c.money   = m
        c.moneyTs = time()
        return true
    end
    return false
end

--==========================================================================
-- 战团银行金币（账号级）
--   暴雪不提供「一次读取所有角色携带金币」的接口 —— GetMoney() 只管当前登录角色，
--   角色选择界面也读不到。所以角色身上的金币只能靠「每个角色登录一次」累积。
--   但战团银行是账号共享的（跨角色、跨子账号），
--   C_Bank.FetchDepositedMoney(Enum.BankType.Account) 直接返回里面存的铜币，
--   任何角色登录都能读到同一个数 —— 这是唯一的官方「账号级金币」通路。
--   ⇒ 把金币放到战团银行，看板上的账号总额就是准的，不必逐个角色登一遍。
--==========================================================================
local function accountBankType()
    if Enum and Enum.BankType then
        return Enum.BankType.Account or Enum.BankType.Warband
    end
    return nil
end

function ns.UpdateWarband()
    if not (C_Bank and C_Bank.FetchDepositedMoney) then return false end
    local bt = accountBankType()
    if bt == nil then return false end
    local ok, amt = pcall(C_Bank.FetchDepositedMoney, bt)
    if not ok or type(amt) ~= "number" then return false end
    local d = db()
    if type(d.warband) ~= "table" then d.warband = {} end
    d.warband.money   = amt
    d.warband.ts      = time()
    d.warband.hasData = true
    return true
end

function ns.MarkMoneyReady()
    ns.moneyReady = true
    ns.UpdateMoney()
    ns.UpdateWarband()
end

ns.frame = CreateFrame("Frame")
local f = ns.frame
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("WEEKLY_REWARDS_UPDATE")
f:RegisterEvent("CHALLENGE_MODE_COMPLETED")
f:RegisterEvent("UPDATE_INSTANCE_INFO")
f:RegisterEvent("QUEST_TURNED_IN")
f:RegisterEvent("QUEST_DATA_LOAD_RESULT")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("QUEST_LOG_UPDATE")     -- 世界任务刷新 / 任务日志变化
f:RegisterEvent("TASK_PROGRESS_UPDATE") -- 世界任务进度变化
f:RegisterEvent("PLAYER_MONEY")
f:RegisterEvent("ACCOUNT_MONEY")       -- 战团银行金币变动
f:RegisterEvent("BANKFRAME_OPENED")    -- 打开银行时补读战团银行
f:RegisterEvent("PLAYER_LOGOUT")

local lastZoneScan = 0

f:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if event == "PLAYER_LOGIN" then
        db()
        -- 自诊断先落地：记录「加载到哪一步」，并把错误捕获挂上。
        --   放在最前 —— 后面任何一步出错（包括扫描）都能被记进存档。
        ns._flushBoot()
        ns._hookErrors()
        ns.MarkSession()      -- 先把「当前角色」记下来，扫描完成后再覆盖一次
        ns.ResetZoneCache()
        ns.ResetPreloadNotify()   -- 每个角色登录后，「限流提示」可以再说一次
        if RequestRaidInfo then pcall(RequestRaidInfo) end
        -- 扫两次：第一次尽早出一版；
        -- 第二次等世界任务数据加载完（实测约需 10~15 秒），否则会扫到空表
        if C_Timer and C_Timer.After then
            C_Timer.After(4,  function() ns.Scan({ maps = true, wqDelay = 1.0 }) end)
            C_Timer.After(22, function() ns.Scan({ maps = true, wqDelay = 1.5 }) end)
        else
            ns.Scan({ maps = true })
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        ns.MarkMoneyReady()
        ns.ResetZoneCache()
        if RequestRaidInfo then pcall(RequestRaidInfo) end
        -- 战团银行数据可能比人物金币晚一点就绪，8 秒后补读一次
        if C_Timer and C_Timer.After then
            C_Timer.After(8, function() ns.UpdateWarband() end)
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(6, function() ns.Scan({ maps = false }) end)
        else
            ns.Scan({ maps = false })
        end

    elseif event == "UPDATE_INSTANCE_INFO" then
        ns.Scan({ maps = false })

    elseif event == "WEEKLY_REWARDS_UPDATE" or event == "CHALLENGE_MODE_COMPLETED" then
        ns.Scan({ maps = false })

    elseif event == "QUEST_DATA_LOAD_RESULT" then
        ns.OnQuestData(a1, a2)

    elseif event == "QUEST_TURNED_IN" then
        ns.OnQuestTurnedIn(a1, a2, a3)
        -- 路线推进：交掉一站就撤它的路点、把箭头指向下一站（Route.lua）。
        -- 用 pcall + 存在性判断包住：Route.lua 是可选文件，
        -- 缺了它只应失去「自动推进」，不该让采集本身报错。
        if ns.AdvanceRoute then pcall(ns.AdvanceRoute, a1) end

    elseif event == "QUEST_LOG_UPDATE" or event == "TASK_PROGRESS_UPDATE" then
        -- 世界任务刷新/进度变化时池要跟着更新（节流，避免高频事件刷屏）
        ns.ThrottledScan(15, true)

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        -- 换区域后地图上的世界任务可能变了，每 3 分钟最多重扫一次
        local now = time()
        if now - lastZoneScan > 180 and not (InCombatLockdown and InCombatLockdown()) then
            lastZoneScan = now
            if C_Timer and C_Timer.After then
                C_Timer.After(10, function() ns.Scan({ maps = true, silent = true, wqDelay = 1.0 }) end)
            end
        end

    elseif event == "PLAYER_MONEY" then
        ns.UpdateMoney()

    elseif event == "ACCOUNT_MONEY" or event == "BANKFRAME_OPENED" then
        -- 战团银行金币是所有角色共享的，任何角色读到的是同一个数
        ns.UpdateWarband()

    elseif event == "PLAYER_LOGOUT" then
        -- 写入 SavedVariables 前的最后一次快照（同步，不能用定时器）
        ns.moneyReady = true      -- 登出时金币一定可读，强制放开护栏再采一次
        pcall(ns.Scan, { maps = true, silent = true, wqDelay = 0 })
        pcall(ns.UpdateWarband)
    end
end)

--==========================================================================
-- 世界任务：额外的采集时机
--   数据是异步加载的，且会随区域/时间变化，单靠登录那一次远远不够。
--==========================================================================

-- ① 打开世界地图时扫一次 —— 此刻客户端刚把所有区域的任务数据加载好，
--    是命中率最高的时机（WorldQuestTracker 也是这么做的）
local lastMapScan = 0
if WorldMapFrame and WorldMapFrame.HookScript then
    WorldMapFrame:HookScript("OnShow", function()
        local now = time()
        if now - lastMapScan < 30 then return end
        lastMapScan = now
        ns.ScanWorldQuests(1.2)
    end)
end

-- ② 定时兜底：每 4 分钟扫一次（战斗中跳过），世界任务会随刷新周期变化
if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(240, function()
        if InCombatLockdown and InCombatLockdown() then return end
        if not (UnitName and UnitName("player")) then return end

        -- ★ 跨周主动检测（v0.9.13）★
        --   以前是靠「下次 Scan / 下次交任务」惰性自愈：ns.Scan 与 ns.OnQuestTurnedIn
        --   都会校验 week.key 再归档，所以**写入路径本来就不会错写**（新一周的任务
        --   不会被记进旧周）。缺的只是「界面多久反映出来」—— 挂机跨过重置点后，
        --   除非你主动交个任务或 /reload，顶部「本周剩余」和上周快照会一直是旧的。
        --   这里每 4 分钟顺带看一眼时间，真跨了就先归档重扫一次、再刷一下看板。
        --   平时只多读一个时间，不产生扫描开销（跨周一周才发生一次）。
        local wk = ns.GetWeek()
        if ns._weekKeySeen == nil then ns._weekKeySeen = wk.key end
        if ns._weekKeySeen ~= wk.key then
            ns._weekKeySeen = wk.key
            ns.Scan({ maps = false })
            if ns.Board and ns.Board.Refresh and ns.Board.frame
                and ns.Board.frame:IsShown() then
                pcall(ns.Board.Refresh, ns.Board)
            end
        end

        ns.ScanWorldQuests(1.0)
    end)
end

-- 自诊断：把「本文件加载成功」记进 ns._mark 的内存轨迹。
--   别删 —— 加载期报错会让本文件**从出错那行起**的后续代码全不执行
--   （注意：**不影响别的文件**。WoW 每个 .lua 独立成一段 chunk，报错只中止这一段。
--    这点最初写反了，已在上面自诊断段更正）。
--   轨迹的正确读法：出现名字 = 这个文件走到底了；**缺谁就是谁在加载期挂了**。
--   实证：v0.9.15 时 Auction.lua 因事件名拼错在顶层抛错，轨迹里正好缺它一个。
if ns._mark then ns._mark("Core.lua") end
