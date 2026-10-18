--[[--------------------------------------------------------------------------
    ForLeiJun / Wpt.lua

    路点：只用暴雪原生「用户路点」，不依赖任何路点插件。

    为什么要有这个文件
      对外版原先继承自用版的**三级路点后端**（TomTom → WaypointUI → 暴雪原生）。
      那套逻辑对开发者是合理的（装了谁就用谁），对玩家是**不可控的**：
        · 玩家装了 WaypointUI 但没开「自定义地图标记」→ 打点静默返回 nil，
          地图上什么都没有，也不报错；
        · WaypointUI 开了自定义标记会**隐藏暴雪原生 pin** → 只调 SetUserWaypoint
          等于什么都没发生；
        · TomTom / WaypointUI 的 Libs 被整合包抽走过一次（2026-10-16 实测），
          插件本身能加载，但打点整条链子断掉。
      玩家的机器上装了什么，我们管不了。所以对外版把它砍成一条路：
      **只调客户端的 C_Map.SetUserWaypoint**，装不装别的插件都一样。

    能力上要知道的一件事（也是本文件设计的根）
      暴雪原生用户路点**只有一个格子**。TomTom 那种「一次铺开 20 个 pin + 箭头」
      是它自己画的，客户端没有这个能力。
      所以这里的模型是「队列 + 当前站」：
        · 发路线 = 把整条路线存进队列，只在图上标第 1 站；
        · 交掉当前站（QUEST_TURNED_IN 由 Core.lua 转进来）→ 自动标下一站；
        · 点某一行任务 → 直接把那一站提到队首（想跳着做就跳着做）；
        · 队列写进存档，`/reload` 后按实时池校验一遍再恢复（轮换掉的自然消失）。

    坐标同源铁律（照抄 Route.lua，改这里之前先读那段）
      x / y 来自「扫描时那张图」的 POI，所以必须配 lastMapID（快照里的 item.mapID），
      不能配 zoneID —— zoneID 常是子区域，拿它配坐标会打到隔壁那张图上，
      而且不报错、只是不准。
--------------------------------------------------------------------------]]--

local ADDON, ns = ...

local SAY   = "|cffd97757[雷菌]|r "
local MUTED = "|cffb8ab8c"
local GOOD  = "|cff8cc63f"
local WARN  = "|cffe0a458"

local function say(s) print(SAY .. tostring(s)) end

-- 队列：queue[1] = 当前应该去的那一站
--   每项 = { item = { id, title, mapID, x, y, money }, label = "3. 任务名 · 1500g" }
local queue = {}
local zones = {}

-- 我们打过的点（"mapID:x:y" → true）。
--   ★ 为什么是集合而不是「最后一个」★
--   导航有两条入口：点「▶」走本文件的 setPoint，点某一行走 Route.lua 的
--   builtin 分支（它自己调 C_Map，不经过这里）。只记「最后一个」的话，点了
--   一行之后再来清路线，就会认不出当前那个点其实是我们打的，标记留在图上。
--   记成集合，两条入口打过的点都认得。
local ours = {}

local MAX_KEEP = 40          -- 存档里最多留 40 站（一屏路线也就十几站，留余量）

--==========================================================================
-- 存档
--==========================================================================
local function db()
    local ok, d = pcall(ns.db)
    if ok and type(d) == "table" then return d end
    return nil
end

local function saveQueue()
    local d = db()
    if not d then return end
    if #queue == 0 then
        d.routeQueue = nil
        return
    end
    local stops = {}
    for i = 1, math.min(#queue, MAX_KEEP) do
        local s = queue[i]
        local it = s.item
        stops[i] = {
            id = tonumber(it.id), title = it.title, mapID = tonumber(it.mapID),
            x = tonumber(it.x), y = tonumber(it.y), money = tonumber(it.money),
            zone = it.zone, label = s.label,
        }
    end
    d.routeQueue = { at = (type(time) == "function" and time()) or 0,
                     zones = zones, stops = stops }
end

--==========================================================================
-- 原生路点
--==========================================================================
local function canSet(mapID)
    if type(mapID) ~= "number" or mapID <= 0 then return false end
    if C_Map and type(C_Map.CanSetUserWaypointOnMap) == "function" then
        local ok, v = pcall(C_Map.CanSetUserWaypointOnMap, mapID)
        if ok and v == false then return false end
    end
    return true
end

-- 打一个点。返回 true/false，不抛错（路点失败不该让整条链子断）。
local function setPoint(mapID, x, y)
    if not canSet(mapID) or type(x) ~= "number" or type(y) ~= "number" then return false end
    if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint
        and type(UiMapPoint.CreateFromCoordinates) == "function") then
        return false
    end
    local ok = pcall(function()
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
    end)
    if not ok then return false end
    -- 超追踪：不设这个，路点只在世界地图上，小地图上看不见
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    ours[("%d:%.3f:%.3f"):format(mapID, x, y)] = true
    return true
