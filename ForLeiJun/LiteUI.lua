--[[--------------------------------------------------------------------------
    ForLeiJun / LiteUI.lua
    对外第一版的主窗口：**只有两页**。

      世界任务 —— 本周还值得飞的金币世界任务，按走法排好序，点一行就导航
      拍卖行   —— 输入物品名或 ID，回车看最低一口价与在售量

    为什么只留这两页（v1.0 刻意的范围控制）
      这两件事是「边玩边看」的：站着等组队、飞在半路、拍卖行门口排队时都用得上。
      其余四个页签（总览 / 角色 / 金币 / 市场）吃的是本机 build.py 生成的
      快照 —— 对玩家既不准也没意义（那是作者自己的账号数据）。等口径梳理完
      再一页一页加，加一页就要能独立站住。

    数据口径（唯一重要的一条）
      这一页**不吃任何快照**：路线每次重画都现读 ns.RouteCandidates() 的实时池。
      所以交完一个任务，下一站立刻重排；快照型页面做不到这一点。
      hint 里永远写清「池快照几分钟前」，不让「刚扫的」和「两小时前的」看起来一样。

    和 full 版的关系
      渲染原语在 Render.lua（同一套实现、同一套配色）；置顶窗复用本文件的
      ns.RouteBlocks —— 主窗口与置顶窗看到的排序必须永远一致，所以只算一次。
--------------------------------------------------------------------------]]

local ADDON, ns = ...

local UI = ns.Board
local R = ns.Render
local num, goldStr, colorText = R.num, R.goldStr, R.colorText
local PAD, ROW_H = R.PAD, R.ROW_H

local W, H = 820, 560

local GOLD, GOLD_DIM, GOLD_BR = R.GOLD, R.GOLD_DIM, R.GOLD_BR
local TEXT, TEXT2, MUTED = R.TEXT, R.TEXT2, R.MUTED
local GOOD, WARN, BAD = R.GOOD, R.WARN, R.BAD

ns.LITE_VERSION = "1.4.2"
-- Core.lua 里的 VERSION 是自用版的版本号；对外包以 toc 的版本号为准
ns.VERSION = ns.LITE_VERSION

-- 页签表：唯一真相源（命令白名单也从这里派生）
ns.LITE_TABS = {
    { "do", "金币任务", "本周哪些最值钱" },
    { "ah", "拍卖快照", "没拍卖师也能查" },
}

local CFG_KEY = "ui"

--==========================================================================
-- 主窗四格大数卡的布局配置（v0.9.38 / lite 1.4.0）
--   「为了雷菌」主窗的四张卡（雷龙进度 / 这趟任务 / 这趟能拿 / 6小时内过期）
--   现在归工作台管：Layout.lua 的 ["main"] 就是它们的配置，这里归一化。
--   ★ 信任边界与 Pin.lua 同一条：卡上的大数与明细行（百分比/站数/金币/
--     快过期的任务名）全部现算，配置只管「显隐 / 顺序 / 摆法 / 文案」。
--   这是「工作台里改了四格、游戏里没反应」的根修：v0.9.37 只把配置
--   存进了 Layout.lua，游戏内根本没人读它。
--==========================================================================
local MAIN_CARDS = { "dragon", "trip", "take", "expire" }
local MAIN_CARD_LABEL = { dragon = "雷龙进度", trip = "这趟任务",
                          take = "这趟能拿", expire = "6 小时内过期" }

