-- 本文件由 tools/build_lite.py 从 ../WeeklyBoard/Pin.lua 同步生成，请勿手改。
-- 改动请改源文件后重跑：python3 tools/build_lite.py
--[[--------------------------------------------------------------------------
    ForLeiJun / Pin.lua —— 置顶小窗（v0.9.24）

    为什么要有这个东西
      看板窗口是「打开→读一遍→关掉」。但有两件事是**边玩边看**的：
        ① 这一趟要飞哪、还剩几个任务、哪个快过期了（世界任务路线）
        ② 这件东西现在卖多少钱（拍卖行）
      每次都要 /wb board → 切页签 → 找那一块，成本太高。所以给它们各开一个
      独立的小窗，压在游戏界面上不挡视线，能拖、能改大小、能随手关掉。

    两个窗口是**独立的**（用户 2026-10-17 选的），各存各的位置和尺寸：
        route = 路线追踪（复用看板「行动」页那张实时路线表，同一份数据、
                同一套列、同一套点击导航）
        ah    = 拍卖行查询（输入物品名 / ID，回车出最低一口价与在售量）

    复用的边界
      行池、DrawTable / Label / Reset 全部复用 DashboardUI 的实现（ns.Board）。
      Pin 只是**第二个渲染宿主**：自己的一套 content / scroll / 行池，用
      setmetatable 把方法借过来。为什么不另写一份「精简表格」：两份必然漂移 ——
      用户会在两个窗口里看到不同的排序、不同的特别任务进度（v0.9.17 的
      页签白名单漂移就是这么翻的车）。

    存档
      ForLeiJunDB.pin.route / .ah = { w, h, left, top, keep }
        keep = 「用户要不要它」（v0.9.26）。不是「上次显示着没有」——
        后者会被任何一次顺手 Hide 写坏，于是重载就不出现。
--------------------------------------------------------------------------]]--

local ADDON, ns = ...

local UI = ns.Board

local Pin = ns.Pin or {}
ns.Pin = Pin

--==========================================================================
-- 配色（与 DashboardUI 同一套 —— 两个窗口底色不一样会显得是两个插件）
--==========================================================================
local GOLD, GOLD_DIM = "fff2c94e", "ffc08a3e"
local TEXT, TEXT2, MUTED = "fff0e6cc", "ffdccfae", "ffb8ab8c"
local WARN, BAD, GOOD = "ffe9c058", "ffe06a50", "ff8cc63f"

local BG    = { 0.055, 0.045, 0.035, 0.93 }
local EDGE  = { 0.42, 0.33, 0.17, 1 }
local PAD   = 10
local BAR_H = 26          -- 标题栏（兼拖动区）
local MIN_W, MIN_H = 380, 170

local function colorText(code, s)
    return "|c" .. code .. tostring(s) .. "|r"
end

-- 数字兜底（与 DashboardUI 同名助手同一口径；置顶窗此前用不到，v0.9.33 卡片要）
local function num(v)
    return tonumber(v) or 0
end

local function box(parent, r, g, b, a)
    local t = parent:CreateTexture(nil, "BACKGROUND")
    t:SetColorTexture(r, g, b, a)
    return t
end

-- 铜 → 金（与 DashboardUI 同一套档位，两边读数不会对不上）
local function goldStr(copper)
    local g = (tonumber(copper) or 0) / 10000
    local a = math.abs(g)
    if a >= 1e8 then return string.format("%.2f亿", g / 1e8) end
    if a >= 1e4 then return string.format("%.1f万", g / 1e4) end
    if a >= 100 then return string.format("%.0f", g) end
    return string.format("%.2f", g)
end

--==========================================================================
-- 存档
--   注意：ns.db() 在 PLAYER_LOGIN 之前拿不到（SavedVariables 还没加载），
--   所以所有读写都推迟到「真的要建窗口 / 真的要开关」的时候，绝不在加载期调。
--==========================================================================
local function pinDb()
    local d = ns.db()
    local p = d.pin
    if type(p) ~= "table" then p = {}; d.pin = p end
    return p
end

local function cfg(key)
    local p = pinDb()
    local c = p[key]
    if type(c) ~= "table" then c = {}; p[key] = c end
    return c
end

-- 屏幕尺寸（UIParent 口径，与 GetLeft/GetTop 同一坐标系）
local function uiSize()
    local w = (UIParent and UIParent.GetWidth) and UIParent:GetWidth() or 0
    local h = (UIParent and UIParent.GetHeight) and UIParent:GetHeight() or 0
    if not w or w <= 0 or not h or h <= 0 then return 1920, 1080 end
    return w, h
end

-- 这块矩形「看得见」吗？至少要有 80 宽 × 40 高落在屏幕里。
--   ⚠ 这条检查是 v0.9.26 的核心：上一版把存档里的 left/top 直接 SetPoint。
--   一旦某次拖出界 / 改了分辨率 / 改了 UI 缩放，存档里就是一个「在屏幕外」的
--   坐标 —— 之后每次登录窗口都被放到看不见的地方，`IsShown()` 却一直是 true。
--   用户的体感就是「一重载就没了」，而且怎么点 /wb pin 也找不回来。
local function onScreen(l, t, w, h)
    l, t = tonumber(l), tonumber(t)
    if not l or not t then return false end
    local sw, sh = uiSize()
    if l >= sw - 80 then return false end
    if l + (tonumber(w) or 0) <= 80 then return false end
    if t <= 40 then return false end
    if t - (tonumber(h) or 0) >= sh - 40 then return false end
    return true
end

local function saveBox(key, f)
    local c = cfg(key)
    local w, h = f:GetWidth() or 0, f:GetHeight() or 0
    local l, t = f:GetLeft(), f:GetTop()
    if not (l and t) then return end
    -- 屏幕外的位置不存：存了就等于「下次登录自己藏起来」
    if not onScreen(l, t, w, h) then return end
    c.w = math.floor(w + 0.5)
    c.h = math.floor(h + 0.5)
    c.left = math.floor(l + 0.5)
    c.top = math.floor(t + 0.5)
end

-- 「这个窗该不该在那儿」—— 唯一真相源（v0.9.26）
--   用户的要求：角色在线就一直在，只有「手动关」才不要它。
--   所以存的是**意图**（keep），而不是「上一刻显示着没有」。
--   旧版存 shown，由 OnShow/OnHide 写；可 OnHide 会被任何东西触发（过场、
--   被别的面板顶掉、退出重载时的界面拆解），一次噪音就把「开着」写成「关」，
--   下次登录自然不出现。意图不会被这些噪音改写。
local function saveKeep(key, on)
    local c = cfg(key)
    c.keep = on and true or false
end

local function wantShown(key)
    local ok, p = pcall(pinDb)
    if not ok or type(p) ~= "table" then return false end
    local c = p[key]
    if type(c) ~= "table" then return true end   -- 从没设置过：默认要它在
    return c.keep ~= false
end

--==========================================================================
-- 布局配置（v0.9.36）：Layout.lua 的 ns.LAYOUT → 归一化后的 L
--
--   为什么要这一层
--     以前「块顺序 / 显示哪几个大数 / 卡片几列 / 文案」全写死在 Refresh 里，
--     用户每调一次布局就得改 Lua、重新装机 —— 原型工作台调了半天，最后
--     还是要等助手动手。现在「怎么摆」变成数据：Layout.lua 是数据，
--     Pin.lua 是渲染器；换布局 = 换配置 + /reload。
--
--   信任边界（重要）
--     Layout.lua 是插件目录里的一个文本文件，且由外部工具生成 —— 当**不可信
--     输入**处理：未知块 id / 未知排序 / 越界列数一律丢弃或收敛。
--     只读「结构、显示项、文案」；**数字永远现算**（工作台里的示例站数/金币
--     若被当数据读进来，窗口上就是假账）。
--==========================================================================
local SEC_ORDER = { "summary", "total", "maps", "table" }
local SEC_SET = { summary = true, total = true, maps = true, table = true }