end

-- 读当前用户路点。客户端各版本字段形状不一样（position.x/y 与 x/y 都见过），
--   两种都读；读不到就返回 nil（**不要**据此认为「没有点」）。
local function currentPoint()
    if not (C_Map and type(C_Map.GetUserWaypoint) == "function") then return nil end
    local ok, p = pcall(C_Map.GetUserWaypoint)
    if not ok or type(p) ~= "table" then return nil end
    local mapID = tonumber(p.uiMapID)
    local pos = p.position or p
    local x = tonumber(pos.x) or tonumber(p.x)
    local y = tonumber(pos.y) or tonumber(p.y)
    if not (mapID and x and y) then return nil end
    return mapID, x, y
end

-- 只清「我们打的」那个点：玩家自己手动标的点不能碰（那是别人的数据，
--   和「绝不 ClearAllPins」是同一条原则）。
local function clearPoint()
    local mapID, x, y = currentPoint()
    local mine = false
    if mapID then
        mine = ours[("%d:%.3f:%.3f"):format(mapID, x, y)] == true
    elseif next(ours) ~= nil then
        -- 读不到当前点（客户端没给这个接口）：既然我们自己打过点，就当它是我们的
        mine = true
    end
    if mine and C_Map and type(C_Map.ClearUserWaypoint) == "function" then
        pcall(C_Map.ClearUserWaypoint)
    end
    ours = {}
end

-- 装了 WaypointUI 的玩家，如果它开着「自定义地图标记」，会**遮住暴雪自带的 pin**。
--   这不是我们的依赖（我们一次都不调它），但结果是「打了点却看不见」——
--   和当初那个坑一模一样的症状。所以只提示一次，并把关掉的位置说清楚。
--   只在真的发了路线时提示，不打扰没这插件的人。
local warnedWpu = false
local function maybeWarnWaypointUI()
    if warnedWpu then return end
    warnedWpu = true
    if type(WaypointUIAPI) ~= "table" then return end
    say(MUTED .. "提示：你装了 WaypointUI。它若开了「自定义地图标记」，会挡住暴雪自带的标记 —— "
        .. "看不到标记就去把它关掉；不关也能看下面表格的顺序跑。" .. "|r")
end

local function labelOf(i, it)
    return ("%d. %s · %dg"):format(i,
        tostring(it.title or ("任务#" .. tostring(it.id))),
        math.floor((tonumber(it.money) or 0) / 10000))
end

local function stopOf(it, label)
    return {
        item = {
            id = tonumber(it.id), title = it.title, zone = it.zone,
            mapID = tonumber(it.mapID) or tonumber(it.zoneID),
            x = tonumber(it.x), y = tonumber(it.y), money = tonumber(it.money),
        },
        label = label,
    }
end

-- 把当前站打出去。返回是否能打（不能打时调用方要给出降级说明）。
local function pointAtHead()
    local s = queue[1]
    if not s then return false end
    return setPoint(s.item.mapID, s.item.x, s.item.y)
end

--==========================================================================
-- 对外接口（覆盖 Route.lua 的同名实现）
--   自用版仍走三级后端；对外版从加载顺序上就把它换掉 —— 这样共享文件
--   不用分叉，也不会出现「改一边忘一边」。
--==========================================================================

-- 永远报 builtin：GotoQuest / 其它分支据此走原生那条路。
function ns.WptBackend() return "builtin" end

-- 界面显示用。nil = 不依赖任何路点插件。
function ns.WptName() return nil end

-- 兼容旧名（自用版语义是「有可用的路点插件」；对外版恒 false）
function ns.TomTomReady() return false end