local function mainLayout()
    local src = (type(ns.LAYOUT) == "table") and ns.LAYOUT.main or nil
    if type(src) ~= "table" then src = {} end
    local M = { cols = (src.cols == 2) and 2 or 4 }

    local function flag(k)
        local s = src.show
        -- ⚠ false 是有意义的（用户就是要关这张卡），不能写成 `s[k] or nil` 三连
        if type(s) == "table" then return s[k] ~= false end
        return true
    end
    M.show = {}
    for _, k in ipairs(MAIN_CARDS) do M.show[k] = flag(k) end

    -- 顺序：配置里认得的先来，没列到的按默认补齐（只排要显示的卡）
    local seen, order = {}, {}
    for _, k in ipairs(type(src.order) == "table" and src.order or {}) do
        if M.show[k] and not seen[k] then
            seen[k] = true
            order[#order + 1] = k
        end
    end
    for _, k in ipairs(MAIN_CARDS) do
        if M.show[k] and not seen[k] then order[#order + 1] = k end
    end
    M.order = order

    M.card = {}
    for _, k in ipairs(MAIN_CARDS) do
        local c = (type(src[k]) == "table") and src[k] or {}
        M.card[k] = {
            label = (type(c.title) == "string" and c.title ~= "")
                        and c.title or MAIN_CARD_LABEL[k],
            -- 副标题 / 说明行：没配（空串）= 跟随实时默认值
            sub = (type(c.sub) == "string" and c.sub ~= "") and c.sub or nil,
            note = (type(c.note) == "string" and c.note ~= "") and c.note or nil,
            goal = tonumber(c.goal),   -- 万金；nil/<=0 = 用游戏内 /lj goal
        }
    end

    -- 页签文案覆盖（键来自 LITE_TABS，配了才覆盖）
    local tsrc = (type(src.tabs) == "table") and src.tabs or {}
    M.tabs = {}
    for _, spec in ipairs(ns.LITE_TABS) do
        local o = tsrc[spec[1]]
        if type(o) == "table" then
            M.tabs[spec[1]] = {
                label = (type(o.label) == "string" and o.label ~= "") and o.label or nil,
                sub = (type(o.sub) == "string" and o.sub ~= "") and o.sub or nil,
            }
        end
    end
    return M
end
ns.MainLayout = mainLayout     -- 测试与自检用

--==========================================================================
-- 存档（只记 UI 偏好，采集数据在 Core 的 chars / wqPool 里）
--==========================================================================
local function db()
    if type(ForLeiJunDB) ~= "table" then ForLeiJunDB = {} end
    return ForLeiJunDB
end

local function lastTab()
    local d = db()
    local ui = (type(d[CFG_KEY]) == "table") and d[CFG_KEY] or {}
    local t = tostring(ui.tab or "")
    for _, spec in ipairs(ns.LITE_TABS) do
        if spec[1] == t then return t end
    end
    return "do"
end

local function setLastTab(t)
    local d = db()
    if type(d[CFG_KEY]) ~= "table" then d[CFG_KEY] = {} end
    d[CFG_KEY].tab = t
end

--==========================================================================
-- 时间与格式化
--==========================================================================
local function fmtLeft(secs)
    secs = num(secs)
    if secs <= 0 then return "—" end
    if secs >= 86400 then
        local d = math.floor(secs / 86400)
        local h = math.floor((secs % 86400) / 3600)
        return (h > 0) and ("%d天%d小时"):format(d, h) or (d .. "天")
    end
    if secs >= 3600 then
        local h = math.floor(secs / 3600)
        local m = math.floor((secs % 3600) / 60)
        return (m > 0) and ("%d小时%d分"):format(h, m) or (h .. "小时")
    end
    return ("%d分"):format(math.max(1, math.floor(secs / 60)))
end

local function leftColor(secs)
    secs = tonumber(secs)
    if not secs then return MUTED end
    if secs <= 3600 then return BAD end
    if secs <= 6 * 3600 then return WARN end
    return MUTED
end

-- 池新鲜度：「刚刚 / N 分钟前 / N 小时前」
local function poolAge(scanAt)
    if type(scanAt) ~= "number" or scanAt <= 0 or type(time) ~= "function" then
        return "未知"
    end
    local m = math.floor((time() - scanAt) / 60)
    if m < 1 then return "刚刚" end
    if m < 60 then return m .. " 分钟前" end
    return math.floor(m / 60) .. " 小时前"
end

--==========================================================================
-- 攒钱进度：这个插件为什么存在
--   目标 = 一只雷龙坐骑。分子 = 各角色身上 + 战团银行（铜）。
--
--   口径必须写清：只累计「登录过」的角色。暴雪没有一次读全账号金币的接口
--   （GetMoney() 只管当前角色），没登过的号读到的是 0 —— 所以宁可显示
--   「还差多少 + 几个号有数据」，也不假装那个总数是准的。
--   战团银行是唯一的账号级金币通路，所以它单独加，不算重复。
--==========================================================================
local GOAL_DEFAULT_GOLD = 5000000   -- 金。默认按经典雷龙价，/lj goal 可改

local function goalGold()
    local g = tonumber(db().goal)
    if not g or g <= 0 then
        -- /lj goal 没设过 → 用工作台里配的雷龙目标；再没有才用出厂默认
        --   ⚠ 布局里的 goal 单位是「万金」，goalGold 返回「金」，要 ×10000
        local lg = tonumber(mainLayout().card.dragon.goal)
        if lg and lg > 0 then g = lg * 10000 end
    end
    if not g or g <= 0 then return GOAL_DEFAULT_GOLD end
    return g
end

local function totalGold()
    local d = db()
    local copper, known, chars = 0, 0, 0
    if type(d.chars) == "table" then
        for _, c in pairs(d.chars) do
            if type(c) == "table" then
                chars = chars + 1
                local m = num(c.money)
                if m > 0 then copper = copper + m; known = known + 1 end
            end
        end
    end
    local wb = (type(d.warband) == "table") and num(d.warband.money) or 0
    if wb > 0 then copper = copper + wb end
    return copper, known, chars
end

-- 目标金额解析：5000000 / 500w / 500万 都按「金」理解
local function parseGoal(s)
    s = tostring(s or ""):gsub("[,%s]", "")
    local n = tonumber(s:match("^([%d%.]+)[wW万]?$"))
    if not n then return nil end
    if s:find("[wW万]") then n = n * 10000 end
    return n
end

--==========================================================================
-- 世界任务页：实时路线 + 地图特别任务监控
--   两条信息，同一张表：
--     ① 现在飞哪几个金币任务、什么顺序（路线站，序号 + 坐标）
--     ② 每张图的特别任务解锁到什么程度、哪条此刻亮着、本周做完了哪些
--        （图名下的汇总行 + ★ 可做 + ✓ 已完成，点 ★ 行直接导航）
--   ② 的判定与行结构在 SaRows.lua，与自用版**同一份实现** —— 这套判定
--   返工过四次，复制一份到对外版必然漂移（玩家看到的和作者看到的不是
--   同一件事）。本文件只负责把它拼进表格。
--==========================================================================
local function buildRoute()
    local blocks = {}
    if not (ns.RouteCandidates and ns.BuildRoute) then
        blocks[#blocks + 1] = { note = "路线模块没加载（Route.lua）—— 插件安装不完整。" }
        return blocks
    end

    -- 每次重绘清一次渲染内缓存（完成状态是要现问客户端的，不能读上一屏的答案）
    if ns.SaRowsReset then ns.SaRowsReset() end

    local ok, cand, scanAt = pcall(ns.RouteCandidates)
    if not ok or type(cand) ~= "table" then
        blocks[#blocks + 1] = { note = "读不到世界任务池 —— 先打开地图（M）让它采集一次。" }
        return blocks
    end

    local zoneOrder
    if ns.ZoneOrder and ns.RouteZoneIDs then
        local okZ, zo = pcall(function() return ns.ZoneOrder(ns.RouteZoneIDs(cand)) end)
        if okZ then zoneOrder = zo end
    end

    local okR, route, dropped = pcall(ns.BuildRoute, cand, { zoneOrder = zoneOrder })
    if not okR or type(route) ~= "table" then
        blocks[#blocks + 1] = { note = "路线计算失败 —— 输入 /lj scan 重新采集，仍不行请反馈。" }
        return blocks
    end

    -- ── 顶部四格：目标进度 + 这一趟的总量 ────────────────────────
    local goldSum, soonN = 0, 0
    for _, it in ipairs(route) do
        goldSum = goldSum + num(it.money)
        local ls = tonumber(it.leftSeconds)
        if ls and ls <= 6 * 3600 then soonN = soonN + 1 end
    end

    -- 四格的配置（显隐/顺序/文案）—— v0.9.38 起真的生效
    local ML = mainLayout()
    local takeNote = ML.card.take.note or "任务实发，不含掉落"
    local expireNote = ML.card.expire.note or "都不着急"

    -- 卡片明细行（2026-10-18 用户要求：大数下面直接列出构成，别只给一个总数）
    --   「这趟能拿」按 canon 地图聚合（与下表同一分组口径，子区域并回所属图）；
    --   「6h 过期」逐任务列名 + 金币，按剩余时间升序（最急的在最上面）。
    --   行数有上限，超出给「…还有 N」——完整明细本来就在下表，卡片是速览。
    local byZone, zoneSeq = {}, {}
    for _, it in ipairs(route) do
        local zk = (ns.RouteZoneKey and ns.RouteZoneKey(it)) or tonumber(it.mapID)
        local z = byZone[zk]
        if not z then
            z = { n = 0, gold = 0,
                  name = (ns.ZoneName and ns.ZoneName(zk)) or tostring(it.zone or "?") }
            byZone[zk] = z
            zoneSeq[#zoneSeq + 1] = zk
        end
        z.n = z.n + 1
        z.gold = z.gold + num(it.money)
    end
    local soon = {}
    for _, it in ipairs(route) do
        local ls = tonumber(it.leftSeconds)
        if ls and ls <= 6 * 3600 then soon[#soon + 1] = it end
    end
    table.sort(soon, function(a, b)
        return (tonumber(a.leftSeconds) or 0) < (tonumber(b.leftSeconds) or 0)
    end)

    local gainLines = {}
    for i = 1, math.min(3, #zoneSeq) do
        local z = byZone[zoneSeq[i]]
        gainLines[#gainLines + 1] =
            { t = ("%s ×%d · %s金"):format(z.name, z.n, goldStr(z.gold)), c = TEXT2 }
    end
    if #zoneSeq > 3 then
        gainLines[#gainLines + 1] =
            { t = ("…还有 %d 张图，见下表"):format(#zoneSeq - 3), c = MUTED }
    elseif #zoneSeq > 0 then
        gainLines[#gainLines + 1] = { t = takeNote, c = MUTED }
    end

    local soonLines = {}
    for i = 1, math.min(4, #soon) do
        local it = soon[i]
        local urgent = (tonumber(it.leftSeconds) or math.huge) <= 2 * 3600
        soonLines[#soonLines + 1] = {
            t = ("%s · %s金"):format(tostring(it.title or ("任务#" .. tostring(it.id))),
                                     goldStr(it.money)),
            c = urgent and WARN or TEXT2,
        }
    end
    if #soon > 4 then
        soonLines[#soonLines + 1] =
            { t = ("…还有 %d 个，见下表"):format(#soon - 4), c = MUTED }
    end

    local have = totalGold()
    local goalC = goalGold() * 10000
    local pct = (goalC > 0) and math.min(1, have / goalC) or 0
    local progV, progS, progC
    if have <= 0 then
        progV, progS, progC = "—", "登录一次就有数了", MUTED
    else
        progV = ("%.1f%%"):format(pct * 100)
        progS = "还差 " .. goldStr(math.max(0, goalC - have)) .. " 金"
        progC = (pct >= 1) and GOOD or GOLD_BR
    end

    -- 「雷龙进度」明细行（v1.4.1，与工作台原型对齐）：大数下面列出金币构成 ——
    --   全部现算，不进配置。★ 第一行固定是「还差 X 金」：DrawGrid 明细模式下
    --   副标题不单独画，丢了它用户就看不到缺口了。
    --   v1.4.2 收敛到最多 4 行：前 2 个号 + 战团银行 + 短口径行 ——
    --   真机反馈行数太多放不下（窄卡上长文案还被截断）。
    local dragonLines = {}
    if have > 0 then
        dragonLines[#dragonLines + 1] = { t = progS, c = TEXT2 }
        local parts = {}
        for k, c in pairs(db().chars or {}) do
            local m = num(type(c) == "table" and c.money or nil)
            if m > 0 then
                parts[#parts + 1] = {
                    name = tostring(k):match("%-(.+)$") or tostring(k),
                    money = m,
                }
            end
        end
        table.sort(parts, function(a, b) return a.money > b.money end)
        for i = 1, math.min(2, #parts) do
            local p = parts[i]
            -- p.money 是铜子 → 万金要除 1e8（/10000 金 → /10000 万）
            dragonLines[#dragonLines + 1] =
                { t = ("%s · %s万"):format(p.name, ("%.1f"):format(p.money / 100000000)), c = TEXT2 }
        end
        local wb = (type(db().warband) == "table") and num(db().warband.money) or 0
        if wb > 0 then
            dragonLines[#dragonLines + 1] =
                { t = ("战团银行 · %.1f万"):format(wb / 100000000), c = TEXT2 }
        end
        dragonLines[#dragonLines + 1] = { t = "只算登录过的角色", c = MUTED }
    end

    -- 四张卡按配置拼：显隐 / 顺序 / 卡标题 / 副标题与说明行覆盖。
    --   大数与明细行（站数、金币、快过期的任务）全部现算，不进配置。
    --   v1.4.2 卡片可交互：雷龙/能拿/过期三张卡点一下收起/展开明细（tkey），
    --   收起状态存 db().ui.collapse，标题带 ▾/▸ 提示可点。
    local coll = db().ui
    coll = (type(coll) == "table" and type(coll.collapse) == "table") and coll.collapse or {}
    local function cardLabel(k, label)
        return label .. (coll[k] and " ▸" or " ▾")
    end
    local tripSub = (#route > 0) and "按走法排好序" or "现在没有可去的"
    if ML.card.trip.sub then tripSub = ML.card.trip.sub end
    local cardMap = {
        dragon = { l = cardLabel("dragon", ML.card.dragon.label), v = progV, vc = progC,
                   s = progS, tkey = "dragon",
                   lines = (not coll.dragon) and dragonLines or nil, p = pct * 100 },
        trip   = { l = ML.card.trip.label, v = #route .. " 站",
                   vc = (#route > 0) and GOLD_BR or MUTED, s = tripSub },
        take   = { l = cardLabel("take", ML.card.take.label), v = goldStr(goldSum) .. " 金",
                   vc = (goldSum > 0) and GOLD_BR or MUTED, s = takeNote, tkey = "take",
                   lines = (not coll.take) and gainLines or nil },
        expire = { l = cardLabel("expire", ML.card.expire.label), v = soonN .. " 个",
                   vc = (soonN > 0) and WARN or MUTED, s = expireNote, tkey = "expire",
                   lines = (not coll.expire) and soonLines or nil },
    }
    local cards = {}
    for _, k in ipairs(ML.order) do cards[#cards + 1] = cardMap[k] end
    if #cards > 0 then
        blocks[#blocks + 1] = { grid = cards }
    end

    -- ── 路线表 ──────────────────────────────────────────────────
    local rows, items = {}, {}
    local lastZone
    local visitedZones = {}   -- canon zk → 已画过组头（补覆盖用）
    local saRowsN = 0

    -- ★ v1.3.6 每图汇总（置顶窗路线卡用）：站数 + 合计金币 + 特别任务状态。
    --   与下面的表格同一份路线数据（同一循环里累计），不会漂移。
    local agg, aggOrder = {}, {}
    local function aggZone(zk, fallbackName)
        local a = agg[zk]
        if not a then
            a = { zk = zk, n = 0, gold = 0,
                  name = (ns.ZoneName and ns.ZoneName(zk)) or tostring(fallbackName or zk) }
            agg[zk] = a
            aggOrder[#aggOrder + 1] = zk
        end
        return a
    end

    -- 一张图的特别任务行（实现在 SaRows.lua，full 与 lite 同一份）
    --   force=true 这张图有路线站，组头反正要画；false 只在「有话可说」时画。
    local function emitSAForZone(zk, force)
        if not ns.SaRowsForZone then return false end
        local srows, sitems, any, n = ns.SaRowsForZone(zk, force)
        if type(srows) == "table" then
            for _, r in ipairs(srows) do rows[#rows + 1] = r end
            for _, it in ipairs(sitems or {}) do items[#items + 1] = it end
        end
        saRowsN = saRowsN + num(n)
        return any
    end

    local function zoneHeader(zk, label)
        rows[#rows + 1] = {
            hdr = true,   -- 渲染层据此画顶部粗线 + 淡金底（按地图分框，与自用版同款）
            { t = colorText(GOLD_DIM, "▼") },
            { t = colorText(GOLD_DIM, label or tostring(zk)) },
            { t = "" }, { t = "" }, { t = "" },
        }
        items[#items + 1] = { header = true }
    end

    for i, it in ipairs(route) do
        local zk = (ns.RouteZoneKey and ns.RouteZoneKey(it)) or tonumber(it.mapID)
        local aggz = aggZone(zk, it.zone)
        aggz.n = aggz.n + 1
        aggz.gold = aggz.gold + num(it.money)
        -- 这张图最近一站的剩余时间（v0.9.36：卡片剩余行 / 按剩余排序用）
        local als = tonumber(it.leftSeconds)
        if als and als > 0 and (not aggz.leftSeconds or als < aggz.leftSeconds) then
            aggz.leftSeconds = als
        end
        if zk ~= lastZone then
            lastZone = zk
            visitedZones[zk] = true
            zoneHeader(zk, (ns.ZoneName and ns.ZoneName(zk)) or tostring(it.zone or "?"))
            -- 图名下面紧跟特别任务：解锁进度 / 亮着的 ★ / 本周做完的 ✓
            emitSAForZone(zk, true)
        end
        local lt = tostring(it.leftText or "")
        local ls = tonumber(it.leftSeconds)
        local leftCell = (lt ~= "") and colorText(leftColor(ls), lt) or colorText(MUTED, "—")
        local x, y = tonumber(it.x), tonumber(it.y)
        rows[#rows + 1] = {
            { t = tostring(i) .. ".", c = MUTED },
            { t = tostring(it.title or ("任务#" .. tostring(it.id))), c = TEXT },
            { t = goldStr(it.money) .. " 金", c = GOLD },
            { t = leftCell },
            { t = (x and y) and ("%.0f, %.0f"):format(x * 100, y * 100) or "?", c = MUTED },
        }
        items[#items + 1] = it
    end

    -- 路线没覆盖的图也要有踪迹：某张图解锁了特别任务、但此刻没有值得导航的
    -- 金币任务时，整组会连 SA 行一起消失，已解锁的特别任务就凭空不见了
    -- （自用版 2026-10-17 实测过这个坑，口径照抄）。
    if type(ns.SA_MAPS) == "table" then
        local extra = {}
        for m, meta in pairs(ns.SA_MAPS) do
            if type(meta) == "table" and meta.cur ~= false then
                local cm = (ns.CanonZoneMap and ns.CanonZoneMap(m)) or m
                if not visitedZones[cm] then extra[cm] = true end
            end
        end
        local keys = {}
        for cm in pairs(extra) do keys[#keys + 1] = cm end
        table.sort(keys, function(a, b)
            local na = (ns.ZoneName and ns.ZoneName(a)) or tostring(a)
            local nb = (ns.ZoneName and ns.ZoneName(b)) or tostring(b)
            if na == nb then return a < b end
            return na < nb
        end)
        for _, cm in ipairs(keys) do
            visitedZones[cm] = true
            emitSAForZone(cm, false)
            aggZone(cm)   -- 没有路线站的 SA 图也有一张卡（n=0，只有状态块）
        end
    end

    -- 每图汇总卡：挂在 table.maps 上，置顶窗（Pin.lua）取用；主看板暂不画。
    local mapCards = {}
    for _, zk in ipairs(aggOrder) do
        local a = agg[zk]
        local st, stx = "none", ""
        if ns.SaZoneState then
            local okS, s1, s2 = pcall(ns.SaZoneState, zk)
            if okS then st, stx = s1 or "none", s2 or "" end
        end
        mapCards[#mapCards + 1] = { zk = zk, name = a.name, n = a.n, gold = a.gold,
                                    leftSeconds = a.leftSeconds,
                                    sa = st, saText = stx }
    end

    if #route == 0 then
        rows[#rows + 1] = {
            { t = "" },
            { t = colorText(MUTED, "现在没有可导航的金币世界任务（可能都做完了，或池还没扫）") },
            { t = "" }, { t = "" }, { t = "" },
        }
        items[#items + 1] = { header = true }
        rows[#rows + 1] = {
            { t = colorText(GOLD, "▶") },
            { t = colorText(GOLD, "立即扫描一次世界任务") },
            { t = "" }, { t = "" }, { t = "" },
        }
        items[#items + 1] = { action = "scan" }
    else
        -- 动作行（表格最后一行，不是数据）
        --   ★ 对外版只用暴雪原生路点（Wpt.lua），一次只能标一格 ★
        --   所以这里说的是「标出当前站」，不是「发给某某插件」——
        --   玩家装不装 TomTom / WaypointUI，这句话都成立。
        local left = 0
        if ns.RouteCurrent then
            local _, _, n = ns.RouteCurrent()
            left = tonumber(n) or 0
        end
        rows[#rows + 1] = {
            { t = colorText(GOLD, "▶") },
            { t = colorText(GOLD, (left > 0)
                and ("重新标出当前站（还剩 " .. left .. " 站）")
                or "开始跑这条路线（在图上标出第 1 站）") },
            { t = "" }, { t = "" }, { t = "" },
        }
        items[#items + 1] = { action = "send" }

        if left > 0 then
            rows[#rows + 1] = {
                { t = colorText(MUTED, "✕") },
                { t = colorText(MUTED, "清掉路线标记（只清本插件打的，不动你自己的点）") },
                { t = "" }, { t = "" }, { t = "" },
            }
            items[#items + 1] = { action = "clear" }
        end
    end

    local hint = ("%d 站 · 池快照 %s · 剩余时间随池重扫更新"):format(#route, poolAge(scanAt))
        .. " · 一次标一站，交完自动指下一站"
        .. (saRowsN > 0 and " · 图名下附特别任务（★＝可做 · ✓＝本周已完成）" or "")
    blocks[#blocks + 1] = { h = "实时路线", hint = hint }
    blocks[#blocks + 1] = { table = {
        head = { { t = "序", w = 44, a = "l" }, { t = "任务", w = 336, a = "l" },
                 { t = "单次", w = 110, a = "r" }, { t = "剩余", w = 100, a = "r" },
                 { t = "坐标", w = 110, a = "r" } },
        rows = rows,
        click = function(_, ri)
            local it = items[ri]
            if type(it) ~= "table" then return end
            if it.action == "scan" then
                if ns.Scan then pcall(ns.Scan, { maps = true }) end
            elseif it.action == "send" then
                if ns.SendRoute then pcall(ns.SendRoute) end
            elseif it.action == "clear" then
                if ns.ClearRoute then pcall(ns.ClearRoute) end
            elseif it.header then
                return
            elseif ns.GotoQuest then
                -- GotoQuest 内部已延迟一帧执行（不能在按钮回调栈上碰 WorldMapFrame）
                pcall(ns.GotoQuest, it)
            end
            UI:SafeRefresh()
        end,
        tip = function(row)
            local c1 = tostring(row[1] and row[1].t or "")
            if c1:find("▶", 1, true) then
                return { { t = "开始跑这条路线：在地图上标出当前站（小地图上也有）" },
                         { t = "用的是暴雪自带的地图标记，不需要装任何路点插件；"
                             .. "一次只标一站，交掉当前站会自动指下一站",
                           r = 0.72, g = 0.67, b = 0.55 } }
            end
            if c1:find("✕", 1, true) then
                return { { t = "只清本插件打的标记，不动你自己标的点" } }
            end
            if c1:find("▼", 1, true) then
                return { { t = "同一张图里的任务已经排在一起，按上面的顺序走最近" } }
            end
            return { { t = "点这一行：挂追踪 + 打路点 + 打开地图" },
                     { t = "顺序＝区域由近到远，区内最近邻 + 2-opt",
                       r = 0.72, g = 0.67, b = 0.55 } }
        end,
    } }
    -- ★ v1.3.6：每图汇总卡随表走（置顶窗画，字段见上面 mapCards 注释）
    blocks[#blocks].table.maps = mapCards

    -- 剔除原因要摊开说，否则「为什么这几个没进路线」会被当成 bug
    local skip = 0
    if type(dropped) == "table" then
        skip = num(dropped.done) + num(dropped.nocoord) + num(dropped.unprobed) + num(dropped.below)
    end
    if skip > 0 then
        blocks[#blocks + 1] = { note = ("另有 %d 条没排进来：已完成 %d · 没坐标 %d · 奖励没读到 %d · 没到金币门槛 %d")
            :format(skip, num(dropped.done), num(dropped.nocoord),
                    num(dropped.unprobed), num(dropped.below)) }
    end
    if #route == 0 then
        blocks[#blocks + 1] = { note = "提示：打开世界地图（M）会自动采集一次，不用敲命令。" }
    end
    return blocks
end

-- 导出给置顶窗（Pin.lua）：主窗口与置顶窗共用同一份表格与同一个点击行为
ns.RouteBlocks = buildRoute

--==========================================================================
-- 拍卖行页
--   搜索规则在 Pin.lua（ns.PinSearchItems）—— 主窗口与置顶窗必须同一套
--   排序（完全匹配优先 → 名字短的优先 → 单价高的优先），否则同一次搜索
--   在两个窗口里给出不同答案。
--==========================================================================
local AH_LIMIT = 400

local function ahSearch(q)
    if type(ns.PinSearchItems) == "function" then
        local ok, res, scanned, truncated = pcall(ns.PinSearchItems, q)
        if ok then return res or {}, num(scanned), truncated end
    end
    return {}, 0, false
end

-- 快照状态：这一页卖的就是「附近没拍卖师也能查」，所以第一行永远是
-- 「这是多久前的价」—— 3 天前的价不能看起来跟刚才的一样。
local function ahSnapshot()
    local okA, a = pcall(function() return (ns.AH and ns.AH.db) and ns.AH.db() end)
    if not okA or type(a) ~= "table" then return 0, 0 end
    return num(a.itemCount), num(a.lastScanTs)
end

local function snapshotNote(n, ts)
    if n <= 0 then
        return "还没有价格快照 —— 打开拍卖行点「刷新周报价格」扫描一次（约 10 秒）。"
    end
    local age = (ns.AH and ns.AH.LastScanText and ns.AH.LastScanText()) or "未知"
    if type(time) == "function" and ts > 0 and (time() - ts) >= 48 * 3600 then
        return ("价格快照：%s · %d 种物品 —— 太旧了，建议去拍卖行更新一次。"):format(age, n)
    end
    return ("价格快照：%s · %d 种物品 · 不在拍卖行时看到的就是这份。"):format(age, n)
end

local function buildAH()
    local blocks = {}
    local q = UI.ahQuery or ""
    local snapN, snapTs = ahSnapshot()
    blocks[#blocks + 1] = { note = snapshotNote(snapN, snapTs) }

    -- 空查询：给引导，而不是一张空表
    if q == "" then
        blocks[#blocks + 1] = { note = "在上面输入物品名（如「附魔」）或物品 ID，回车查询。" }
        return blocks
    end

    local res, scanned, truncated = ahSearch(q)
    local head = { { t = "物品", w = 300, a = "l" }, { t = "一口价(金)", w = 110, a = "r" },
                   { t = "在售", w = 70, a = "r" }, { t = "货值(金)", w = 110, a = "r" } }

    local rows, items = {}, {}
    for _, r in ipairs(res) do
        rows[#rows + 1] = {
            -- id 藏在第一格里：tip 回调只拿得到 row，靠 ri 反查又慢又不可靠
            --（与置顶窗拍卖窗同款做法）
            { t = r.nm, c = TEXT, id = r.id },
            { t = r.u > 0 and goldStr(r.u) or colorText(MUTED, "—"), c = TEXT2 },
            { t = num(r.n), c = TEXT2 },
            { t = r.u > 0 and goldStr(r.u * num(r.n)) or colorText(MUTED, "—"), c = GOLD },
        }
        items[#items + 1] = r
    end
    if #rows == 0 then
        rows[#rows + 1] = {
            { t = colorText(MUTED, "没有匹配的物品 —— 换个关键词，或直接输物品 ID") },
            { t = "" }, { t = "" }, { t = "" },
        }
        items[#items + 1] = { header = true }
    end

    local hint = ("「%s」命中 %d 种"):format(q, #res)
    if truncated then hint = hint .. ("（最多显示 %d，请再具体些）"):format(AH_LIMIT) end
    if scanned > 0 then hint = hint .. (" · 扫过 %d 条"):format(scanned) end

    blocks[#blocks + 1] = { h = "搜索结果", hint = hint }
    blocks[#blocks + 1] = { table = {
        head = head,
        rows = rows,
        click = function(_, ri)
            local it = items[ri]
            if type(it) ~= "table" or it.header or not it.id then return end
            -- 点一行把物品链接塞进聊天框：问价、发给朋友都用得上
            local link = select(2, GetItemInfo(it.id))
            if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
        end,
        tip = function(row)
            local id = row and row[1] and row[1].id
            -- 悬停铺物品本体（图标/名称/等级），价格行追加在下面 ——
            -- 与置顶窗拍卖窗同一个口径；没有 id（空行）就只出说明。
            if GameTooltip and id then pcall(GameTooltip.SetItemByID, GameTooltip, id) end
            local it
            if id then
                for _, r0 in ipairs(res) do if r0.id == id then it = r0; break end end
            end
            local lines = {}
            if it then
                if it.u > 0 then
                    lines[#lines + 1] = { t = ("最低一口价 %s 金 · 在售 %d 个"):format(goldStr(it.u), num(it.n)) }
                    lines[#lines + 1] = { t = ("总货值 %s 金"):format(goldStr(it.u * num(it.n))),
                                          r = 0.72, g = 0.67, b = 0.55 }
                else
                    lines[#lines + 1] = { t = "快照里这个物品当前没有一口价（可能只有人堆叠竞价）",
                                          r = 0.72, g = 0.67, b = 0.55 }
                end
            end
            lines[#lines + 1] = { t = "点这一行：把物品链接放进聊天框" }
            return lines
        end,
    } }
    blocks[#blocks + 1] = { note = "价格来自本插件自己的拍卖行扫描，不是全网均价；过期物品可能已被买走。" }
    return blocks
end

-- 卡片收起/展开（v1.4.2）：DrawGrid 里 tkey 卡的 OnMouseUp 调到这里。
--   状态存 db().ui.collapse，重载后保持。
function UI:CardToggle(k)
    local d = db()
    if type(d.ui) ~= "table" then d.ui = {} end
    if type(d.ui.collapse) ~= "table" then d.ui.collapse = {} end
    d.ui.collapse[k] = (not d.ui.collapse[k]) or nil
    self:Refresh()
end

--==========================================================================
-- 刷新
--==========================================================================
function UI:Refresh()
    if not self.frame then return end
    self:Reset()
    self:Layout()

    -- 内容宽度跟窗口实际宽度走（v1.4.2 支持拖右下角改窗大小）；
    --   下限仍不出厂宽（表格布局按这个宽算的，再窄就挤坏了）。测试桩
    --   GetWidth 恒回 100，用 max 兑回出厂宽，断言不受影响。
    local width = math.max((self.frame.GetWidth and self.frame:GetWidth()) or 0, W)
    width = width - PAD * 2 - 24
    local blocks
    if self.tab == "ah" then blocks = buildAH() else blocks = buildRoute() end

    local y = 0
    for _, b in ipairs(blocks) do
        if b.h then
            y = self:DrawHead(b.h, b.hint, y, width)
        elseif b.note then
            y = self:DrawNote(b.note, y)
        elseif b.grid then
            -- 2×2 摆法（v0.9.38）：把卡两两一排交给 DrawGrid ——
            --   DrawGrid 本身只会画一行，分排的活儿在这几做。
            local ML2 = mainLayout()
            if ML2.cols == 2 and #b.grid > 2 then
                for i = 1, #b.grid, 2 do
                    local chunk = {}
                    for j = i, math.min(i + 1, #b.grid) do chunk[#chunk + 1] = b.grid[j] end
                    y = self:DrawGrid(chunk, y, width)
                end
            else
                y = self:DrawGrid(b.grid, y, width)
            end
        elseif b.table then
            y = self:DrawTable(b.table, y, width) + 14
        end
    end

    self.content:SetWidth(width - 8)
    self.content:SetHeight(math.max(y + 8, 10))
    self.scroll:SetVerticalScroll(0)
    for _, b in ipairs(self.tabs or {}) do
        b:SetActive(b._key == self.tab)
    end
    if self.searchBar then
        if self.tab == "ah" then self.searchBar:Show() else self.searchBar:Hide() end
    end
end

-- 内容区起点随搜索条有无变化（早先固定锚点会让搜索框压住第一行）
function UI:Layout()
    if not (self.scroll and self.frame) then return end
    local top = (self.tab == "ah") and 112 or 82
    self.scroll:ClearAllPoints()
    self.scroll:SetPoint("TOPLEFT", self.frame, "TOPLEFT", PAD, -top)
    self.scroll:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -(PAD + 12), PAD + 4)
end

function UI:SetTab(key)
    self.tab = key
    setLastTab(key)
    self:Refresh()
end

--==========================================================================
-- 拍卖搜索条（只在拍卖页显示）
--==========================================================================
local function buildSearchBar(f)
    local holder = CreateFrame("Frame", nil, f)
    -- 位置随页签切换（Layout 只动 scroll，搜索条固定在页签下方）
    holder:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -82)
    holder:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(PAD + 12), -82)
    holder:SetHeight(24)
    R.box(holder, 1, 1, 1, 0.05):SetAllPoints()
    holder:Hide()

    local eb = CreateFrame("EditBox", "ForLeiJunAHEdit", holder)
    eb:SetPoint("TOPLEFT", holder, "TOPLEFT", 6, -2)
    eb:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -66, 2)
    eb:SetFontObject("ChatFontNormal")
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(40)
    eb:SetTextInsets(2, 2, 0, 0)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self)
        local q = self:GetText() or ""
        self:ClearFocus()
        UI.ahQuery = q
        UI:Refresh()
    end)
    UI.edit = eb

    local ph = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ph:SetPoint("LEFT", holder, "LEFT", 8, 0)
    ph:SetText(colorText("ff8a7f66", "物品名或 ID，回车查询"))
    eb:SetScript("OnEditFocusGained", function() ph:Hide() end)
    eb:SetScript("OnEditFocusLost", function()
        if (eb:GetText() or "") == "" then ph:Show() else ph:Hide() end
    end)
    UI.placeholder = ph

    local go = CreateFrame("Button", nil, holder)
    go:SetSize(56, 20)
    go:SetPoint("RIGHT", holder, "RIGHT", -4, 0)
    local gt = go:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gt:SetPoint("CENTER")
    gt:SetText(colorText(GOLD, "查询"))
    go:SetScript("OnClick", function()
        local q = eb:GetText() or ""
        eb:ClearFocus()
        UI.ahQuery = q
        UI:Refresh()
    end)

    UI.searchBar = holder
    return holder
end

--==========================================================================
-- 窗口
--==========================================================================
function UI:Build()
    if self.frame then return self.frame end

    local f = CreateFrame("Frame", "ForLeiJunMain", UIParent)
    f:SetSize(W, H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameLevel(20)
    f:Hide()
    self.frame = f

    R.box(f, R.BG[1], R.BG[2], R.BG[3], R.BG[4]):SetAllPoints()
    -- 四条边手画（不依赖 Backdrop 模板）；v1.4.2 起窗子可拖拽改大小，
    --   边框必须两头锚定拉伸，不能再用出厂宽高写死。
    local function edgeH(anchor)
        local t = R.box(f, R.EDGE[1], R.EDGE[2], R.EDGE[3], 1)
        t:SetPoint("TOPLEFT", f, anchor, 0, 0)
        t:SetPoint("TOPRIGHT", f, anchor, 0, 0)
        t:SetHeight(2)
        return t
    end
    local function edgeV(anchor)
        local t = R.box(f, R.EDGE[1], R.EDGE[2], R.EDGE[3], 1)
        t:SetPoint("TOPLEFT", f, anchor, 0, 0)
        t:SetPoint("BOTTOMLEFT", f, anchor, 0, 0)
        t:SetWidth(2)
        return t
    end
    edgeH("TOPLEFT"); edgeH("BOTTOMLEFT"); edgeV("TOPLEFT"); edgeV("TOPRIGHT")

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- 右下角拖拽改窗大小（v1.4.2）：松手存档并重排内容。
    --   下限 = 出厂尺寸（表格按出厂宽算的布局，再窄就挤坏）。
    f:SetResizable(true)
    if f.SetResizeBounds then f:SetResizeBounds(W, H)
    else pcall(function() f:SetMinResize(W, H) end) end
    local grip = CreateFrame("Frame", nil, f)
    grip:SetSize(18, 18)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -3, 3)
    grip:EnableMouse(true)
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        local w = math.max(W, math.floor((f:GetWidth() or W) + 0.5))
        local h = math.max(H, math.floor((f:GetHeight() or H) + 0.5))
        f:SetSize(w, h)
        local d = db()
        d.w, d.h = w, h
        UI:Refresh()
    end)
    for i = 0, 2 do   -- 手柄外观：三条斜杠
        local t = R.box(grip, 1, 1, 1, 0.25)
        t:SetWidth(2)
        t:SetHeight(2 + i * 5)
        t:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -2 - i * 4, 2)
    end
    -- 上次调过的窗口大小：重载/重登后保持（不出厂大就忽略，防脏档）
    local d0 = db()
    if tonumber(d0.w) and tonumber(d0.h) and d0.w >= W and d0.h >= H then
        f:SetSize(d0.w, d0.h)
    end

    -- 交任务后自动重画：路线与「还能做几个号」都是现读的，不重画就停在交之前
    f:RegisterEvent("QUEST_TURNED_IN")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function(_, event)
        if not f:IsVisible() then return end
        if event == "QUEST_TURNED_IN" then
            if C_Timer and C_Timer.After then
                C_Timer.After(0.3, function()
                    if f:IsVisible() then UI:SafeRefresh() end
                end)
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            -- 换地图 / 进出副本后池会变，刷新一次
            if C_Timer and C_Timer.After then
                C_Timer.After(2.0, function()
                    if f:IsVisible() then UI:SafeRefresh() end
                end)
            end
        end
    end)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetText(colorText(GOLD, "为了雷菌"))
    title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -12)

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("LEFT", title, "RIGHT", 10, 0)
    sub:SetText(colorText(MUTED, "攒钱买雷龙 · 金币任务 + 拍卖快照"))

    local hintCmd = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hintCmd:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, -14)
    hintCmd:SetText(colorText(MUTED, "/lj 开关 · /lj pin 置顶窗"))

    -- 页签
    local TABS = ns.LITE_TABS
    local ML = mainLayout()
    local tabY = -40
    local tw = math.floor((W - PAD * 2) / #TABS)
    self.tabs = {}
    for i, spec in ipairs(TABS) do
        local o = ML.tabs[spec[1]] or {}
        local lab, sub = o.label or spec[2], o.sub or spec[3]
        local b = CreateFrame("Button", nil, f)
        b:SetSize(tw - 4, 36)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (i - 1) * tw, tabY)
        b.bg = R.box(b, 1, 1, 1, 0.03)
        b.bg:SetAllPoints()
        b._key = spec[1]
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.label:SetPoint("TOP", b, "TOP", 0, -4)
        b.label:SetText(colorText(MUTED, lab))
        b.sub = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.sub:SetPoint("TOP", b.label, "BOTTOM", 0, -1)
        b.sub:SetText(colorText(MUTED, sub))
        function b:SetActive(on)
            if on then
                self.bg:SetColorTexture(1, 1, 1, 0.10)
                self.label:SetText(colorText(GOLD, lab))
            else
                self.bg:SetColorTexture(1, 1, 1, 0.03)
                self.label:SetText(colorText(MUTED, lab))
            end
        end
        b:SetScript("OnClick", function() UI:SetTab(spec[1]) end)
        self.tabs[i] = b
    end

    -- 滚动内容区
    local okTpl, scroll = pcall(CreateFrame, "ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    if not okTpl then scroll = CreateFrame("ScrollFrame", nil, f) end
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -82)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(PAD + 12), PAD + 4)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local step = 34
        local maxS = math.max(0, self:GetVerticalScrollRange() or 0)
        local v = self:GetVerticalScroll() or 0
        if delta > 0 then v = math.max(0, v - step) else v = math.min(maxS, v + step) end
        self:SetVerticalScroll(v)
    end)
    self.scroll = scroll

    local content = CreateFrame("Frame", nil, scroll)
    content:SetPoint("TOPLEFT")
    content:SetWidth(W - PAD * 2 - 32)
    content:SetHeight(10)
    scroll:SetScrollChild(content)
    self.content = content

    self.rows, self.labels, self.bars = {}, {}, {}
    self.nRow, self.nLabel, self.nBar = 0, 0, 0

    buildSearchBar(f)

    -- Esc 关闭：主窗口注册（置顶窗不注册 —— 那是常驻窗，见 Pin.lua 的说明）
    if type(UISpecialFrames) == "table" then
        local found = false
        for _, v in ipairs(UISpecialFrames) do
            if v == "ForLeiJunMain" then found = true; break end
        end
        if not found then table.insert(UISpecialFrames, "ForLeiJunMain") end
    end

    return f
end

function UI:Toggle(tab)
    local f = self:Build()
    if f:IsShown() and not tab then
        f:Hide()
    else
        f:Show()
        self:SetTab(tab or self.tab or lastTab())
    end
    return f
end

function UI:Open(tab)
    local f = self:Build()
    f:Show()
    self:SetTab(tab or self.tab or lastTab())
    return f
end

--==========================================================================
-- 命令：/lj
--   刻意保持极少：对外第一版的命令面越小越好，其余都做成界面里的可点行。
--==========================================================================
local PREFIX = colorText("ffd97757", "[雷菌]") .. " "

local function say(s) print(PREFIX .. tostring(s)) end

local function handle(msg)
    local raw = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local low = raw:lower()
    local cmd = low:match("^(%S*)")
    local rest = raw:match("^%S*%s*(.*)$") or ""

    if cmd == "" then
        UI:Toggle()
        return
    end

    if cmd == "help" then
        say("命令（都很短，日常只需要第一个）：")
        say("  /lj            打开 / 关闭面板")
        say("  /lj ah <关键词> 直接查拍卖行快照（如 /lj ah 附魔）")
        say("  /lj scan       重新采集世界任务")
        say("  /lj goal <金额> 改攒钱目标（单位金，可写 500w 或 500万）")
        say("  /lj pin        置顶窗开关（路线 + 拍卖两个小窗）")
        say("  /lj pin route  只开关路线置顶窗")
        say("  /lj pin ah     只开关拍卖置顶窗")
        say("  /lj pin off    全部关掉（并记住不要了）")
        say("  /lj pin reset  置顶窗位置尺寸复原")
        say("提示：打开世界地图（M）会自动采集一次，不用敲命令。")
        say("口径：金币 = 各角色携带 + 战团银行，只统计登录过的角色。")
        return
    end

    if cmd == "ah" then
        UI.ahQuery = rest
        UI:Open("ah")
        if UI.edit then UI.edit:SetText(rest) end
        return
    end

    if cmd == "scan" then
        if ns.Scan then
            local ok, c = pcall(ns.Scan, { maps = true })
            say(ok and "采集完成。" or ("采集失败：" .. tostring(c)))
            UI:SafeRefresh()
        else
            say("采集模块没加载。")
        end
        return
    end

    if cmd == "goal" or cmd == "目标" then
        local have, known = totalGold()
        if rest == "" then
            say(("目标 %s 金 · 已攒 %s 金 · 还差 %s 金（%d 个角色有数据）"):format(
                goldStr(goalGold() * 10000), goldStr(have),
                goldStr(math.max(0, goalGold() * 10000 - have)), known))
            say(colorText(MUTED, "改目标：/lj goal 5000000（单位金，也可写 500w 或 500万）"))
            return
        end
        local v = parseGoal(rest)
        if not v or v <= 0 then
            say("金额看不懂。" .. colorText(MUTED, "写法：/lj goal 5000000 或 /lj goal 500w"))
            return
        end
        db().goal = v
        say(("目标已设为 %s 金。"):format(goldStr(v * 10000)))
        UI:SafeRefresh()
        return
    end

    if cmd == "pin" then
        if not ns.Pin then say("置顶窗模块没加载（Pin.lua）。") return end
        local a = (rest or ""):lower():gsub("%s+", "")
        if a == "" then ns.Pin:Toggle()
        elseif a == "off" or a == "close" or a == "关" then ns.Pin:HideAll()
        elseif a == "route" or a == "路线" then ns.Pin:Toggle("route")
        elseif a == "ah" or a == "拍卖" then ns.Pin:Toggle("ah")
        elseif a == "reset" or a == "重置" then ns.Pin:Reset(); say("置顶窗位置与尺寸已复原。")
        else say("用法：/lj pin [route|ah|off|reset]") end
        return
    end

    if cmd == "layout" or cmd == "布局" then
        -- v0.9.36：置顶窗布局配置（与自用版同一份 Layout.lua / 同一个渲染器）
        if not ns.PinLayoutInfo then say("布局模块没加载（Layout.lua）。") return end
        for _, s in ipairs(ns.PinLayoutInfo()) do say(s) end
        return
    end

    say("不认识的命令。" .. colorText(MUTED, "输入 /lj help 看用法。"))
end

-- 四个入口指向同一个 handler。中文命令放在最后：客户端支持 UTF-8，
-- 但万一某个语言包不认，前面的英文/拼音仍然能用。
SLASH_FORLEIJUN1 = "/lj"
SLASH_FORLEIJUN2 = "/leijun"
SLASH_FORLEIJUN3 = "/wbl"      -- 兼容改名前的旧命令
SLASH_FORLEIJUN4 = "/雷菌"
SlashCmdList["FORLEIJUN"] = function(msg)
    local ok, err = pcall(handle, msg)
    if not ok then say(colorText(BAD, "命令出错：") .. tostring(err)) end
end

if ns._mark then ns._mark("LiteUI.lua") end
