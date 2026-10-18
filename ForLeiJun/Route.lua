-- 本文件由 tools/build_lite.py 从 ../WeeklyBoard/Route.lua 同步生成，请勿手改。
-- 改动请改源文件后重跑：python3 tools/build_lite.py
--[[--------------------------------------------------------------------------
    ForLeiJun / Route.lua

    路线：把这周还值得去做的金币世界任务排成一条走法，推给路点插件。

    为什么单独一个文件
      ① 排序是纯算法（最近邻 + 2-opt）。不想让它跟采集 / 展示搅在一起 ——
         顺序对不对应该能在本机断言（tools/test_route.lua），而不是进游戏肉眼看。
      ② 它是可选的：三级路点后端（TomTom / WaypointUI / 暴雪自带），
         一个都没有也能用，退化成把顺序打到聊天框，不影响任何其它功能。

    ★ 坐标从哪来（这条曾经是个坑，写在这里防止以后改错）★
      池条目上的 x / y 来自**扫描时那张地图**的 POI（Core.lua 的 CollectWorldQuests
      里是 `e.x = poi.x`），而 zoneID 是 C_TaskQuest.GetQuestZoneID 给的
      「任务所属区域」—— 后者常常是**子区域**（比如「屠戮者高地」属于「哈籁恩达尔」）。
      所以 (mapID, x, y) 这个三元组里的 mapID 必须用 e.lastMapID（扫描那张图）。
      拿 e.zoneID 配 x/y 会打到错的地图上去 —— 这是最隐蔽的一类错误：
      代码不报错，路点就是不准，而且要进游戏才发现。
      Core.lua 的 WqPoolSnapshot 已经把 lastMapID 作为 item.mapID 暴露出来了。

    为什么路线只在「当前登录角色」有意义
      路点是绑角色的。任务清单本身是账号级的（见 Core.lua 顶部「三层口径」），
      但「先走哪个」必须是这个角色此刻还没做的那批。
      所以这一层是角色视角 —— 和 HTML 看板的账号级定位不冲突：那是看板，这是导航。
--------------------------------------------------------------------------]]--

local ADDON, ns = ...

local SAY = "|cffd97757[周报]|r "
local GOLD = "|cfff2c94e"

-- 2-opt 轮数上限：不追求最优解。
--   真实地图有飞行 / 传送 / 任务内路径，两点直线距离本来只是近似，
--   多跑几轮换来的那点收益不值得 —— 但上限必须有，否则遇到病态输入会空转。
local ROUTE_MAX_PASSES = 50

local routeState = {}      -- { { item=, uid=/pinID=, label=, backend= }, ... } 还没走完的
local routeZones = {}      -- 本次路线的区域顺序（诊断 / 展示用）
-- 本次路线是否占用了 WaypointUI 的「导航」槽（NewUserNavigation）。
--   占用过就要在清路线时一并放开，否则「下一站」的箭头会一直挂着。
--   单独一个变量是因为 routeState 会被整体换掉，而这个是跨那一步的。
local routeNavUsed = false

local function say(s) print(SAY .. tostring(s)) end
ns.RouteSay = say

--==========================================================================
-- 候选清单：从**实时**世界任务池取可导航的金币任务
--
--   为什么不吃 Dashboard.lua 那个快照：快照是 build.py 几小时前跑的，
--   拿来排路线会把人带到已经轮换掉的任务点上。导航必须用实时的。
--   池的刷新时机：登录 / 换区域 / 任务日志变化 / 每 4 分钟兜底（Core.lua 尾部）。
--==========================================================================
function ns.RouteCandidates()
    local wq = ns.db() and ns.db().worldQuests
    if type(wq) ~= "table" or type(wq.list) ~= "table" then return {}, nil end
    return wq.list, wq.scanTime
end

-- ★ v0.9.22：规范区域（canonical zone）★
--   子区域任务会把路线组撕碎（2026-10-17 用户实测）：屠戮者高地(2444) 是
--   虚影风暴(2405) 的子地图，奈格塔尔(2600)、银月城(2393)、阿塔乌特克地窟(2509)、
--   阿塔阿曼(2536) 同理 —— 同一张图会冒出两三个组头。
--   判图口径与特别任务目录同源（QuestPOIBlob 挂在哪张 UiMap）：取「父链上最高的
--   那张区域图」—— 沿父链向上走，父图仍是「区域」(mapType==Zone) 就继续并，
--   碰到大陆/世界图就停。屠戮者高地→虚影风暴、银月城→永歌森林、阿塔阿曼→祖阿曼；
--   而祖阿曼、盘卷蛇岛这类**本体就是区域图**的保持独立。
--   分组键 = canon(zoneID or mapID)：zoneID 是任务自己报的区域（GetQuestZoneID，
--   与 SA 目录同源）；mapID（lastMapID）是「扫描哪张图时捎带看到的」，会污染
--   （pool 实测：祖阿曼的任务被 2395 永歌森林的扫描捎出来，mapID=2395/zoneID=2437）。
--   无头测试没有 MapUtil → 恒等返回，分组键退化为 zoneID 本身（test_route 靠这个口径）。
local canonCache = {}