-- 原生没有「箭头」，这个钩子保留成 no-op，免得调用方判空。
function ns.PointArrow(_) end

function ns.RouteState()
    return queue, zones
end

function ns.RouteCurrent()
    local s = queue[1]
    return s and s.item or nil, s and s.label or nil, #queue
end

-- 发路线：整条存进队列，只在图上标第 1 站。
--   items 省略时用实时候选（与看板同一份数据）。
function ns.SendRoute(items, opts)
    opts = opts or {}
    local cand = items
    if type(cand) ~= "table" then cand = ns.RouteCandidates() end
    if type(cand) ~= "table" then return {} end

    if opts.zoneOrder == nil and ns.RouteZoneIDs and ns.ZoneOrder then
        opts.zoneOrder = ns.ZoneOrder(ns.RouteZoneIDs(cand), opts.originMapID)
    end

    local route, dropped = {}, nil
    if ns.BuildRoute then route, dropped = ns.BuildRoute(cand, opts) end
    if type(route) ~= "table" or #route == 0 then
        say("现在没有可导航的金币世界任务 —— 可能是都做完了，或池还没扫。打开地图（M）会重采一次。")
        return route or {}
    end

    queue, zones = {}, {}
    local lastZone
    for i, it in ipairs(route) do
        local zk = (ns.RouteZoneKey and ns.RouteZoneKey(it)) or tonumber(it.mapID)
        if zk ~= lastZone then
            lastZone = zk
            zones[#zones + 1] = (ns.ZoneName and ns.ZoneName(zk)) or tostring(it.zone or "?")
        end
        queue[#queue + 1] = stopOf(it, labelOf(i, it))
    end
    saveQueue()

    local ok = pointAtHead()
    if ok then
        say(("路线已就绪：%d 站 · 区域顺序 %s"):format(#queue, table.concat(zones, " > ")))
        say(("图上已标出第 1 站：%s"):format(queue[1].label))
        if #queue > 1 then
            say(("%s一次只标一站（暴雪原生只有一格）：交掉当前站会自动指下一站；" ..
                 "想跳着做，点面板里的那一行就行。%s"):format(MUTED, "|r"))
        end
        maybeWarnWaypointUI()
    else
        -- 打不上点也要把顺序交出去，不能静默失败
        say((WARN .. "路线算好了（%d 站），但地图标记没打上%s|r"):format(
            #queue, (queue[1].item.mapID and "（这张图不接受玩家路点）") or "（没读到坐标）"))
        for i, s in ipairs(queue) do
            if i > 12 then say(MUTED .. ("…其余 %d 站看面板"):format(#queue - 12) .. "|r") break end
            say(("  %d) %s"):format(i, s.label))
        end
    end

    if type(dropped) == "table" then
        local skip = (tonumber(dropped.done) or 0) + (tonumber(dropped.nocoord) or 0)
            + (tonumber(dropped.unprobed) or 0) + (tonumber(dropped.below) or 0)
        if skip > 0 then
            say(MUTED .. ("已跳过 %d 条：完成 %d · 没坐标 %d · 奖励没读到 %d · 没到门槛 %d")
                :format(skip, tonumber(dropped.done) or 0, tonumber(dropped.nocoord) or 0,
                        tonumber(dropped.unprobed) or 0, tonumber(dropped.below) or 0) .. "|r")
        end
    end
    return route
end

-- 清路线：清掉队列 + 存档 + 我们打的那个点。
function ns.ClearRoute(quiet)
    local n = #queue
    clearPoint()
    queue, zones = {}, {}
    local d = db()
    if d then d.routeQueue = nil end
    if not quiet then
        if n > 0 then say(("已清掉路线标记（%d 站）。"):format(n))
        else say("当前没有路线标记。") end
    end
    return n
end

-- 交掉一站 → 推进队列。
--   Core.lua 的 QUEST_TURNED_IN 会带 pcall 调进来。
function ns.AdvanceRoute(questID)
    local qid = tonumber(questID)
    if not qid or #queue == 0 then return false end

    local idx
    for i, s in ipairs(queue) do
        if tonumber(s.item.id) == qid then idx = i break end
    end
    if not idx then return false end

    if idx == 1 then
        table.remove(queue, 1)
        saveQueue()
        if #queue == 0 then
            clearPoint()
            say(GOOD .. "路线走完了，这一轮全清。" .. "|r")
        elseif pointAtHead() then
            say(("这站完成，下一站：%s（还剩 %d 站）"):format(queue[1].label, #queue))
        else
            say((WARN .. "这站完成，但下一站没打上标记（地图不接受路点）。还剩 %d 站。|r")
                :format(#queue))
        end
    else
        -- 跳着交的：从队列里去掉，但**不动当前站**（按顺序跑的人不该被带偏）
        table.remove(queue, idx)
        saveQueue()
        say(("这站不在当前目标上，已从队列去掉（还剩 %d 站）。"):format(#queue))
    end
    return true
end

-- 点某一行 = 从那一站开始跑：把那一站提到队首，再走原生导航。
local origGoto = ns.GotoQuest
function ns.GotoQuest(item, silent)
    local qid = tonumber(item and item.id)
    if qid then
        for i = 1, #queue do
            if tonumber(queue[i].item.id) == qid then
                if i > 1 then
                    local s = table.remove(queue, i)
                    table.insert(queue, 1, s)
                    saveQueue()
                end
                break
            end
        end
    end
    local ok = false
    if type(origGoto) == "function" then ok = origGoto(item, silent) end
    -- Route.lua 的原生分支是自己调 C_Map 的，没经过 setPoint ——
    --   这里补记一下，否则「点一行导航 → 清路线」会认不出这个点是我们打的。
    local mapID = tonumber(item and (item.mapID or item.zoneID))
    local x, y = tonumber(item and item.x), tonumber(item and item.y)
    if ok and mapID and x and y then
        ours[("%d:%.3f:%.3f"):format(mapID, x, y)] = true
    end
    return ok
end

--==========================================================================
-- 恢复：/reload 之后重新标出当前站
--
--   ★ 校验口径：只恢复「此刻还在实时池里」的站。★
--   存档是上次会话的，任务会轮换；拿旧坐标打点会把人带到已经没任务的地方。
--   池还没扫出来时**不恢复也不清档**（返回，等下一轮），否则一次登录就把
--   存货吃掉了 —— 这正是「拿痕迹当状态」的老坑。
--==========================================================================
local restoreDone = false

local function tryRestore()
    if restoreDone then return end
    local d = db()
    local q = d and d.routeQueue
    if type(q) ~= "table" or type(q.stops) ~= "table" then
        restoreDone = true
        return
    end

    local cand = (ns.RouteCandidates and ns.RouteCandidates()) or nil
    if type(cand) ~= "table" or #cand == 0 then return end   -- 池还没好，下次再试

    local live = {}
    for _, it in ipairs(cand) do live[tonumber(it.id)] = it end

    local out = {}
    for _, s in ipairs(q.stops) do
        local it = live[tonumber(s.id)]
        if it then
            -- 用**实时池的坐标**，不用存档里的（存档坐标可能已经过期一轮）
            out[#out + 1] = stopOf(it, s.label or labelOf(#out + 1, it))
        end
    end

    restoreDone = true
    if #out == 0 then
        d.routeQueue = nil
        return
    end
    queue, zones = out, (type(q.zones) == "table" and q.zones) or {}
    local ok = pointAtHead()
    if ok then
        say(("路线已恢复：还剩 %d 站（当前：%s）"):format(#queue, queue[1].label))
    end
end

-- 池是异步扫的（登录后 4s / 22s 各一次），所以试三轮；每轮都便宜（一次表读）。
--   导出成 ns.RouteRestore 是为了能在无头测试里直接验「池空时不清档」这个分支 ——
--   定时器在测试里不会跑。
ns.RouteRestore = tryRestore

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:SetScript("OnEvent", function()
    if restoreDone then return end
    if not (C_Timer and C_Timer.After) then return end
    for _, d in ipairs({ 9, 25, 70 }) do
        C_Timer.After(d, function()
            local okR, errR = pcall(ns.RouteRestore)
            if not okR then
                -- 恢复失败不该反复刷屏，也不该让窗口看起来坏了
                if ns._noteError then ns._noteError("Wpt.restore: " .. tostring(errR)) end
            end
        end)
    end
end)

if ns._mark then ns._mark("Wpt.lua") end