-- 归一化：缺字段补默认、脏值收敛。测试与 /wb layout 共用这一份。
local function lay()
    local src = ns.LAYOUT
    if type(src) ~= "table" then src = {} end
    local L = { rev = tonumber(src.rev) or 0, winW = tonumber(src.winW) }

    local seen, secs = {}, {}
    if type(src.sections) == "table" then
        for _, it in ipairs(src.sections) do
            if type(it) == "table" and SEC_SET[it.id] and not seen[it.id] then
                seen[it.id] = true
                secs[#secs + 1] = { id = it.id, on = (it.on ~= false) }
            end
        end
    end
    for _, id in ipairs(SEC_ORDER) do
        if not seen[id] then secs[#secs + 1] = { id = id, on = (id ~= "total") } end
    end
    L.sections = secs

    local function flags(t, keys, dflt)
        local out = {}
        for _, k in ipairs(keys) do
            -- ⚠ 不能写 `t[k] or nil`：值是 false 时 `(cond) and false or nil` 会
            --   把 false 变成 nil，于是「显式关掉」被当成「没配」→ 又按默认打开了。
            --   配置里 false 是**有意义的**（用户就是要关这项），必须原样保留。
            local v
            if type(t) == "table" then v = t[k] end
            if v == nil then out[k] = (dflt[k] == true) else out[k] = (v == true) end
        end
        return out
    end
    L.total = flags(src.total, { "stations", "quests", "gold", "sa", "weekly" },
                    { stations = true, quests = true, gold = true, sa = true })
    L.maps = flags(src.maps, { "stations", "gold", "sa", "bar", "eta" },
                   { stations = true, gold = true, sa = true, bar = true })
    local ms = (type(src.maps) == "table") and src.maps or {}
    L.maps.empty = (ms.empty ~= false)
    L.maps.cols = math.max(1, math.min(3, math.floor((tonumber(ms.cols) or 1) + 0.5)))
    local srt = ms.sort
    if srt ~= "gold" and srt ~= "eta" and srt ~= "name" then srt = "custom" end
    L.maps.sort = srt
    L.maps.order = (type(ms.order) == "table") and ms.order or {}

    local tb = (type(src.table) == "table") and src.table or {}
    L.table = { eta = (tb.eta ~= false), coord = (tb.coord ~= false) }

    local txt = {}
    if type(src.txt) == "table" then
        for k, v in pairs(src.txt) do
            if type(k) == "string" and type(v) == "string" and v ~= "" then txt[k] = v end
        end
    end
    L.txt = txt
    local ov = {}
    if type(src.ov) == "table" then
        for k, v in pairs(src.ov) do
            if type(k) == "string" and type(v) == "table" then ov[k] = v end
        end
    end
    L.ov = ov

    -- 拍卖置顶窗的文案配置（v0.9.38）：标题 / 输入框占位符 / 空态说明。
    --   main（为了雷菌主窗四格）由 LiteUI 自己读，这里不碰 —— 主窗只有对外版有。
    local function cstr(v)
        return (type(v) == "string" and v ~= "") and v or nil
    end
    local asrc = (type(src.ah) == "table") and src.ah or {}
    L.ah = { title = cstr(asrc.title),
             placeholder = cstr(asrc.placeholder),
             hint = cstr(asrc.hint) }
    return L
end
ns.PinLayout = lay

-- 文案覆盖。**只对不含实时数据的标签生效**：
--   bigcap / th:N / name:<图名>  → 生效
--   hint / sa:<图名> / eta:<图名> → 忽略（里面是站数、解锁进度、剩余时间，
--     固化下来就是把「0 站」「2/3」印死在窗口上，第二天还是那句）
local function tx(L, key, def)
    local v = L.txt[key]
    if type(v) == "string" and v ~= "" then return v end
    return def
end

-- 单卡三态覆盖：先看 ov[图名][key]，否则跟全局
local function vis(L, name, key)
    local o = (type(L.ov[name]) == "table") and L.ov[name][key] or nil
    if o == "on" then return true end
    if o == "off" then return false end
    return L.maps[key] == true
end

local function leftStr(sec)
    sec = tonumber(sec)
    if not sec or sec <= 0 then return nil end
    local m = math.floor(sec / 60)
    if m < 60 then return (m < 1 and "不到 1 分" or (m .. " 分")) end
    local h = math.floor(m / 60)
    if h < 48 then return h .. " 小时" end
    return math.floor(h / 24) .. " 天" .. (h % 24) .. " 时"
end

--==========================================================================
-- 窗口定义（默认位置避开人物与右侧动作条）
--==========================================================================
local DEFS = {
    route = {
        title = "路线追踪",
        w = 660, h = 430,
        point = { "TOPRIGHT", "TOPRIGHT", -40, -170 },
    },
    ah = {
        title = "拍卖行查询",
        w = 640, h = 450,
        point = { "LEFT", "LEFT", 40, -120 },
    },
}

local WINS = {}          -- key -> 实例（懒建，第一次打开才建）

--==========================================================================
-- 窗口骨架：底 + 四边 + 标题栏 + 关闭 + 缩放角 + 滚动内容区
--   边是手画的四条纹理，不依赖 Backdrop 模板（那套模板名各版本改过，
--   见 DashboardUI 的同款注释）。
--==========================================================================
local function buildShell(inst, def, key)
    local c = cfg(key)
    local f = CreateFrame("Frame", "ForLeiJunPin" .. key, UIParent)
    -- 布局配置（v0.9.36）：rev 变了说明用户刚应用过新配置 → 宽度以配置为准，
    --   清掉旧的拖拽宽度（否则「我在工作台里把窗宽从 660 改成 520」看起来毫无反应）。
    --   rev == 0 = 出厂默认，不碰宽度（与旧版行为一致）。
    local L = lay()
    if key == "route" and L.rev > 0 and tonumber(L.winW) and c.layoutRev ~= L.rev then
        c.layoutRev = L.rev
        c.w = nil
    end
    local w0 = math.max(MIN_W, tonumber(c.w) or ((key == "route") and tonumber(L.winW)) or def.w)
    local h0 = math.max(MIN_H, tonumber(c.h) or def.h)
    f:SetSize(w0, h0)
    -- 位置：存的是屏幕坐标（GetLeft/GetTop 的口径），用 UIParent 的
    -- BOTTOMLEFT 当原点还原。**先校验再落位**：存档里可能是一个屏幕外的
    -- 坐标（拖出界 / 换分辨率 / 换 UI 缩放），直接 SetPoint 会让窗口
    -- 「显示着但看不见」，用户以为它没恢复。
    if onScreen(c.left, c.top, w0, h0) then
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", c.left, c.top)
    else
        f:SetPoint(def.point[1], UIParent, def.point[2], def.point[3], def.point[4])
    end
    -- ★ 层级：必须高于「全屏面板」★
    --   v0.9.24 用的是 DIALOG —— 而地图（WorldMapFrame）、任务日志这些都在
    --   FULLSCREEN_DIALOG 层，一打开就把置顶窗整个盖住。用户看到的是
    --   「窗口动不动就消失」，其实是「被盖住了，压根没画在可见处」。
    --   抬到 FULLSCREEN_DIALOG 再给个大 level（同层按 level 比高低），
    --   这样边看地图边看路线才不会白做这个小窗。
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)      -- 背景吃鼠标，右键不会把镜头转走
    f:SetFrameLevel(200)
    inst.frame = f

    box(f, BG[1], BG[2], BG[3], BG[4]):SetAllPoints()
    -- 四条边：横向两条锚左右两端、纵向两条锚上下两端（窗口可缩放，不能用固定长度）
    local et = box(f, EDGE[1], EDGE[2], EDGE[3], 0.85)
    et:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    et:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    et:SetHeight(1)
    local eb = box(f, EDGE[1], EDGE[2], EDGE[3], 0.85)
    eb:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    eb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    eb:SetHeight(1)
    local el = box(f, EDGE[1], EDGE[2], EDGE[3], 0.85)
    el:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    el:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    el:SetWidth(1)
    local er = box(f, EDGE[1], EDGE[2], EDGE[3], 0.85)
    er:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    er:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    er:SetWidth(1)

    -- 标题栏（拖动区）
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    bar:SetHeight(BAR_H)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() f:StartMoving() end)
    bar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        saveBox(key, f)
    end)
    box(bar, 1, 1, 1, 0.05):SetAllPoints()

    local title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", bar, "LEFT", PAD, 0)
    -- 窗口标题也走配置（v0.9.38）：路线窗用 txt.title 覆盖，拍卖窗用 ah.title
    local titleText = def.title
    if key == "route" then
        titleText = tx(L, "title", def.title)
    elseif key == "ah" and L.ah.title then
        titleText = L.ah.title
    end
    title:SetText(colorText(GOLD, titleText))
    inst.title = title

    -- 右上角：关闭
    local close = CreateFrame("Button", nil, bar)
    close:SetSize(16, 16)
    close:SetPoint("RIGHT", bar, "RIGHT", -6, 0)
    local cx = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cx:SetPoint("CENTER")
    cx:SetText(colorText(MUTED, "×"))
    close:SetScript("OnEnter", function() cx:SetText(colorText(BAD, "×")) end)
    close:SetScript("OnLeave", function() cx:SetText(colorText(MUTED, "×")) end)
    close:SetScript("OnClick", function() Pin:Hide(key) end)

    -- 关闭左边：刷新（拍卖窗查完价想立刻重扫时用得上）
    local rf = CreateFrame("Button", nil, bar)
    rf:SetSize(34, 16)
    rf:SetPoint("RIGHT", close, "LEFT", -8, 0)
    local rt = rf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rt:SetPoint("CENTER")
    rt:SetText(colorText(MUTED, "刷新"))
    rf:SetScript("OnEnter", function() rt:SetText(colorText(GOLD, "刷新")) end)
    rf:SetScript("OnLeave", function() rt:SetText(colorText(MUTED, "刷新")) end)
    rf:SetScript("OnClick", function() inst:Refresh() end)

    -- 滚动内容区（下边留出缩放角的位置）
    local okTpl, scroll = pcall(CreateFrame, "ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    if not okTpl then scroll = CreateFrame("ScrollFrame", nil, f) end
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(BAR_H + 6))
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(PAD + 12), PAD + 4)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local step = 34
        local maxS = math.max(0, self:GetVerticalScrollRange() or 0)
        local v = self:GetVerticalScroll() or 0
        if delta > 0 then v = math.max(0, v - step) else v = math.min(maxS, v + step) end
        self:SetVerticalScroll(v)
    end)
    inst.scroll = scroll

    local content = CreateFrame("Frame", nil, scroll)
    content:SetPoint("TOPLEFT")
    -- 宽度要减掉模板滚动条：scroll 宽 = W - 2PAD - 12，条占 ~20
    content:SetWidth(math.max(100, (c.w or def.w) - PAD * 2 - 32))
    content:SetHeight(10)
    scroll:SetScrollChild(content)
    inst.content = content

    -- 行池（每个宿主一套，互不干扰；行/格/标签的复用逻辑全在 UI 里）
    inst.rows, inst.labels, inst.bars = {}, {}, {}
    inst.nRow, inst.nLabel, inst.nBar = 0, 0, 0

    -- ★ 缩放角 ★
    --   按下瞬间先把窗口钉成 TOPLEFT 锚定：不然 CENTER 锚定的窗口会两边一起长，
    --   左下角跟着跑，手感很差。松手才重画表格（每帧重建几十行会卡）。
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    local gtex = grip:CreateTexture(nil, "ARTWORK")
    gtex:SetAllPoints()
    gtex:SetColorTexture(0.91, 0.75, 0.34, 0.22)
    grip:SetScript("OnEnter", function() gtex:SetColorTexture(0.91, 0.75, 0.34, 0.55) end)
    grip:SetScript("OnLeave", function()
        if not grip._drag then gtex:SetColorTexture(0.91, 0.75, 0.34, 0.22) end
    end)
    grip:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self._drag = true
        local left, top = f:GetLeft(), f:GetTop()
        if left and top then
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        end
        local sw, sh = f:GetWidth(), f:GetHeight()
        local px, py = GetCursorPosition()
        local sc = f:GetEffectiveScale() or 1
        if sc <= 0 then sc = 1 end
        local sx, sy = px / sc, py / sc
        self:SetScript("OnUpdate", function()
            local nx, ny = GetCursorPosition()
            nx, ny = nx / sc, ny / sc
            f:SetSize(math.max(MIN_W, sw + (nx - sx)), math.max(MIN_H, sh - (ny - sy)))
        end)
    end)
    grip:SetScript("OnMouseUp", function(self)
        self._drag = nil
        self:SetScript("OnUpdate", nil)
        saveBox(key, f)
        inst:Refresh()
    end)
    inst.grip = grip

    -- 尺寸变了（拖拽 / UI 缩放变化）→ 重排。拖动中不重画，松手补一次。
    f:SetScript("OnSizeChanged", function(_, w)
        if inst.content then
            inst.content:SetWidth(math.max(100, w - PAD * 2 - 32))
        end
    end)

    f:Hide()
    -- Hide 之后再挂 OnShow/OnHide（建窗时那次 Hide 不该引发任何副作用）
    f:SetScript("OnShow", function()
        inst._hiddenAt = nil
        inst:Refresh()
    end)
    f:SetScript("OnHide", function()
        -- ★ v0.9.26：OnHide 里**什么都不记** ★
        --   谁关的都可能：暴雪面板、过场动画、界面重载时的整体拆解……
        --   拿它当「用户不要了」的证据，误关一次就永不回来 —— 这正是
        --   「每次重载就没了」的根。要不要它只由 keep 决定（见 Pin:Hide）。
        --   位置倒是可以顺手存一次（关之前那一刻的位置是真位置）。
        inst._hiddenAt = (GetTime and GetTime()) or 0
        saveBox(key, f)
    end)

    -- ★ 故意**不**进 UISpecialFrames（v0.9.26）★
    --   进了就得跟暴雪 CloseSpecialWindows()（从数组末尾往前找第一个显示的
    --   关掉）的遍历方向斗智：追加到末尾 → 按 Esc 第一个关它；插到头部 →
    --   所有窗口关完了再按一次还是关它。两条都不对，因为用户要的是
    --   「只要在线就一直在」。所以干脆不让 Esc 碰它：
    --   关它就两招 —— 标题栏的 × ，/wb pin off。

    return f
