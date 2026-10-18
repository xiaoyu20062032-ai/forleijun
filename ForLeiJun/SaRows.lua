-- 本文件由 tools/build_lite.py 从 ../WeeklyBoard/SaRows.lua 同步生成，请勿手改。
-- 改动请改源文件后重跑：python3 tools/build_lite.py
--[[--------------------------------------------------------------------------
    ForLeiJun / SaRows.lua
    特别任务（Special Assignment）行生成器 —— 自用版看板与对外版（为了雷菌）
    共用同一份判定与行结构。

    为什么单独抽出来
      「这张图解锁了没有 / 本周做了几条」这套判定改过四次：
        v0.9.19 只有进度   v0.9.22 按规范图聚合
        v0.9.23 读实时池   v0.9.27 已完成标记
      每一次都是同一类错误：**拿痕迹当状态**。如果再复制一份到对外版，
      两边迟早给出不同答案 —— 而对外版一旦漂移，玩家看到的和作者看到的
      不是同一件事，报上来的 bug 也没法复现。所以判定与行结构只此一份，
      full 与 lite 都调 ns.SaRowsForZone()。

    口径（三句话，改之前先读）
      1) 已解锁的证据优先级：本周全做完 > 实时池里亮着 > 解锁追踪任务 > 本周做过该图任务。
      2) 「池里没亮」≠「没解锁」。特别任务有时限，亮着才是证据，不亮只是不知道。
      3) 完成状态只信 C_QuestLog.IsQuestFlaggedCompleted（角色级、周重置清零）；
         池里的 completed 是**上次扫描**的快照，只做回退 —— 刚交完任务时它仍是 live。

    用法
      ns.SaRowsReset()                      -- 每次整页重绘开始调一次（清渲染内缓存）
      local rows, items, any, n = ns.SaRowsForZone(zk, force)
        zk    = 规范区域 key（ns.CanonZoneMap 之后的值）
        force = true  这张图有路线站，组头反正要画 → SA 行跟着画
                false 只在「有话可说」（亮着 / 有进度 / 本周做过）时才画，
                      并在需要时**自己补一个组头**（孤行不知道是哪张图的）
      返回 rows/items 可直接用 table.insert 拼进表格；n = 加了几条数据行。
--------------------------------------------------------------------------]]--

local ADDON, ns = ...

-- 配色与两版渲染层一致（改这里会同时改到 full 看板与对外版，属于预期）
local GOLD, GOLD_DIM = "fff2c94e", "ffc08a3e"
local TEXT, TEXT2, MUTED = "fff0e6cc", "ffdccfae", "ffb8ab8c"
local GOOD, WARN, BAD = "ff8cc63f", "ffe9c058", "ffe06a50"

local function num(v)
    return tonumber(v) or 0
end

-- 与两版渲染层同一个写法：色值本身已含 alpha（"ffdccfae"），
-- 所以前缀只能是 "|c" —— 写成 "|cff"..code 会多出两位，颜色码错位，
-- 剥色后残留字符（测试里的 logCountExact 就是这么抓到假绿的）。
local function colorText(code, s)
    if not code or code == "" then return tostring(s) end
    return "|c" .. code .. tostring(s) .. "|r"
end

local function goldStr(copper)
    local g = num(copper) / 10000
    local a = math.abs(g)
    if a >= 1e8 then return string.format("%.2f亿", g / 1e8) end
    if a >= 1e4 then return string.format("%.1f万", g / 1e4) end
    return string.format("%d", math.floor(g + 0.5))
end

-- 剩余时间文案（池条目只有 leftSeconds，没有现成的 leftText）
local function fmtLeft(secs)
    secs = num(secs)
    if secs <= 0 then return "—" end
    if secs < 3600 then
        return math.max(1, math.ceil(secs / 60)) .. " 分"
    elseif secs < 86400 then
        local h = math.floor(secs / 3600)
        local m = math.floor((secs % 3600) / 60)
        return (m > 0) and ("%d小时%d分"):format(h, m) or (h .. "小时")
    end
    local d = math.floor(secs / 86400)
    local h = math.floor((secs % 86400) / 3600)
    return (h > 0) and ("%d天%d小时"):format(d, h) or (d .. "天")
end