-- ★ v0.9.29：静态子图锚定表 ★
--   「子区域任务并回所属区域图」原先只靠真机 API（MapUtil.GetMapParentInfo /
--   C_Map.GetMapHierarchy）沿父链爬 —— 2026-10-17 真机实测**爬不动**：
--   屠戮者高地(2444) 的任务没并进虚影风暴(2405)，单独冒出一个「▼ 屠戮者高地」
--   组头，而虚影风暴组头下面只剩特别任务行 —— 用户看到的「任务和特别任务
--   分了家」。所以已知关系改用**静态表**（决定性），API 只兜静态表没收录的新图。
--
--   数据来源：客户端本体 UiMap.db2（wow-db 项目 data/raw/UiMap.csv，
--   2026-10-17 导出）：收录 SA 目录各图的全部子地图（UiMapType 3=Zone、4=Micro）。
--   它和 Special.lua 的 SA 目录一样是**版本化数据** —— 暴雪改了地图层级、
--   SA 目录更新时，这张表要跟着对一遍（导出脚本：查 ParentUiMapID ∈ SA 图的行）。
local KNOWN_SUBGROUPS = {
    [2512] = { 2509, 2588, 2589, 2590, 2606, 2607, 2608, 2609, 2610, 2632, 2633, 2634, 2635, 2636 },
    [2405] = { 2444, 2506, 2507, 2528, 2529, 2530, 2556, 2571, 2572, 2573, 2574, 2599, 2600, 2617, 2623 },
    [2413] = { 2427, 2500, 2505, 2510, 2531, 2532, 2575 },
    [2395] = { 2393, 2433, 2492, 2493, 2494, 2496, 2497, 2498, 2499, 2502, 2525, 2547, 2577, 2578, 2594, 2605, 2647, 2648 },
    [2437] = { 2501, 2503, 2504, 2513, 2514, 2535, 2536, 2564, 2585 },
}
local KNOWN_SUBMAP = {}
for top, subs in pairs(KNOWN_SUBGROUPS) do
    for _, s in ipairs(subs) do KNOWN_SUBMAP[s] = top end
end

function ns.CanonZoneMap(m)
    m = tonumber(m)
    if not m or m <= 0 then return m end
    local c = canonCache[m]
    if c ~= nil then return c end
    -- ① 静态表命中 → 直接锚到顶层图（不进缓存前先归一化，见 ③）
    local out = KNOWN_SUBMAP[m] or m
    -- ② API 爬链兜底：只在静态表没收录时才试 —— API 在部分真机上拿不到
    --    父子关系（见上），拿不到时它自己会原样返回，无害。
    if out == m then
        local CMap, MU = C_Map, MapUtil
        if CMap and CMap.GetMapInfo and (MU and MU.GetMapParentInfo or CMap.GetMapHierarchy) then
            local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
            -- 父图（mapID + mapType）。优先 MapUtil.GetMapParentInfo；
            -- 没有（老客户端）就用 C_Map.GetMapHierarchy（自顶向下，idx-1 即父图）。
            local function parentOf(id)
                if MU and MU.GetMapParentInfo then
                    local okP, p = pcall(MU.GetMapParentInfo, id)
                    if okP and type(p) == "table" and tonumber(p.mapID) then
                        return tonumber(p.mapID), tonumber(p.mapType)
                    end
                end
                if CMap.GetMapHierarchy then
                    local okH, h = pcall(CMap.GetMapHierarchy, id)
                    if okH and type(h) == "table" then
                        for i, e in ipairs(h) do
                            if type(e) == "table" and tonumber(e.mapID) == id and i > 1 then
                                local pe = h[i - 1]
                                if type(pe) == "table" and tonumber(pe.mapID) then
                                    return tonumber(pe.mapID), tonumber(pe.mapType)
                                end
                            end
                        end
                    end
                end
                return nil
            end
            local cur = m
            for _ = 1, 8 do                        -- 层级不会深过 8 层；防脏数据成环
                local pid, pmt = parentOf(cur)
                if not pid or pid <= 0 or pid == cur or pmt ~= zoneType then break end
                cur = pid
            end
            out = cur
        end
    end
    -- ③ 归一化：API 爬链半途而废（停在另一张已知子图上）也锚到顶层
    if KNOWN_SUBMAP[out] then out = KNOWN_SUBMAP[out] end
    canonCache[m] = out
    return out
end

-- 区域图名（显示用；拿不到返回 nil，调用方退回条目自己的 zone 字符串）
function ns.ZoneName(m)
    m = tonumber(m)
    if not m or m <= 0 then return nil end
    local CMap = C_Map
    if CMap and CMap.GetMapInfo then
        local ok, mi = pcall(CMap.GetMapInfo, m)
        if ok and type(mi) == "table" and type(mi.name) == "string" and mi.name ~= "" then
            return mi.name
        end
    end
    return nil
end

-- 一条候选的「规范区域键」—— 分组、换组头、SA 行三处共用，口径必须唯一
function ns.RouteZoneKey(it)
    if type(it) ~= "table" then return nil end
    local base = tonumber(it.zoneID) or tonumber(it.mapID)
    return ns.CanonZoneMap(base)
end