end


--==========================================================================
-- 路线窗
--==========================================================================
local RouteWin = setmetatable({}, { __index = UI })

-- 每图汇总卡（v0.9.33）：路线表上方一摞「N 站 · 合计 X 金」小卡，
--   卡顶一条**特别任务状态色条**（Row.top 复用）：
--     绿   = 已解锁未完成     金   = 本周已做完
--     黄   = 有目录未解锁     灰   = 进度未知
--     无条 = 这张图没有特别任务目录
--   数据跟路线表同一份（routeBlocks / buildRoute 挂在 table.maps 上），
--   不另算一遍 —— 两份数据必然漂移。
local SA_STATE_COLOR = {
    unlocked = { 0.55, 0.78, 0.25 },   -- 绿：亮着可做
    done     = { 0.95, 0.79, 0.31 },   -- 金：本周做完
    locked   = { 0.91, 0.75, 0.34 },   -- 黄：未解锁（有进度）
    unknown  = { 0.62, 0.58, 0.47 },   -- 灰：进度未知
}
local SA_STATE_TIP = {
    unlocked = "已解锁未完成：回这张图做亮着的 ★ 任务",
    done     = "本周特别任务已全部做完（每周重置后刷新）",
    locked   = "特别任务未解锁：本周在这张图做满 3 个世界任务后亮起",
    unknown  = "这张图有特别任务目录，但这个角色还没有解锁记录",
    none     = "这张图没有特别任务目录",
}