--==========================================================================
-- 渲染内缓存
--   一张图 3 条 × 6 张图 → 一次重绘要问几十遍客户端函数，每次都是一次 C 调用。
--   必须在**每次整页重绘开始时**清空：清早了没意义，不清就会读到上一屏的
--   旧答案（刚交完任务还显示「可做」）。
--==========================================================================
local cache = { pool = nil, titles = nil, byMap = nil, done = {} }

function ns.SaRowsReset()
    cache.pool, cache.titles, cache.byMap = nil, nil, nil
    cache.done = {}
end

-- 实时特别任务池（wqPool().sa）：解锁后**此刻亮在地图上**的条目都在这里
local function getPool()
    if cache.pool ~= nil then return cache.pool end
    cache.pool = false
    if ns.wqPool then
        local ok, p = pcall(ns.wqPool)
        if ok and type(p) == "table" and type(p.sa) == "table" then
            cache.pool = p.sa
        end
    end
    return cache.pool
end

-- qid → 去前缀短名（「特别任务：破庙残痕」→「破庙残痕」，省列宽）
local function getTitles()
    if cache.titles then return cache.titles end
    local t = {}
    if type(ns.SA_QUEST) == "table" then
        for qid, q in pairs(ns.SA_QUEST) do
            local s = (type(q) == "table") and tostring(q.t or "") or ""
            t[qid] = s:gsub("^特别任务：", "")
        end
    end
    cache.titles = t
    return t
end

-- 角色身上的解锁追踪任务（代理指标只少不多，见 Core.lua ns.ScanUnlockTrackers）
local function getByMap()
    if cache.byMap ~= nil then return cache.byMap end
    cache.byMap = false
    if ns.ScanUnlockTrackers then
        local ok, r = pcall(ns.ScanUnlockTrackers)
        if ok and type(r) == "table" then cache.byMap = r end
    end
    return cache.byMap
end

-- 本周做完了没有。拿不到客户端函数（无头测试 / 极老客户端）才回退池里的
-- completed —— 别把「不知道」当「没做」。
local function saDoneQ(qid, entry)
    local key = tonumber(qid)
    local hit = key and cache.done[key] or nil
    if hit ~= nil then return hit end
    local v
    if type(C_QuestLog) == "table" and type(C_QuestLog.IsQuestFlaggedCompleted) == "function" then
        local okq, r = pcall(C_QuestLog.IsQuestFlaggedCompleted, qid)
        if okq then v = (r == true) end
    end
    if v == nil then
        v = (type(entry) == "table" and entry.completed == true) or false
    end
    if key then cache.done[key] = v end
    return v
end