-- 候选里出现过的区域 mapID（去重，保持首次出现顺序 —— 保证同输入同输出）
function ns.RouteZoneIDs(items)
    local seen, out = {}, {}
    for _, it in ipairs(items or {}) do
        local m = ns.RouteZoneKey(it)
        if m and not seen[m] then seen[m] = true; out[#out + 1] = m end
    end
    return out
end

--==========================================================================
-- 区域排序（吃 C_Map，非纯函数 —— 但也正因为这样，它只负责算顺序）
--
--   按「区域中心离原点的世界坐标距离」排。原点是当前所在区域。
--   算不出来（跨大陆 / 副本 / API 缺失）的一律排到后面，且彼此保持传入顺序 ——
--   ★ 宁可按一个确定的顺序走，也不要随机顺序。
--     同输入同输出是这个项目已有的约定（角色列排序就是这么写的）。
--==========================================================================
function ns.ZoneOrder(zoneIDs, originMapID)
    local out = {}
    for _, z in ipairs(zoneIDs or {}) do out[#out + 1] = z end
    if #out < 2 then return out end

    local CMap = C_Map
    if not (CMap and CMap.GetWorldPosFromMapPos and CreateVector2D) then return out end

    local origin = originMapID
    if type(origin) ~= "number" or origin <= 0 then
        origin = (CMap.GetBestMapForUnit and CMap.GetBestMapForUnit("player")) or nil
    end
    if type(origin) ~= "number" or origin <= 0 then return out end

    -- 取一张图中心点的世界坐标。任何一步失败都返回 nil（调用方会退化处理）
    local function centre(m)
        if type(m) ~= "number" or m <= 0 then return nil end
        local ok, cont, pos = pcall(CMap.GetWorldPosFromMapPos, m, CreateVector2D(0.5, 0.5))
        if not ok or not cont or not pos then return nil end
        local ok2, x, y = pcall(function() return pos:GetXY() end)
        if not ok2 or type(x) ~= "number" or type(y) ~= "number" then return nil end
        return cont, x, y
    end

    local oc, ox, oy = centre(origin)
    local keyed = {}
    for i, m in ipairs(out) do
        local d
        local c, x, y = centre(m)
        if oc and c and c == oc and type(ox) == "number" and type(x) == "number" then
            local dx, dy = x - ox, y - oy
            d = math.sqrt(dx * dx + dy * dy)
        end
        keyed[#keyed + 1] = { m = m, i = i, d = d }
    end

    table.sort(keyed, function(a, b)
        local ad, bd = a.d, b.d
        if ad ~= nil and bd ~= nil then
            if ad ~= bd then return ad < bd end
            return a.i < b.i
        end
        -- 一边能算一边算不出来 → 能算的排前面
        if (ad ~= nil) ~= (bd ~= nil) then return ad ~= nil end
        return a.i < b.i
    end)

    for i, k in ipairs(keyed) do out[i] = k.m end
    return out
end

--==========================================================================
-- 路线排序（纯函数 —— 本文件的核心，可无头测试）
--
--   ns.BuildRoute(items, opts) -> route, dropped
--     items  池快照的 list（或任何同形状的表：需要 id/title/zone/mapID/x/y/
--            money/moneyProbed/doneByMe）
--     opts   minMoney      金币门槛（铜），默认 ns.GoldWqFloor()（v0.9.34 起
--                          默认 700 金 = 7000000 铜；等级联动已删，见 Core.lua）
--            allowUnknown  moneyProbed == false 的条目要不要收（默认不收）
--            zoneOrder     区域顺序（mapID 数组，由 ns.ZoneOrder 算好；缺失则退化）
--            startPos      { mapID=, x=, y= } 玩家此刻的位置，用来当区内的起点
--            maxPasses     2-opt 轮数上限
--     route  排好序的条目（原表引用，不复制）
--     dropped 各条被剔除的理由计数，供诊断与断言
--
--   剔除顺序是固定的：done → nocoord → unprobed → below。
--   顺序固定是为了让 dropped 的计数可判定（测试要断言得出来），不是为了语义。
--==========================================================================
local function pdist(a, b)
    local dx = (tonumber(a.x) or 0) - (tonumber(b.x) or 0)
    local dy = (tonumber(a.y) or 0) - (tonumber(b.y) or 0)
    return math.sqrt(dx * dx + dy * dy)
end
ns.RouteDist = pdist

-- 2-opt：反转一段子路径，能缩短就接受。上限轮数防死循环。
--   下标 1 天然固定：反转区间永远是 [i+1, j]，i >= 1，所以起点不会被挪走。
--   —— 这一点对「从玩家脚下出发」的路线是关键，别改成反转 [i, j]。
local function twoOpt(path, maxPasses)
    local n = #path
    if n < 4 then return path end
    local passes, improved = 0, true
    while improved and passes < maxPasses do
        improved, passes = false, passes + 1
        for i = 1, n - 1 do
            for j = i + 1, n do
                local a, b, c, d = path[i], path[i + 1], path[j], path[j + 1]
                if a and b then
                    local before = pdist(a, b) + (d and pdist(c, d) or 0)
                    local after  = pdist(a, c) + (d and pdist(b, d) or 0)
                    if after + 1e-12 < before then
                        local lo, hi = i + 1, j
                        while lo < hi do
                            path[lo], path[hi] = path[hi], path[lo]
                            lo, hi = lo + 1, hi - 1
                        end
                        improved = true
                    end
                end
            end
        end
    end
    return path
end
ns.RouteTwoOpt = twoOpt

function ns.BuildRoute(items, opts)
    opts = opts or {}
    local floor = tonumber(opts.minMoney) or ns.GoldWqFloor()
    local allowUnknown = (opts.allowUnknown == true)

    -- ① 过滤
    local kept = {}
    local dropped = { done = 0, nocoord = 0, unprobed = 0, below = 0 }
    for _, it in ipairs(items or {}) do
        if type(it) == "table" then
            local m = it.mapID or it.zoneID
            if it.doneByMe == true then
                dropped.done = dropped.done + 1
            elseif not (type(tonumber(it.x)) == "number" and type(tonumber(it.y)) == "number"
                        and type(tonumber(m)) == "number") then
                -- 没坐标就没法导航 —— 连地图都不打开（打开一张都不知道是哪张的图没意义）
                dropped.nocoord = dropped.nocoord + 1
            elseif it.moneyProbed == false and not allowUnknown then
                -- 奖励还没读出来：它可能值钱，也可能一文不值。
                -- 默认不收 —— 「宁可少说，也不猜错」（项目里的既有口径）。
                dropped.unprobed = dropped.unprobed + 1
            elseif (it.moneyProbed ~= false)
                   and (((tonumber(it.money) or 0) <= 0) or ((tonumber(it.money) or 0) < floor)) then
                -- 确认没金币（0）或低于门槛：不算金币任务，不进路线
                --（v0.9.32：默认 floor = 0 不限金额，但 0 金的仍要剔 —— 金币路线不收白跑的）
                dropped.below = dropped.below + 1
            else
                kept[#kept + 1] = it
            end
        end
    end

    -- ② 按区域分组。键 = 规范区域 ns.RouteZoneKey(it)（v0.9.22）——
    --    zoneID 是任务自己报的区域（与特别任务目录同源），canon 把子区域并回
    --    所属的区域图（屠戮者高地→虚影风暴、银月城→永歌森林）。旧口径按
    --    lastMapID（扫描捎带的图），会把祖阿曼拆进永歌森林的扫描批次、
    --    盘卷蛇岛拆进祖阿曼批次 —— 同一张图两三个组。
    --    组名优先用规范图的官方名（ZoneName），拿不到再退条目自己的 zone 字符串。
    local groups, gorder = {}, {}
    for _, it in ipairs(kept) do
        local k = ns.RouteZoneKey(it)
        local g = groups[k]
        if not g then
            g = { key = k, mapID = k, name = ns.ZoneName(k) or it.zone or "?", items = {} }
            groups[k] = g
            gorder[#gorder + 1] = k
        end
        g.items[#g.items + 1] = it
        if g.name == "?" and it.zone then g.name = it.zone end
    end

    -- ③ 区域顺序
    local ordered = {}
    local used = {}
    local zo = opts.zoneOrder
    if type(zo) == "table" and #zo > 0 then
        for _, m in ipairs(zo) do
            local g = groups[tonumber(m)]
            if g and not used[g.key] then used[g.key] = true; ordered[#ordered + 1] = g end
        end
    end
    -- 没被 zoneOrder 覆盖到的（含 zoneOrder 缺失时）→ 按「区内最高金额降序」兜底，
    -- 同额再按区域键升序。不依赖任何 API，保证同输入同输出。
    local rest = {}
    for _, k in ipairs(gorder) do
        if not used[k] then rest[#rest + 1] = groups[k] end
    end
    local function bestMoney(g)
        local m = 0
        for _, it in ipairs(g.items) do
            local v = tonumber(it.money) or 0
            if v > m then m = v end
        end
        return m
    end
    table.sort(rest, function(a, b)
        local ma, mb = bestMoney(a), bestMoney(b)
        if ma ~= mb then return ma > mb end
        return tostring(a.key) < tostring(b.key)
    end)
    for _, g in ipairs(rest) do ordered[#ordered + 1] = g end

    -- ④ 区内排序：先金额降序打底（路线被打断时先拿到大头），
    --    再最近邻贪心，最后 2-opt 收。
    local route = {}
    local sp = opts.startPos
    local maxPasses = tonumber(opts.maxPasses) or ROUTE_MAX_PASSES
    for _, g in ipairs(ordered) do
        local pool = {}
        for _, it in ipairs(g.items) do pool[#pool + 1] = it end
        table.sort(pool, function(a, b)
            local ma, mb = tonumber(a.money) or 0, tonumber(b.money) or 0
            if ma ~= mb then return ma > mb end
            return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
        end)

        local path, virtual = {}, false
        if type(sp) == "table" and type(tonumber(sp.x)) == "number"
            and type(tonumber(sp.y)) == "number"
            and (sp.mapID == nil or tonumber(sp.mapID) == g.mapID) then
            path[1] = { x = tonumber(sp.x), y = tonumber(sp.y), _start = true }
            virtual = true
        end
        if not virtual then path[1] = table.remove(pool, 1) end

        while #pool > 0 do
            local last = path[#path]
            local bi, bd = 1, math.huge
            for i = 1, #pool do
                local d = pdist(last, pool[i])
                if d < bd then bi, bd = i, d end
            end
            path[#path + 1] = table.remove(pool, bi)
        end

        twoOpt(path, maxPasses)

        for i = 1, #path do
            if not (virtual and i == 1) then route[#route + 1] = path[i] end
        end
    end

    ns.RouteZoneOrder = ordered
    return route, dropped
end

--==========================================================================
-- 文本输出（没装 TomTom 时的降级路线，也是 /wb route 的默认形态）
--==========================================================================
function ns.PrintRoute(route, dropped)
    if not route or #route == 0 then
        say("没有可导航的金币世界任务。可能原因见下方统计，或先 /wb wq 重扫一次。")
        return
    end
    local n = 0
    local lastZone = nil
    for i, it in ipairs(route) do
        local zk = ns.RouteZoneKey(it)
        if zk ~= lastZone then
            lastZone = zk
            n = n + 1
            print(("  %s%d. 【%s】%s"):format(GOLD, n, ns.ZoneName(zk) or tostring(it.zone or "?"), "|r"))
        end
        print(("     %d) %s  %s"):format(i, tostring(it.title or ("任务#" .. tostring(it.id))),
            (function()
                local m = tonumber(it.money) or 0
                if m <= 0 then return "|cffb8ab8c金额未读到|r" end
                return ("|cfff2c94e%d 金|r"):format(math.floor(m / 10000))
            end)()))
    end
    if dropped then
        say(("共 %d 站。剔除：已完成 %d · 无坐标 %d · 奖励未读到 %d · 未达门槛 %d")
            :format(#route, dropped.done, dropped.nocoord, dropped.unprobed, dropped.below))
    end
end

--==========================================================================
-- 路点出口：三级后端（v0.9.14）
--
--   tomtom      TomTom        多点 + 疯狂箭头
--   waypointui  WaypointUI    多点 pin（需在它的设置里开「自定义地图标记」）
--   builtin     暴雪自带路点   只有一格，只能指「下一站」
--
--   ★ 为什么必须有中间这一档（2026-10-16 实机踩到）：
--     本机装的是 **WaypointUI**，不是 TomTom；而 WaypointUI 并不提供
--     TomTom 兼容全局。只认 TomTom 的后果是整条路线**静默退化成纯文本** ——
--     表现就是「点了打点按钮，地图上什么都没有」，不报错、不留痕、最难查。
--
--   ★ WaypointUI 的第二个坑：它开了「自定义地图标记」（CustomMapPinsEnabled）
--     之后会**隐藏暴雪自带的用户路点 pin**（见它的 MapPinFrame.lua 里 shouldHide
--     那段判断）。所以走 WaypointUI 这条路时必须用它的 API，
--     不能指望 C_Map.SetUserWaypoint 还能被看见 —— 这跟「unmodified 的自带路点」
--     是两种世界，代码要按「当前装了谁」分别走。
--
--   三个后端一律是可选依赖：缺了不报错，只降级。跟 SavedInstances /
--   Auctionator 一个待遇，别把可选插件写成硬依赖。
--==========================================================================
function ns.WptBackend()
    if type(TomTom) == "table" and type(TomTom.AddWaypoint) == "function" then
        return "tomtom"
    end
    local W = WaypointUIAPI
    if type(W) == "table" and type(W.Navigation) == "table" then
        local N = W.Navigation
        if type(N.NewPin) == "function" or type(N.NewUserNavigation) == "function" then
            return "waypointui"
        end
    end
    return "builtin"
end

-- 界面显示用：路点插件名（nil = 只能用暴雪自带路点，一次一格）
function ns.WptName()
    local b = ns.WptBackend()
    if b == "tomtom" then return "TomTom" end
    if b == "waypointui" then return "WaypointUI" end
    return nil
end

-- 兼容旧名。语义已放宽成「存在可用的路点插件」——
--   保留是因为别处（DashboardUI / 旧测试）还在引用；
--   新代码请直接用 ns.WptBackend() / ns.WptName()。
function ns.TomTomReady()
    return ns.WptBackend() ~= "builtin"
end

function ns.RouteState()
    return routeState, routeZones
end

-- WaypointUI：把某一条设成**当前导航目标**（带箭头的那种，一次只有一个）。
--   多点 pin 负责「整条路线可见」，这个负责「现在往哪走」。两者配合才完整。
function ns.WptFocus(item, label)
    if ns.WptBackend() ~= "waypointui" then return false end
    local N = WaypointUIAPI and WaypointUIAPI.Navigation
    if not N or type(N.NewUserNavigation) ~= "function" then return false end
    local mapID = tonumber(item and (item.mapID or item.zoneID))
    local x, y = tonumber(item and item.x), tonumber(item and item.y)
    if not (mapID and x and y) then return false end
    local ok = pcall(N.NewUserNavigation, {
        name = label or tostring(item.title or "路点"),
        mapID = mapID, x = x, y = y,
    })
    if ok then routeNavUsed = true end
    return ok
end

function ns.PointArrow(rec)
    if not rec then return end
    local b = ns.WptBackend()
    if b == "tomtom" then
        if not (rec.uid and type(TomTom.SetCrazyArrow) == "function") then return end
        local arrival = 10
        local p = TomTom.profile
        if type(p) == "table" and type(p.arrow) == "table" and tonumber(p.arrow.arrival) then
            arrival = tonumber(p.arrow.arrival)
        end
        pcall(TomTom.SetCrazyArrow, TomTom, rec.uid, arrival, rec.label or "")
    elseif b == "waypointui" then
        ns.WptFocus(rec.item, rec.label)
    end
end

function ns.ClearRoute(quiet)
    local b = ns.WptBackend()
    if b == "tomtom" and type(TomTom.RemoveWaypoint) == "function" then
        for _, r in ipairs(routeState) do
            if r.uid then pcall(TomTom.RemoveWaypoint, TomTom, r.uid) end
        end
    elseif b == "waypointui" then
        local N = WaypointUIAPI and WaypointUIAPI.Navigation
        if N then
            -- ★ 只删**我们自己建的** pin，逐个 ClearPin。
            --   绝不能用 ClearAllPins()：那会把用户手动标的点一起清掉 ——
            --   那是别人的数据，插件没资格碰。
            for _, r in ipairs(routeState) do
                if r.pinID and type(N.ClearPin) == "function" then
                    pcall(N.ClearPin, r.pinID)
                end
            end
            if routeNavUsed and type(N.ClearUserNavigation) == "function" then
                pcall(N.ClearUserNavigation)
            end
        end
    end
    routeNavUsed = false
    local n = #routeState
    routeState = {}
    routeZones = {}
    if not quiet and n > 0 then
        say(("已清掉 %d 个路点（%s）。"):format(n, ns.WptName() or "暴雪自带"))
    end
    return n
end

-- 站名：带序号 + 金额。三个后端都读这一行当路点标题。
local function routeLabel(i, it)
    return ("%d. %s · %dg"):format(i,
        tostring(it.title or ("任务#" .. tostring(it.id))),
        math.floor((tonumber(it.money) or 0) / 10000))
end

-- 把路线发给当前可用的路点后端。items 省略时用实时候选。
function ns.SendRoute(items, opts)
    opts = opts or {}
    local cand = items
    if not cand then cand, _ = ns.RouteCandidates() end

    -- 区域顺序先用「全部候选」算出来（超集没关系：BuildRoute 会把多出来的忽略掉，
    -- 真正没覆盖到的再按金额兜底），避免「先过滤再算区域」的两趟依赖。
    if opts.zoneOrder == nil then
        opts.zoneOrder = ns.ZoneOrder(ns.RouteZoneIDs(cand), opts.originMapID)
    end

    local route, dropped = ns.BuildRoute(cand, opts)
    if #route == 0 then
        ns.PrintRoute(route, dropped)
        return route
    end

    local backend = ns.WptBackend()
    local placed = 0

    -- 区域顺序（三种后端都要用来写文案）—— 与看板同口径：规范区域键
    local lastZone = nil
    for _, it in ipairs(route) do
        local zk = ns.RouteZoneKey(it)
        if zk ~= lastZone then
            lastZone = zk
            routeZones[#routeZones + 1] = ns.ZoneName(zk) or tostring(it.zone or "?")
        end
    end
    local zoneStr = #routeZones > 0 and table.concat(routeZones, " > ") or "?"

    -- ── 后端 ①：TomTom（多点 + 疯狂箭头）─────────────────────────────
    if backend == "tomtom" then
        ns.ClearRoute(true)
        for i, it in ipairs(route) do
            local label = routeLabel(i, it)
            local ok, uid = pcall(TomTom.AddWaypoint, TomTom, it.mapID, it.x, it.y, {
                title = label, persistent = false, minimap = true, world = true, from = "ForLeiJun",
            })
            if ok and uid then
                placed = placed + 1
                routeState[#routeState + 1] = { item = it, uid = uid, label = label, backend = "tomtom" }
            end
        end
        ns.PointArrow(routeState[1])
        say(("路线已发给 TomTom：%d 站 · 区域顺序 %s"):format(placed, zoneStr))
        if placed < #route then
            say(("|cffe0a458注意：%d 站没能打上路点（TomTom 拒了）。|r"):format(#route - placed))
        end

    -- ── 后端 ②：WaypointUI（多点 pin；未开「自定义地图标记」则退成一站）──
    elseif backend == "waypointui" then
        local N = WaypointUIAPI.Navigation
        ns.ClearRoute(true)
        if type(N.NewPin) == "function" then
            for i, it in ipairs(route) do
                local label = routeLabel(i, it)
                -- pin id 必须唯一且稳定：推进路线时靠它精确删掉这一条
                local pid = ("ForLeiJun-route-%s"):format(tostring(it.id or i))
                local ok, pin = pcall(N.NewPin, {
                    id = pid, name = label,
                    mapID = tonumber(it.mapID) or tonumber(it.zoneID),
                    x = tonumber(it.x), y = tonumber(it.y),
                })
                if ok and pin then
                    placed = placed + 1
                    routeState[#routeState + 1] =
                        { item = it, pinID = pid, uid = pid, label = label, backend = "waypointui" }
                end
            end
        end

        if placed > 0 then
            ns.PointArrow(routeState[1])
            say(("路线已发给 WaypointUI：%d 站 · 区域顺序 %s"):format(placed, zoneStr))
        else
            -- NewPin 在「自定义地图标记」关闭时会**静默返回 nil**（不报错），
            -- 所以要靠 placed == 0 反推，并把打开方法直接告诉用户。
            local label = routeLabel(1, route[1])
            if ns.WptFocus(route[1], label) then
                routeState[#routeState + 1] =
                    { item = route[1], label = label, backend = "waypointui-nav" }
                placed = 1
                say("WaypointUI 的「自定义地图标记」没开 —— 只导航了第 1 站。")
                say(("|cffb8ab8c开启路径：WaypointUI 设置 → 地图 → 自定义地图标记；"
                    .. "开了之后 /wb route 会一次铺开全部 %d 站。|r"):format(#route))
            else
                say("|cffe0a458WaypointUI 没能建路点，退回到只打印顺序：|r")
                ns.PrintRoute(route, nil)
            end
        end

    -- ── 后端 ③：暴雪自带路点（只有一格，只能指「下一站」）────────────
    else
        local it = route[1]
        local label = routeLabel(1, it)
        local mapID = tonumber(it.mapID) or tonumber(it.zoneID)
        local okSet = false
        if C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
            okSet = pcall(function()
                C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(
                    mapID, tonumber(it.x), tonumber(it.y)))
            end)
        end
        if okSet then
            placed = 1
            routeState[#routeState + 1] = { item = it, label = label, backend = "builtin" }
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
            end
        end
        say("没装路点插件 —— 暴雪自带路点只有一格，只标了第 1 站。")
        ns.PrintRoute(route, nil)
        say("|cffb8ab8c装 TomTom 或 WaypointUI（并在设置里打开「自定义地图标记」）后，"
            .. "/wb route 会一次铺开整条路线并出箭头。|r")
    end

    if dropped and (dropped.done + dropped.nocoord + dropped.unprobed + dropped.below) > 0 then
        say(("|cffb8ab8c已跳过：完成 %d · 无坐标 %d · 奖励未知 %d · 未达门槛 %d|r")
            :format(dropped.done, dropped.nocoord, dropped.unprobed, dropped.below))
    end
    return route
end

-- 交掉一个任务 → 撤掉它的路点，箭头指向下一站。
--   由 Core.lua 的 QUEST_TURNED_IN 事件调进来（那边带 pcall 兜底）。
function ns.AdvanceRoute(questID)
    local qid = tonumber(questID)
    if not qid or #routeState == 0 then return false end
    for i, r in ipairs(routeState) do
        if tonumber(r.item and r.item.id) == qid then
            -- 按**这条记录当初是用哪个后端建的**来撤，不要按「现在装了什么」——
            --   中途换插件（或 WaypointUI 里改了多点开关）时，混用会撤错对象。
            local b = r.backend or ns.WptBackend()
            if b == "tomtom" then
                if r.uid and type(TomTom.RemoveWaypoint) == "function" then
                    pcall(TomTom.RemoveWaypoint, TomTom, r.uid)
                end
            elseif b == "waypointui" then
                local N = WaypointUIAPI and WaypointUIAPI.Navigation
                if r.pinID and N and type(N.ClearPin) == "function" then
                    pcall(N.ClearPin, r.pinID)
                end
            elseif b == "waypointui-nav" then
                -- 这条占的是导航槽：放开，下面 PointArrow 会重新指向下一站
                routeNavUsed = false
            end
            table.remove(routeState, i)
            if routeState[1] then
                ns.PointArrow(routeState[1])
                say(("这站完成，下一站：%s（还剩 %d 站）")
                    :format(routeState[1].label or "?", #routeState))
            else
                if ns.WptBackend() == "waypointui" then
                    local N = WaypointUIAPI and WaypointUIAPI.Navigation
                    if routeNavUsed and N and type(N.ClearUserNavigation) == "function" then
                        pcall(N.ClearUserNavigation)
                    end
                end
                routeNavUsed = false
                say("|cff8cc63f路线走完了，这一轮全清。|r")
            end
            return true
        end
    end
    return false
end

--==========================================================================
-- 交互：跳地图 / 打路点 / 超追踪
--
--   ★ 所有地图与路点调用都推迟一帧（C_Timer.After(0, ...)）★
--   这些函数是从按钮 / 列表行的 OnClick 里调进来的。如果直接在按钮回调的
--   调用栈上操作 WorldMapFrame，会「污染」暴雪原生 UI —— 表现是地图窗口
--   之后点不动、或暴雪自带的自动追踪失效，而且报错往往指向完全无关的地方。
--   推迟一帧就把调用挪到了干净的栈上，这是 WoW 插件里的标准做法。
--   （UI.lua:329 那处 C_Timer.After(0.05) 是「等布局稳定」的延时，用途不同，
--     别把两者混为一谈。）
--==========================================================================

-- 打开世界地图并定位到指定区域。
--   补设一次：地图如果本来就是开着的，客户端会把它弹回「你所在的区域」，
--   所以 0.2 秒后再确认一遍（实测经验）。
function ns.ShowMapAt(mapID)
    if type(mapID) ~= "number" or mapID <= 0 then return end
    if WorldMapFrame then
        if ToggleWorldMap and not WorldMapFrame:IsShown() then pcall(ToggleWorldMap) end
        pcall(function() WorldMapFrame:SetMapID(mapID) end)
    elseif ToggleWorldMap then
        pcall(ToggleWorldMap)
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0.2, function()
            if WorldMapFrame and WorldMapFrame:IsShown() and WorldMapFrame.GetMapID then
                local ok, cur = pcall(function() return WorldMapFrame:GetMapID() end)
                if ok and cur ~= mapID then
                    pcall(function() WorldMapFrame:SetMapID(mapID) end)
                end
            end
        end)
    end
end

-- 对一条任务：挂追踪 + 打玩家路点 + 超追踪 + 开地图
function ns.GotoQuest(item, silent)
    if type(item) ~= "table" then return false, "没有任务数据" end
    local qid = tonumber(item.id)
    local mapID = tonumber(item.mapID or item.zoneID)
    local x, y = tonumber(item.x), tonumber(item.y)
    local title = tostring(item.title or ("任务#" .. tostring(item.id or "?")))

    if qid and C_QuestLog and type(C_QuestLog.AddWorldQuestWatch) == "function" then
        pcall(C_QuestLog.AddWorldQuestWatch, qid)
    end

    -- 没有坐标：至少把世界地图开到那一张，并说清楚为什么没有路点
    if not (mapID and x and y) then
        if mapID and C_Timer and C_Timer.After then
            C_Timer.After(0, function() ns.ShowMapAt(mapID) end)
        end
        if not silent then
            say(("|cffe0a458%s|r 这条没读到坐标，只打开了地图（没打路点）。"):format(title))
        end
        return false, "no-coord"
    end

    if not (C_Timer and C_Timer.After) then return false, "no-timer" end

    C_Timer.After(0, function()
        -- 优先走「路点后端」：★ 装了 WaypointUI 且开了「自定义地图标记」时，
        --   它会**隐藏暴雪自带的用户路点 pin** —— 只调 SetUserWaypoint 等于什么都没发生。
        --   所以这里必须先问后端是谁，再决定用哪个 API。
        local b = ns.WptBackend()
        if b == "tomtom" then
            local ok, uid = pcall(TomTom.AddWaypoint, TomTom, mapID, x, y, {
                title = title, persistent = false, minimap = true, world = true, from = "ForLeiJun",
            })
            if ok and uid then
                if type(TomTom.SetCrazyArrow) == "function" then
                    pcall(TomTom.SetCrazyArrow, TomTom, uid, 10, title)
                end
                ns.ShowMapAt(mapID)
                return
            end
        elseif b == "waypointui" then
            if ns.WptFocus({ mapID = mapID, x = x, y = y, title = title }, title) then
                ns.ShowMapAt(mapID)
                return
            end
        end

        -- 兜底：暴雪自带路点
        local placed = false
        local canSet = true
        if C_Map and type(C_Map.CanSetUserWaypointOnMap) == "function" then
            local ok, v = pcall(C_Map.CanSetUserWaypointOnMap, mapID)
            if ok and v == false then canSet = false end
        end
        if canSet and C_Map and C_Map.SetUserWaypoint and UiMapPoint
            and UiMapPoint.CreateFromCoordinates then
            local ok = pcall(function()
                C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
            end)
            placed = ok
        end

        if placed and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
        elseif qid and C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
            -- 打不上玩家路点就退回「追踪这个任务」，别什么都没发生
            pcall(C_SuperTrack.SetSuperTrackedQuestID, qid)
        end

        ns.ShowMapAt(mapID)
    end)

    if not silent then say(("已定位：%s"):format(title)) end
    return true
end

--==========================================================================
-- 按「标题 + 区域」去实时池里反查一条。
--
--   用途：看板的数据来自 build.py 的快照（只有标题和区域名，没有 ID 和坐标），
--   而导航需要 ID + 坐标。所以从快照行点过来时，用标题+区域去实时池里找。
--
--   ★ 要求唯一命中。找不着或找到多条一律不下手 —— 猜错比不做更糟：
--     点一下跳到隔壁那张图的另一个同名任务上，会被当成「插件有 bug」，
--     而且很难复现（取决于快照和实时的时差）。
--==========================================================================
local function stripColor(s)
    s = tostring(s or "")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return s
end

function ns.FindLiveWq(title, zone)
    local want = stripColor(title)
    local wantZone = stripColor(zone)
    if want == "" then return nil, "empty" end

    local cand = ns.RouteCandidates()
    local hits = {}
    for _, it in ipairs(cand) do
        if stripColor(it.title) == want then
            if wantZone == "" or stripColor(it.zone) == wantZone then
                hits[#hits + 1] = it
            end
        end
    end
    if #hits == 1 then return hits[1] end
    if #hits == 0 then return nil, "gone" end
    return nil, "ambiguous"
end

-- 给 UI 调用：从快照行跳过去，失败时给出人话解释
function ns.GotoByTitleZone(title, zone)
    local it, why = ns.FindLiveWq(title, zone)
    if it then return ns.GotoQuest(it) end
    if why == "gone" then
        say(("|cffe0a458「%s」这会儿不在场上了|r —— 看板是快照（几小时前的），"
            .. "这条可能已经轮换掉。先 /wb wq 重扫一次再点。"):format(stripColor(title)))
    elseif why == "ambiguous" then
        say(("|cffe0a458「%s」在实时池里对上了多条|r，不敢猜是哪一条。"
            .. "从「行动」页的实时路线块里点，那里带 ID 不会歧义。"):format(stripColor(title)))
    else
        say("这条任务信息不全，定位不了。")
    end
    return false
end

--==========================================================================
-- 诊断：/wb route diag
--   把剔除原因和区域顺序摊开 —— 路线不对时先看这个，别猜。
--==========================================================================
function ns.DiagRoute()
    local out = {}
    local cand, at = ns.RouteCandidates()
    out[#out + 1] = ("实时池候选 %d 条（扫描时刻 %s）"):format(#cand, tostring(at or "?"))
    local zids = ns.RouteZoneIDs(cand)
    local order = ns.ZoneOrder(zids)
    out[#out + 1] = ("区域顺序（离当前位置由近到远）：%s"):format(
        #order > 0 and table.concat(order, " > ") or "(算不出来，将退化为按金额)")
    local opts = { zoneOrder = order }
    local route, dropped = ns.BuildRoute(cand, opts)
    out[#out + 1] = ("可导航 %d 站｜剔除：已完成 %d · 无坐标 %d · 奖励未知 %d · 未达门槛 %d")
        :format(#route, dropped.done, dropped.nocoord, dropped.unprobed, dropped.below)
    out[#out + 1] = ("门槛 %d 铜（%.0f 金）"):format(ns.GoldWqFloor(), ns.GoldWqFloor() / 10000)
    for i, it in ipairs(route) do
        out[#out + 1] = ("  %2d. [map %s] %s · %s · %s 金 · (%.3f, %.3f)"):format(
            i, tostring(it.mapID), tostring(it.title), tostring(it.zone),
            tostring(math.floor((tonumber(it.money) or 0) / 10000)),
            tonumber(it.x) or -1, tonumber(it.y) or -1)
    end
    local b = ns.WptBackend()
    local bdesc = (b == "tomtom" and "TomTom")
        or (b == "waypointui" and "WaypointUI（未开「自定义地图标记」时只能导航一站）")
        or "暴雪自带路点（只有一格）"
    out[#out + 1] = ("路点后端：%s｜当前路线 %d 站"):format(bdesc, #routeState)
    return out
end

-- 自诊断：把「本文件加载成功」记进 ns._mark 的内存轨迹。
--   别删 —— 加载期报错会让本文件**从出错那行起**的后续代码全不执行
--   （注意：**不影响别的文件**。WoW 每个 .lua 独立成一段 chunk，报错只中止这一段。
--    这点最初写反了，已在 Core.lua 自诊断段更正）。
--   轨迹的正确读法：出现名字 = 这个文件走到底了；**缺谁就是谁在加载期挂了**。
--   实证：v0.9.15 时 Auction.lua 因事件名拼错在顶层抛错，轨迹里正好缺它一个。
if ns._mark then ns._mark("Route.lua") end