-- 卡片高度：第一行（图名 + 数字）固定的 24，之后每多一行 +14/+12
local function cardHeight(L, mc)
    local h = 24
    if vis(L, mc.name, "sa") and mc.sa ~= "none" and tostring(mc.saText or "") ~= "" then
        h = h + 14
    end
    if vis(L, mc.name, "eta") and leftStr(mc.leftSeconds) then
        h = h + 12
    end
    return h
end

-- 排序 / 过滤（配置里的 sort + order）
--   custom：按工作台里拖好的图名顺序；没列到的图跟在后面（保持路线原本的区域顺序）
local function orderMaps(L, maps)
    local list = {}
    for _, mc in ipairs(maps) do
        if L.maps.empty or num(mc.n) > 0 then list[#list + 1] = mc end
    end
    local mode = L.maps.sort
    if mode == "gold" then
        table.sort(list, function(a, b)
            local ga, gb = num(a.gold), num(b.gold)
            if ga ~= gb then return ga > gb end
            return tostring(a.name) < tostring(b.name)
        end)
    elseif mode == "eta" then
        table.sort(list, function(a, b)
            local ea, eb = tonumber(a.leftSeconds), tonumber(b.leftSeconds)
            if ea and eb and ea ~= eb then return ea < eb end
            if ea and not eb then return true end
            if eb and not ea then return false end
            return tostring(a.name) < tostring(b.name)
        end)
    elseif mode == "name" then
        table.sort(list, function(a, b) return tostring(a.name) < tostring(b.name) end)
    elseif type(L.maps.order) == "table" then
        local pos = {}
        for i, n in ipairs(L.maps.order) do
            if pos[n] == nil then pos[n] = i end
        end
        if next(pos) then
            local n = #list
            for i = 1, n do list[i]._i = i end
            table.sort(list, function(a, b)
                local pa, pb = pos[tostring(a.name)], pos[tostring(b.name)]
                if pa and pb then return pa < pb end
                if pa then return true end
                if pb then return false end
                return a._i < b._i
            end)
        end
    end
    return list
end

local function drawOneCard(self, L, mc, x, y, cw, h)
    local r = self:Row()
    r:SetPoint("TOPLEFT", self.content, "TOPLEFT", x, -y)
    r:SetWidth(cw)
    r:SetHeight(h)
    r.bg:SetColorTexture(1, 1, 1, 0.045)
    r.bg:Show()

    -- 状态色条（复用组头的顶部粗线纹理；Row() 已把它藏掉，要才 Show）
    local c = SA_STATE_COLOR[mc.sa]
    if r.top and c and vis(L, mc.name, "bar") then
        r.top:SetColorTexture(c[1], c[2], c[3], 0.9)
        r.top:SetHeight(3)
        r.top:Show()
    end

    -- 第 1 行：图名（左） + 数字（右）
    local shown = tx(L, "name:" .. tostring(mc.name or ""), tostring(mc.name or "?"))
    local c1 = self:Cell(r, 1)
    c1:SetText(colorText(TEXT, shown))
    c1:SetJustifyH("LEFT")
    c1:SetWordWrap(false)
    c1:SetWidth(math.max(40, cw - 120))
    c1:SetPoint("TOPLEFT", r, "TOPLEFT", 9, -7)

    local showS, showG = vis(L, mc.name, "stations"), vis(L, mc.name, "gold")
    local c2 = self:Cell(r, 2)
    if num(mc.n) <= 0 then
        -- 0 站说「没有路线站」比「0 站 · 0 金」更像人话（这张图只有特别任务状态）
        c2:SetText(colorText(MUTED, "没有路线站"))
    elseif showS and showG then
        c2:SetText(colorText(GOLD, ("%d 站 · %s 金"):format(num(mc.n), goldStr(mc.gold))))
    elseif showG then
        c2:SetText(colorText(GOLD, goldStr(mc.gold) .. " 金"))
    elseif showS then
        c2:SetText(colorText(GOLD, ("%d 站"):format(num(mc.n))))
    else
        c2:SetText(colorText(MUTED, "有站"))
    end
    c2:SetJustifyH("RIGHT")
    c2:SetWordWrap(false)
    c2:SetWidth(math.max(40, cw - 100))
    c2:SetPoint("TOPRIGHT", r, "TOPRIGHT", -9, -7)

    local ly = 22
    -- 第 2 行：特别任务状态
    if vis(L, mc.name, "sa") and mc.sa ~= "none" and tostring(mc.saText or "") ~= "" then
        local scode = WARN
        if mc.sa == "unlocked" then scode = GOOD
        elseif mc.sa == "done" then scode = GOLD_DIM
        elseif mc.sa == "unknown" then scode = MUTED end
        local c3 = self:Cell(r, 3)
        c3:SetText(colorText(scode, "特别任务 · " .. tostring(mc.saText or "")))
        c3:SetJustifyH("LEFT")
        c3:SetWordWrap(false)
        c3:SetWidth(math.max(40, cw - 18))
        c3:SetPoint("TOPLEFT", r, "TOPLEFT", 9, -ly)
        ly = ly + 14
    end
    -- 第 3 行：最短剩余时间
    local ls = leftStr(mc.leftSeconds)
    if vis(L, mc.name, "eta") and ls then
        local c4 = self:Cell(r, 4)
        c4:SetText(colorText(MUTED, "最近一站 " .. ls))
        c4:SetJustifyH("LEFT")
        c4:SetWordWrap(false)
        c4:SetWidth(math.max(40, cw - 18))
        c4:SetPoint("TOPLEFT", r, "TOPLEFT", 9, -ly)
    end

    -- 悬停出状态说明（色块看不懂配色时鼠标一放就知道）
    local stext = SA_STATE_TIP[mc.sa] or SA_STATE_TIP.none
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(f)
        if GameTooltip then
            GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
            GameTooltip:ClearLines()
            GameTooltip:AddLine(tostring(mc.name or "?"), 0.94, 0.9, 0.8)
            GameTooltip:AddLine(stext, 0.72, 0.67, 0.55)
            if num(mc.n) > 0 then
                GameTooltip:AddLine(("%d 个金币任务 · 合计 %s 金（任务实发，不含掉落）")
                    :format(num(mc.n), goldStr(mc.gold)), 0.91, 0.75, 0.34)
            end
            if ls then
                GameTooltip:AddLine("最近一站 " .. ls .. " 后过期", 0.72, 0.67, 0.55)
            end
            GameTooltip:Show()
        end
    end)
    r:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
        r.bg:SetColorTexture(1, 1, 1, 0.045)
    end)
end