-- 这张图「亮着」的特别任务条目（活着，且本周还没做完）
local function activeSAs(meta)
    local pool = getPool()
    if type(meta) ~= "table" or type(meta.qs) ~= "table" or not pool then return nil end
    local out = {}
    for _, qid in ipairs(meta.qs) do
        local a = pool[qid]
        if type(a) == "table" and a.live and not saDoneQ(qid, a) then out[#out + 1] = a end
    end
    return (#out > 0) and out or nil
end

-- 一张图里本周做完了几条
local function saDoneN(meta)
    if type(meta) ~= "table" or type(meta.qs) ~= "table" then return 0 end
    local pool = getPool()
    local n = 0
    for _, qid in ipairs(meta.qs) do
        if saDoneQ(qid, pool and pool[qid] or nil) then n = n + 1 end
    end
    return n
end

-- 一张图的汇总行内容。返回 nil = 这张图没有特别任务目录。
local function saRow(mid)
    local meta = (type(ns.SA_MAPS) == "table") and ns.SA_MAPS[mid] or nil
    if type(meta) ~= "table" or type(meta.qs) ~= "table" or #meta.qs == 0 then return nil end
    local titles = getTitles()
    local names = {}
    for _, qid in ipairs(meta.qs) do
        names[#names + 1] = titles[qid] or ("#" .. tostring(qid))
    end
    local need = (ns.SaUnlockNeed and ns.SaUnlockNeed()) or 3
    local total = #meta.qs
    local doneN = saDoneN(meta)
    local prog, pc, gap
    local tr = getByMap() and getByMap()[mid] or nil
    local act = activeSAs(meta)
    if doneN >= total then
        -- 全做完是终态，信息量比「已解锁」大。必须在 act 之前判：
        -- 池里的 completed 是上次扫描的快照，刚交完任务时它仍是 live。
        prog, pc, gap = "本周已做完", GOOD, ("%d/%d"):format(doneN, total)
    elseif act then
        -- 实时池里有亮着的 → 必然已解锁，且这是最直接的证据。
        -- 优先级放在追踪任务之前：追踪任务做完就消失，池里条目才是实况。
        prog, pc = "已解锁", GOOD
        gap = ("亮着 %d 条"):format(#act)
        if doneN > 0 then gap = gap .. (" · 已做 %d"):format(doneN) end
    elseif tr then
        local got, req = num(tr.wq), num(tr.need)
        if tr.unlocked or got >= req then
            prog, pc = "已解锁", GOOD
            gap = (doneN > 0) and ("已做 %d/%d"):format(doneN, total) or "—"
        else
            prog, pc = ("解锁 %d/%d"):format(got, req), WARN
            gap = ("还差 %d 个"):format(req - got)
        end
    else
        -- 追踪任务没见过（新号 / 目录还没开过）→ 退而求其次：本周做过该图的
        -- 特别任务 ＝ 必然已解锁；除此之外不猜，标「进度未知」。
        -- （「没亮 ≠ 没解锁」，所以不能拿「池里没亮」当未解锁。）
        if doneN > 0 then
            prog, pc = "已解锁", GOOD
            gap = ("已做 %d/%d"):format(doneN, total)
        else
            prog, pc, gap = "进度未知", MUTED, ("满 %d 个解锁"):format(need)
        end
    end
    return ("特别任务 %d 条 · %s"):format(total, table.concat(names, " · ")), prog, pc, gap
end

--==========================================================================
-- 对外接口：一张规范区域的全部特别任务行
--==========================================================================
function ns.SaRowsForZone(zk, force)
    local rows, items = {}, {}
    if type(ns.SA_MAPS) ~= "table" then return rows, items, false, 0 end

    -- 同一规范图下可能挂着多个 mapID（屠戮者高地 / 虚影风暴是同一张图）
    local maps = {}
    for m, meta in pairs(ns.SA_MAPS) do
        if type(meta) == "table" and type(meta.qs) == "table" and #meta.qs > 0
            and meta.cur ~= false then
            local cm = (ns.CanonZoneMap and ns.CanonZoneMap(m)) or m
            if cm == zk then maps[#maps + 1] = m end
        end
    end
    if #maps == 0 then return rows, items, false, 0 end
    table.sort(maps)

    local pool = getPool()
    local titles = getTitles()
    local any, hdrDone, nRows = false, false, 0

    for _, m in ipairs(maps) do
        local meta = ns.SA_MAPS[m]
        local txt, prog, pc, gap = saRow(m)
        local act = activeSAs(meta)
        if txt and (force or act or prog ~= "进度未知") then
            nRows = nRows + 1
            if #maps > 1 then
                local mn = (type(meta) == "table" and tostring(meta.n or "")) or tostring(m)
                txt = ("【%s】%s"):format(mn, txt)
            end
            if not force and not hdrDone then
                -- 路线没覆盖的图：SA 行总得跟一张图名，孤行不知道是谁的
                -- （hdr=true → 渲染层画顶部粗线 + 淡金底，与其他组头同一视觉）
                rows[#rows + 1] = {
                    hdr = true,
                    { t = colorText(GOLD_DIM, "▼") },
                    { t = colorText(GOLD_DIM, (ns.ZoneName and ns.ZoneName(zk)) or tostring(zk)) },
                    { t = "" }, { t = "" }, { t = "" },
                }
                items[#items + 1] = { header = true }
                hdrDone = true
            end
            rows[#rows + 1] = {
                { t = "" },
                { t = colorText(TEXT2, txt) },
                { t = colorText(pc, prog) },
                { t = colorText(pc, gap) },
                { t = "" },
            }
            items[#items + 1] = { header = true }

            -- ★ 亮着的逐条给一行：可点（挂追踪 + 打路点 + 开地图）
            --   先剔掉本周已做完的 —— 池快照会过期，刚交完任务时仍挂着 live。
            for _, a in ipairs(act or {}) do
                local qid = num(a.id)
                if not saDoneQ(qid, a) then
                    local title = tostring(a.title or titles[qid] or ("特别任务#" .. tostring(qid)))
                    local secs = num(a.leftSeconds)
                    local leftCell = colorText(MUTED, "—")
                    if secs > 0 then
                        local lc = MUTED
                        if secs <= 3600 then lc = BAD
                        elseif secs <= 6 * 3600 then lc = WARN end
                        leftCell = colorText(lc, fmtLeft(secs))
                    end
                    rows[#rows + 1] = {
                        { t = colorText(GOLD, "★") },
                        { t = colorText(GOLD, title) },
                        { t = num(a.money) > 0 and colorText(GOLD, goldStr(a.money) .. " 金")
                              or colorText(MUTED, "宝箱") },
                        { t = leftCell },
                        { t = (a.x and a.y) and ("%.0f, %.0f"):format(a.x * 100, a.y * 100) or "?",
                          c = MUTED },
                    }
                    -- 坐标同源铁律：a.x/a.y 是扫描那张图（lastMapID）上的，路点也用那张
                    items[#items + 1] = { id = qid, title = title,
                                          x = a.x, y = a.y,
                                          mapID = tonumber(a.lastMapID), zoneID = a.zoneID }
                    nRows = nRows + 1
                end
            end

            -- ✓ 本周已做完的逐条给一行（不可点 —— 做完导航没意义）
            --   否则做完的条目从两边同时消失（池里 completed、追踪任务也早没了），
            --   汇总行只剩一句「已解锁」，看不出到底做了几条。
            for _, qid0 in ipairs(meta.qs) do
                local qid = num(qid0)
                local a = pool and pool[qid] or nil
                if saDoneQ(qid, a) then
                    local title = tostring((type(a) == "table" and a.title)
                        or titles[qid] or ("特别任务#" .. tostring(qid)))
                    rows[#rows + 1] = {
                        { t = colorText(GOOD, "✓") },
                        { t = colorText(MUTED, title) },
                        { t = (type(a) == "table" and num(a.money) > 0)
                              and colorText(GOLD_DIM, goldStr(a.money) .. " 金")
                              or colorText(MUTED, "宝箱") },
                        { t = colorText(GOOD, "已完成") },
                        { t = colorText(MUTED, "—") },
                    }
                    items[#items + 1] = { header = true }
                    nRows = nRows + 1
                end
            end
            any = true
        end
    end
    return rows, items, any, nRows
end

--==========================================================================
-- 对外接口：一张规范图的特别任务「状态块」
--   置顶窗路线卡用：每张图一个小色块 + 一句状态。与 SaRowsForZone 同一份
--   判定（saRow），同一个渲染内缓存 —— 必须在 SaRowsReset 之后调。
--
--   返回 (state, text)：
--     none      这张图没有特别任务目录
--     unknown   有目录但解锁进度未知（新号 / 没开过任务日志面板）
--     locked    有目录、未解锁（解锁 K/N · 还差 M 个）
--     unlocked  已解锁、本周还没做完（亮着 N 条 · 已做 K）
--     done      本周全部做完（K/N）
--==========================================================================
function ns.SaZoneState(zk)
    if type(ns.SA_MAPS) ~= "table" then return "none", "" end
    -- 同一规范图下可能挂多个 mapID（与 SaRowsForZone 同一套收集）
    local maps = {}
    for m, meta in pairs(ns.SA_MAPS) do
        if type(meta) == "table" and type(meta.qs) == "table" and #meta.qs > 0
            and meta.cur ~= false then
            local cm = (ns.CanonZoneMap and ns.CanonZoneMap(m)) or m
            if cm == zk then maps[#maps + 1] = m end
        end
    end
    if #maps == 0 then return "none", "" end
    table.sort(maps)

    local info, allDone = {}, true
    for _, m in ipairs(maps) do
        local _, prog, _, gap = saRow(m)
        local st = (prog == "本周已做完" and "done")
                or (prog == "已解锁" and "unlocked")
                or (prog == "进度未知" and "unknown")
                or "locked"
        if st ~= "done" then allDone = false end
        if not info[st] then info[st] = { prog = prog, gap = gap } end
    end
    if allDone and info.done then
        local g = info.done.gap or ""
        return "done", (g ~= "") and ("本周已做完 " .. g) or "本周已做完"
    end
    if info.unlocked then
        local g = info.unlocked.gap or ""
        return "unlocked", (g ~= "") and g or "已解锁"
    end
    if info.locked then
        local p, g = info.locked.prog or "未解锁", info.locked.gap or ""
        return "locked", (g ~= "") and (p .. " · " .. g) or p
    end
    return "unknown", "进度未知"
end

if ns._mark then ns._mark("SaRows.lua") end