-- 每图卡片（1~3 列）。同一排的卡等高，进度条/色条永远贴顶 —— 参差不齐会像没对齐。
local function drawMapCards(self, L, maps, y, width)
    if type(maps) ~= "table" or #maps == 0 then return y end
    local list = orderMaps(L, maps)
    if #list == 0 then return y end
    local cols = L.maps.cols
    local gap = 6
    local cw = math.floor((width - gap * (cols - 1)) / cols)
    local i = 1
    while i <= #list do
        local band, hs = 0, {}
        for k = 0, cols - 1 do
            local mc = list[i + k]
            if mc then
                hs[k + 1] = cardHeight(L, mc)
                if hs[k + 1] > band then band = hs[k + 1] end
            end
        end
        for k = 0, cols - 1 do
            local mc = list[i + k]
            if mc then
                drawOneCard(self, L, mc, k * (cw + gap), y, cw, band)
            end
        end
        y = y + band + gap
        i = i + cols
    end
    return y + 2
end

--==========================================================================
-- 总览大数卡（v0.9.36）
--   一行大数（合计金币）+ 一行指标。指标口径：
--     总站 / 合计金  —— 各图卡求和（路线站数，就是这趟要跑几个任务）
--     世界任务      —— 池快照里的活任务总数（含没金币的，看「值不值得跑」的基数）
--     特别任务      —— 按图计数（可做 / 已做完 / 未解锁 / 未知）
--     本周上交      —— chars[key].weeklyQuests.totals.handins（角色级，跨周清零）
--   没有的数据一律不编：拿不到就不显示那一项，而不是印个 0。
--==========================================================================
local function liveWqTotal()
    local ok, d = pcall(ns.db)
    if not ok or type(d) ~= "table" then return nil end
    local w = d.worldQuests
    if type(w) == "table" and tonumber(w.total) then return tonumber(w.total) end
    return nil
end

local function weeklyHandins()
    local ok, d = pcall(ns.db)
    if not ok or type(d) ~= "table" then return nil end
    local ck = ns.CharKey and ns.CharKey()
    local c = ck and type(d.chars) == "table" and d.chars[ck] or nil
    local q = type(c) == "table" and c.weeklyQuests or nil
    local t = type(q) == "table" and q.totals or nil
    if type(t) == "table" and tonumber(t.handins) then return tonumber(t.handins) end
    return nil
end

local function drawTotal(self, L, maps, y, width)
    local st, gold = 0, 0
    local cnt = { done = 0, unlocked = 0, locked = 0, unknown = 0 }
    for _, mc in ipairs(maps or {}) do
        st = st + num(mc.n)
        gold = gold + num(mc.gold)
        if cnt[mc.sa] then cnt[mc.sa] = cnt[mc.sa] + 1 end
    end

    local h = 46
    local r = self:Row()
    r:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -y)
    r:SetWidth(width)
    r:SetHeight(h)
    r.bg:SetColorTexture(1, 1, 1, 0.055)
    r.bg:Show()
    if r.top then
        r.top:SetColorTexture(0.91, 0.75, 0.34, 0.85)
        r.top:SetHeight(3)
        r.top:Show()
    end

    local big, cap
    if L.total.gold then
        big, cap = goldStr(gold), tx(L, "bigcap", "金 · 合计可拿")
    else
        big, cap = ("%d"):format(st), tx(L, "bigcap", "站 · 这一趟要跑")
    end
    local b1 = self:Label("GameFontNormalLarge")
    b1:SetPoint("TOPLEFT", r, "TOPLEFT", 10, -5)
    b1:SetText(colorText(GOLD, big) .. " " .. colorText(MUTED, cap))

    local parts = {}
    if L.total.stations then
        parts[#parts + 1] = "总站 " .. colorText(TEXT, ("%d"):format(st))
    end
    if L.total.quests then
        local n = liveWqTotal()
        if n then parts[#parts + 1] = "世界任务 " .. colorText(TEXT, ("%d"):format(n)) end
    end
    if L.total.sa then
        local sa = {}
        if cnt.done > 0 then sa[#sa + 1] = cnt.done .. " 图已做完" end
        if cnt.unlocked > 0 then sa[#sa + 1] = cnt.unlocked .. " 图可做" end
        if cnt.locked > 0 then sa[#sa + 1] = cnt.locked .. " 图未解锁" end
        if cnt.unknown > 0 then sa[#sa + 1] = cnt.unknown .. " 图未知" end
        parts[#parts + 1] = "特别任务 " ..
            colorText(TEXT, (#sa > 0) and table.concat(sa, " · ") or "没目录")
    end
    if L.total.weekly then
        local n = weeklyHandins()
        if n then parts[#parts + 1] = "本周上交 " .. colorText(TEXT, ("%d 次"):format(n)) end
    end
    if #parts > 0 then
        local b2 = self:Label("GameFontNormalSmall")
        b2:SetPoint("TOPLEFT", r, "TOPLEFT", 11, -29)
        b2:SetWidth(math.max(60, width - 22))
        b2:SetWordWrap(false)
        b2:SetText(table.concat(parts, colorText("ff5a5348", " · ")))
    end

    r:EnableMouse(true)
    r:SetScript("OnEnter", function(f)
        if GameTooltip then
            GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
            GameTooltip:ClearLines()
            GameTooltip:AddLine("这趟能拿多少（实时）", 0.94, 0.9, 0.8)
            GameTooltip:AddLine(("%d 站 · 合计 %s 金"):format(st, goldStr(gold)), 0.91, 0.75, 0.34)
            GameTooltip:AddLine("金额是任务实发（不含掉落/宝箱）", 0.72, 0.67, 0.55)
            GameTooltip:AddLine("世界任务数取自池快照，特别任务按图计数", 0.72, 0.67, 0.55)
            GameTooltip:Show()
        end
    end)
    r:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    return y + h + 6
end

-- 表格列投影：把 5 列 src 按配置裁成 3~5 列。
--   为什么重排而不是「画了再藏」：DrawTable 按 head 的 w 比例铺满内容宽度，
--   藏掉两列还留权重的话右边会空一大块；重排后剩下列自动铺满。
--   注意 tip/click 拿到的 row 是投影后的行 —— 它们只读 row[1] / row[2]，
--   这两个位置永远是「序」和「任务」，所以不用改回调。
local function projectSpec(spec, L)
    local keep = { 1, 2, 3 }
    if L.table.eta then keep[#keep + 1] = 4 end
    if L.table.coord then keep[#keep + 1] = 5 end

    local head, rows = {}, {}
    for j, idx in ipairs(keep) do
        local src = spec.head and spec.head[idx]
        head[j] = {
            t = tx(L, "th:" .. tostring(idx - 1), (src and src.t) or ""),
            w = (src and src.w) or 100,
            a = (src and src.a) or "l",
        }
    end
    for _, row in ipairs(spec.rows or {}) do
        local nr = { hdr = row.hdr }
        for j, idx in ipairs(keep) do nr[j] = row[idx] end
        rows[#rows + 1] = nr
    end
    return head, rows
end

function RouteWin:Refresh()
    if not (self.frame and self.frame:IsShown()) then return end
    self:Reset()

    local L = lay()
    local width = math.max(120, self.content:GetWidth() or 300)
    local y = 0

    -- 取看板那份路线块的「表」和「说明」—— 不另算一份。
    --   hint 里已经带了站数与池快照时间（"18 站 · 池快照 3 分钟前 …"），
    --   自己再拼一遍必然和看板对不上。
    local spec, hint
    if ns.RouteBlocks then
        local okB, blocks = pcall(ns.RouteBlocks)
        if okB and type(blocks) == "table" then
            for _, b in ipairs(blocks) do
                if b.h and not hint then hint = b.hint end
                if b.table then spec = b.table; break end
            end
        end
    end

    -- 块顺序 / 显隐全部来自配置（summary / total / maps / table）。
    --   某一类数据这次没有（比如池里一个金币任务都没有 → 没有 spec）时，
    --   对应的块直接跳过 —— 空块比少一块更像坏掉了。
    for _, sec in ipairs(L.sections) do
        if sec.on then
            if sec.id == "summary" then
                local sub = hint or "路线取实时池，交任务后自动重算"
                local fs = self:Label("GameFontNormalSmall")
                fs:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -y)
                fs:SetWidth(width)
                fs:SetWordWrap(true)
                fs:SetText(colorText(MUTED, tostring(sub)))
                local hh = 14
                if fs.GetStringHeight then
                    local okH, v = pcall(fs.GetStringHeight, fs)
                    if okH and tonumber(v) then hh = math.max(14, tonumber(v)) end
                end
                y = y + hh + 6

            elseif sec.id == "total" and spec then
                y = drawTotal(self, L, spec.maps or {}, y, width)

            elseif sec.id == "maps" and spec and spec.maps then
                y = drawMapCards(self, L, spec.maps, y, width)

            elseif sec.id == "table" and spec then
                -- 包装点击：原回调照跑（挂追踪 / 打点 / 开地图），之后把自己也重画。
                -- 原回调内部已改走 UI:SafeRefresh()（v0.9.24）—— 主看板没建过也不会炸。
                local s = {}
                for k, v in pairs(spec) do s[k] = v end
                local orig = spec.click
                if orig then
                    s.click = function(row, ri, btn)
                        local okC, err = pcall(orig, row, ri, btn)
                        if not okC then print("|cffff4d4d置顶窗点击出错：|r" .. tostring(err)) end
                        self:Refresh()
                    end
                end
                s.head, s.rows = projectSpec(spec, L)
                y = self:DrawTable(s, y, width) + 8
            end
        end
    end

    -- 一条路线都没有：不管块怎么配，都要说一句，别给一个空窗口
    if not spec then
        local e = self:Label("GameFontNormalSmall")
        e:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -y)
        e:SetWidth(width)
        e:SetWordWrap(true)
        e:SetText(colorText(MUTED, "现在没有可导航的金币世界任务。\n"
            .. "（路线只收「本周没做过 + 有坐标 + 读到奖励 + 达门槛」的世界任务）"))
        y = y + 36
    end

    self.content:SetHeight(math.max(y + 6, 10))
end

-- 把配置里的窗宽重新套上去（/wb layout width）
--   为什么单独一个函数：Reset() 是「回默认位置+默认尺寸」，而这里要的是
--   「丢掉我拖出来的宽度，改回**配置里的**宽度」—— 两件事不一样。
function ns.PinApplyWidth()
    local L = lay()
    local c = cfg("route")
    c.w = nil
    local w = WINS.route
    if w and w.frame then
        local target = math.max(MIN_W, tonumber(L.winW) or w.def.w)
        w.frame:SetSize(target, w.frame:GetHeight())
        saveBox("route", w.frame)
        w:Refresh()
    end
    return tonumber(L.winW)
end

--==========================================================================
-- 布局自检（/wb layout 的输出）
--   用户改完配置最常问的是「到底生效了没有 / 哪条没生效」——
--   这里把「生效的」和「故意的忽略」都摊开，省得靠猜。
--==========================================================================
function ns.PinLayoutInfo()
    local L = lay()
    local out = {}
    local sec = {}
    for _, s in ipairs(L.sections) do
        sec[#sec + 1] = s.id .. (s.on and "" or "（隐藏）")
    end
    out[#out + 1] = "块顺序：" .. table.concat(sec, " → ")
    out[#out + 1] = ("宽度：%s · 每图卡 %d 列 · 排序 %s%s")
        :format(L.winW and (L.winW .. "px") or "跟随窗口", L.maps.cols, L.maps.sort,
                next(L.ov) and (" · 单卡覆盖 " .. tostring(#L.ov) .. " 张") or "")
    local on = {}
    for k, v in pairs(L.total) do if v then on[#on + 1] = k end end
    table.sort(on)
    out[#out + 1] = "总览指标：" .. (#on > 0 and table.concat(on, " / ") or "（全关）")
    out[#out + 1] = ("表格列：序/任务/单次%s%s"):format(
        L.table.eta and " + 剩余" or "", L.table.coord and " + 坐标" or "")
    -- 主窗四格 + 拍卖窗文案（v0.9.38：这两个窗也归工作台管了）
    local msrc = (type(ns.LAYOUT) == "table") and ns.LAYOUT.main or nil
    if type(msrc) == "table" then
        local names = { dragon = "雷龙进度", trip = "这趟任务",
                        take = "这趟能拿", expire = "6小时内过期" }
        local show = {}
        for _, k in ipairs({ "dragon", "trip", "take", "expire" }) do
            local s = msrc.show
            if type(s) ~= "table" or s[k] ~= false then show[#show + 1] = names[k] end
        end
        out[#out + 1] = ("主窗四格（为了雷菌）：%s · %s")
            :format((#show > 0) and table.concat(show, "/") or "（全隐藏）",
                    (msrc.cols == 2) and "2×2" or "4 格一行")
        local g = (type(msrc.dragon) == "table") and tonumber(msrc.dragon.goal) or nil
        if g and g > 0 then
            out[#out + 1] = ("雷龙目标（游戏内没设 /lj goal 时）：%g 万金"):format(g)
        end
    end
    if L.ah.title or L.ah.placeholder or L.ah.hint then
        out[#out + 1] = "拍卖窗文案："
            .. table.concat({ L.ah.title or "", L.ah.placeholder or "", L.ah.hint or "" }, " / ")
    end
    if next(L.txt) then
        local ks = {}
        for k in pairs(L.txt) do ks[#ks + 1] = k end
        table.sort(ks)
        out[#out + 1] = "文案覆盖 " .. tostring(#ks) .. " 条：" .. table.concat(ks, " · ")
    end
    out[#out + 1] = "|cff9a968c忽略项：hint / sa:图名 / eta:图名（含实时数字，固化了就是假账）|r"
    return out
end

--==========================================================================
-- 拍卖行窗
--==========================================================================
local AHWin = setmetatable({}, { __index = UI })

-- 快照里的物品搜索
--   items[itemID] = { u = 单价铜, n = 在售数, nm = 名字 }
--   规则：ID 精确 > 名字精确 > 名字包含；同组内名字短的优先（更像用户想找的），
--        再按单价降序。限制 MAX_HITS 防「输入一个『布』字扫出两千条」。
local MAX_HITS = 400

local function searchItems(q)
    local out = {}
    q = tostring(q or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return out, 0, false end
    if not (ns.AH and ns.AH.db) then return out, 0, false end
    local okD, a = pcall(ns.AH.db)
    if not okD or type(a) ~= "table" or type(a.items) ~= "table" then return out, 0, false end

    local items = a.items
    local qid = q:match("^%d+$") and tonumber(q)
    local lq = q:lower()
    local scanned, truncated = 0, false
    for id, r in pairs(items) do
        scanned = scanned + 1
        if type(r) == "table" then
            local nm = tostring(r.nm or "")
            local hit, exact = false, false
            if qid and tonumber(id) == qid then
                hit, exact = true, true
            elseif nm ~= "" and nm:lower():find(lq, 1, true) then
                hit = true
                exact = (nm == q)
            end
            if hit then
                out[#out + 1] = {
                    id = tonumber(id) or 0,
                    nm = (nm ~= "" and nm) or ("物品 #" .. tostring(id)),
                    u = tonumber(r.u) or 0,
                    n = tonumber(r.n) or 0,
                    exact = exact,
                    short = #nm,
                }
                if #out >= MAX_HITS then truncated = true; break end
            end
        end
    end
    table.sort(out, function(x, y)
        if x.exact ~= y.exact then return x.exact end
        if x.short ~= y.short then return x.short < y.short end
        return x.u > y.u
    end)
    return out, scanned, truncated
end
ns.PinSearchItems = searchItems     -- 测试要单独钉搜索规则

function AHWin:DoSearch(q)
    self.query = tostring(q or "")
    local res, scanned, truncated = searchItems(self.query)
    self.results = res
    self.scanned = scanned
    self.truncated = truncated
    if self.scroll then self.scroll:SetVerticalScroll(0) end
    self:Refresh()
end

function AHWin:Refresh()
    if not (self.frame and self.frame:IsShown()) then return end
    self:Reset()

    local width = math.max(120, self.content:GetWidth() or 300)
    local y = 0
    local res = self.results or {}
    local hasAH = (ns.AH ~= nil)

    -- 状态行：新鲜度永远是第一信息（价格最怕「看起来是新的其实是上周的」）
    local status
    if not hasAH then
        status = "拍卖行模块没加载（Auction.lua），查不了价"
    else
        local count = 0
        local okA, a = pcall(ns.AH.db)
        if okA and type(a) == "table" then count = tonumber(a.itemCount) or 0 end
        local last = (ns.AH.LastScanText and ns.AH.LastScanText()) or "—"
        status = ("上次扫描 %s · 快照 %s 种"):format(tostring(last), tostring(count))
        if self.query and self.query ~= "" then
            status = status .. " · 命中 " .. #res .. " 种"
            if self.truncated then status = status .. "（太多，只列前 " .. MAX_HITS .. "）" end
        end
    end
    local fs = self:Label("GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -y)
    fs:SetWidth(width)
    fs:SetWordWrap(true)
    fs:SetText(colorText(MUTED, status))
    y = y + 18

    if not hasAH then
        self.content:SetHeight(math.max(y + 6, 10))
        return
    end

    local q = tostring(self.query or "")
    if q == "" then
        local guide = (lay().ah.hint)
            or "输入物品名（中文/英文都行）或物品 ID，按回车查询。\n"
                .. "价格来自拍卖行浏览扫描：打开拍卖行会自动扫一次，也可以 /wb ah scan。"
        local e = self:Label("GameFontNormalSmall")
        e:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -y)
        e:SetWidth(width)
        e:SetWordWrap(true)
        e:SetText(colorText(MUTED, guide))
        y = y + 38
    elseif #res == 0 then
        local e = self:Label("GameFontNormalSmall")
        e:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -y)
        e:SetWidth(width)
        e:SetWordWrap(true)
        e:SetText(colorText(WARN, "快照里没有匹配「" .. q .. "」的物品。\n")
            .. colorText(MUTED, "可能现在没人卖，也可能还没扫到 —— 去拍卖行开一次再点刷新。"))
        y = y + 38
    else
        local rows = {}
        for _, it in ipairs(res) do
            local unit = it.u
            local col = MUTED
            if unit >= 100000 then col = GOLD_DIM end       -- 单价 10 万金以上
            rows[#rows + 1] = {
                -- id 藏在格子上：行是复用池，tip / click 靠 ri 反查又慢又不可靠
                -- （文字可能被 fitText 截断），直接在格里带 id 最稳。
                { t = it.nm, c = TEXT, id = it.id },
                { t = goldStr(unit), c = col, id = it.id },
                { t = tostring(it.n), c = (it.n <= 2) and WARN or TEXT2, id = it.id },
                { t = goldStr(unit * math.max(0, it.n)), c = TEXT2, id = it.id },
            }
        end
        local self2 = self
        local spec = {
            head = { { t = "物品", w = 300, a = "l" }, { t = "一口价(金)", w = 110, a = "r" },
                     { t = "在售", w = 70, a = "r" }, { t = "货值(金)", w = 110, a = "r" } },
            rows = rows,
            tip = function(row)
                local id = row[1] and row[1].id
                local it
                for _, r in ipairs(res) do if r.id == id then it = r; break end end
                local lines = {}
                if GameTooltip and id then
                    -- 先铺物品本体（图标/名称/等级），再追加价格行。
                    --   DrawTable 在调用 tip **之前**已经 ClearLines + SetOwner，
                    --   这里填的物品内容会被保留，返回的行追加在它下面。
                    pcall(GameTooltip.SetItemByID, GameTooltip, id)
                end
                if it then
                    lines[#lines + 1] = { t = ("最低一口价 %s 金 · 在售 %d 个"):format(goldStr(it.u), it.n) }
                    lines[#lines + 1] = { t = ("总货值 %s 金"):format(goldStr(it.u * it.n)),
                                          r = 0.72, g = 0.67, b = 0.55 }
                end
                lines[#lines + 1] = { t = "左键把物品 ID 填进查询框", r = 0.6, g = 0.56, b = 0.46 }
                return lines
            end,
            click = function(row, _, button)
                if button ~= "LeftButton" then return end
                local id = row[1] and row[1].id
                local eb = self2.edit
                if id and eb then
                    eb:SetText(tostring(id))
                    eb:SetFocus()
                    eb:HighlightText()
                end
            end,
        }
        y = self:DrawTable(spec, y, width) + 8
    end

    self.content:SetHeight(math.max(y + 6, 10))
end

--==========================================================================
-- 拍卖窗：搜索行（固定在标题栏下，不随内容滚动）
--==========================================================================
local function buildAHExtra(inst)
    local f = inst.frame
    local holder = CreateFrame("Frame", nil, f)
    holder:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(BAR_H + 6))
    holder:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(PAD + 12), -(BAR_H + 6))
    holder:SetHeight(24)
    box(holder, 1, 1, 1, 0.05):SetAllPoints()

    local eb = CreateFrame("EditBox", "ForLeiJunPinAHEdit", holder)
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
        inst:DoSearch(q)
    end)
    inst.edit = eb

    local ph = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ph:SetPoint("LEFT", holder, "LEFT", 8, 0)
    ph:SetText(colorText("ff8a7f66",
        (lay().ah.placeholder or "物品名或 ID，回车查询")))
    eb:SetScript("OnEditFocusGained", function() ph:Hide() end)
    eb:SetScript("OnEditFocusLost", function()
        if (eb:GetText() or "") == "" then ph:Show() else ph:Hide() end
    end)
    inst.placeholder = ph

    local go = CreateFrame("Button", nil, holder)
    go:SetSize(56, 20)
    go:SetPoint("RIGHT", holder, "RIGHT", -4, 0)
    local gt = go:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gt:SetPoint("CENTER")
    gt:SetText(colorText(GOLD, "查询"))
    go:SetScript("OnEnter", function() gt:SetText(colorText(GOLD, "查询")) end)
    go:SetScript("OnLeave", function() gt:SetText(colorText(GOLD, "查询")) end)
    go:SetScript("OnClick", function()
        local q = eb:GetText() or ""
        eb:ClearFocus()
        inst:DoSearch(q)
    end)

    -- 内容区从搜索行下方开始（buildShell 里建的那条 scroll 要重锚）
    inst.contentTop = BAR_H + 6 + 24 + 6
    inst.scroll:ClearAllPoints()
    inst.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -inst.contentTop)
    inst.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(PAD + 12), PAD + 4)
end

--==========================================================================
-- 生命周期
--==========================================================================
local CLASS = { route = RouteWin, ah = AHWin }

function Pin:Win(key)
    local w = WINS[key]
    if w then return w end
    local def = DEFS[key]
    if not def then return nil end

    local inst = setmetatable({ key = key, def = def }, { __index = CLASS[key] })
    buildShell(inst, def, key)
    if key == "ah" then buildAHExtra(inst) end
    WINS[key] = inst
    return inst
end

function Pin:Show(key)
    if not key then
        for k in pairs(DEFS) do self:Show(k) end
        return
    end
    local w = self:Win(key)
    if w then
        saveKeep(key, true)     -- 要它在 → 记成意图（重载/换角色都照此恢复）
        w.frame:Show()
    end
end

function Pin:Hide(key)
    if not key then return self:HideAll() end
    local w = WINS[key]
    if w and w.frame then
        -- 只有这里（× 按钮 / /wb pin off / Toggle）算「用户手动关」。
        -- 别处顺手 Hide 的一律不算。
        saveKeep(key, false)
        w.frame:Hide()
    end
end

function Pin:HideAll()
    for key in pairs(DEFS) do
        local w = WINS[key]
        if w and w.frame then
            saveKeep(key, false)
            w.frame:Hide()
        end
    end
end

function Pin:IsShown(key)
    local w = WINS[key]
    return (w and w.frame and w.frame:IsShown()) or false
end

-- 回到默认位置与尺寸（v0.9.26）
--   窗口被拖到奇怪的地方、换了显示器/分辨率后「找不回来」时用。
--   它只重置位置尺寸，不动 keep —— 重置完照样按「该在就一直在」处理。
function Pin:Reset(key)
    local keys = {}
    if key then keys[1] = key else for k in pairs(DEFS) do keys[#keys + 1] = k end end
    for _, k in ipairs(keys) do
        local def = DEFS[k]
        if def then
            local c = cfg(k)
            c.left, c.top, c.w, c.h = nil, nil, nil, nil
            local w = WINS[k]
            if w and w.frame then
                local p = def.point
                w.frame:ClearAllPoints()
                w.frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
                w.frame:SetSize(def.w, def.h)
            else
                self:Win(k)          -- 还没建过：建的时候读的就是上面清空后的默认值
            end
        end
    end
end

function Pin:Toggle(key)
    if key then
        local w = self:Win(key)
        if not w then return end
        if w.frame:IsShown() then
            self:Hide(key)
        else
            self:Show(key)
        end
        return
    end
    -- 无参：任一开着一律全关，否则全开。
    --   （不做「把开的关掉、把没开的打开」那种半开半关 —— 用户根本猜不到结果）
    local any = false
    for k in pairs(DEFS) do
        if self:IsShown(k) then any = true end
    end
    if any then self:HideAll() else self:Show() end
end

-- 回到世界（登录 / 换角色 / 进出副本 / /reload）后，把「用户要它」的窗拿出来。
--   v0.9.26：判据从「上次那一刻显示着没有」改成 keep（意图）。
--   只挂 PLAYER_LOGIN 不够：切角色不重登，那个事件不再触发。
function Pin:Restore()
    Pin._ready = true
    for key in pairs(DEFS) do
        if wantShown(key) then
            local ok, err = pcall(self.Show, self, key)
            if not ok then
                print("|cffff4d4d置顶小窗恢复失败：|r" .. tostring(err))
            end
        end
    end
end

-- 保活对账（v0.9.26）
--   用户的要求只有一句：「只要角色在线就一直在，除非我手动关」。
--   与其一条条追「这次又是谁把它藏了」，不如每秒对一次账：
--     · 该在却没显示     → 补显示（给 2 秒宽限，别和刚发生的关闭抢同一帧）
--     · 显示着但整块在屏幕外 → 拉回默认位置，并纠正存档
--   keep=false（用户手动关过）的一律不碰。
local KEEP_ERR = {}
local function keepAlive()
    if not Pin._ready then return end
    if IsInWorld and not IsInWorld() then return end
    local t = (GetTime and GetTime()) or 0
    for key in pairs(DEFS) do
        if wantShown(key) then
            local w = WINS[key]
            local f = w and w.frame
            local need = false
            if not f then
                need = true
            elseif not f:IsShown() then
                need = (not w._hiddenAt) or (t - w._hiddenAt) >= 2
            elseif not onScreen(f:GetLeft(), f:GetTop(), f:GetWidth(), f:GetHeight()) then
                -- 画在屏幕外（换分辨率 / 拖出界）→ 拉回默认位
                f:ClearAllPoints()
                local p = w.def.point
                f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
                saveBox(key, f)
            end
            if need then
                -- ⚠ 这里是普通函数，没有 self —— 写 self.Show 会直接抛
                -- 「attempt to index nil」，而它被外层 pcall 吃掉，表现为
                -- 「保活逻辑完全不生效」却一条报错都看不到（本轮踩过）。
                local ok, err = pcall(Pin.Show, Pin, key)
                if not ok and KEEP_ERR[key] ~= tostring(err) then
                    KEEP_ERR[key] = tostring(err)
                    print("|cffff4d4d置顶窗补显示失败：|r" .. tostring(err))
                end
            end
        end
    end
end

--==========================================================================
-- 自动刷新
--   路线：每 20 秒（剩余时间会走、池会被后台重扫）
--   拍卖：快照的 lastScanTs 一变就刷（扫描完成的那一刻价格才新）
--==========================================================================
-- 起个名字：无头测试要能拿到它的 OnUpdate 才能验「保活对账」
local ticker = CreateFrame("Frame", "ForLeiJunPinTicker")
ticker:SetScript("OnUpdate", function(_, elapsed)
    ticker._acc = (ticker._acc or 0) + (elapsed or 0)
    if ticker._acc < 1 then return end
    ticker._acc = 0
    local now = time()

    -- 先对账（该在不在就补回来），再谈重画
    pcall(keepAlive)

    local r = WINS.route
    if r and r.frame and r.frame:IsShown() then
        if not r._nextTick or now >= r._nextTick then
            r._nextTick = now + 20
            -- 自动重画包一层 pcall：重画失败不该让窗口看起来「坏了/空了」，
            -- 也不该每 20 秒往聊天框刷一次同样的错。同一个错只报一次。
            local okR, errR = pcall(r.Refresh, r)
            if not okR and r._err ~= tostring(errR) then
                r._err = tostring(errR)
                print("|cffff4d4d置顶窗重画出错：|r" .. tostring(errR))
            end
        end
    end

    local a = WINS.ah
    if a and a.frame and a.frame:IsShown() then
        local st = 0
        if ns.AH and ns.AH.db then
            local ok, d = pcall(ns.AH.db)
            if ok and type(d) == "table" then st = tonumber(d.lastScanTs) or 0 end
        end
        if st ~= a._scanTs then
            a._scanTs = st
            a:Refresh()
        end
    end
end)

-- 交任务 / 做完世界任务 → 路线立刻重算（与看板同一个事件、同一个延迟理由：
-- 等任务日志落定再读，否则读到的是交之前的日志）
local ev = CreateFrame("Frame")
ev:RegisterEvent("QUEST_TURNED_IN")
ev:SetScript("OnEvent", function()
    local r = WINS.route
    if not (r and r.frame and r.frame:IsShown()) then return end
    if C_Timer and C_Timer.After then
        C_Timer.After(0.3, function()
            if r.frame and r.frame:IsShown() then r:Refresh() end
        end)
    end
end)

-- 恢复时机：PLAYER_LOGIN（登录）+ PLAYER_ENTERING_WORLD（换角色 / 进出副本）
--   只挂登录的话，同一会话里换个小号，窗口就不会再出现（PLAYER_LOGIN 不重发）。
--   进副本也发一次，正好顺手把被货栈/过场弄丢的窗补回来。
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then self:UnregisterEvent("PLAYER_LOGIN") end
    local ok, err = pcall(Pin.Restore, Pin)
    if not ok then print("|cffff4d4d置顶小窗恢复失败：|r" .. tostring(err)) end
end)

-- 自诊断标记（见 Core.lua 的说明：缺这一行 = 本文件加载期挂了）
if ns._mark then ns._mark("Pin.lua") end
