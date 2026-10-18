--[[--------------------------------------------------------------------------
    ForLeiJun / Render.lua
    表格与卡片渲染原语 + 控件池。**Lite 版自带一套，不依赖 DashboardUI.lua。**

    为什么要单独一份（而不是共用 full 版的 DashboardUI）
      对外第一版只要两页（世界任务路线 / 拍卖搜索），而 DashboardUI.lua 有
      1900 行，其中绝大部分是「总览 / 角色 / 金币 / 市场」四个吃 build.py
      快照的页签。把这些代码随发布包一起带出去有两个坏处：
        ① 玩家能通过 /wb board gold 之类摸到半成品页面（快照是作者的账号数据）；
        ② 以后改 full 版页签时，lite 的发布行为会跟着变 —— 对外版本必须**冻结**。
      所以 lite 只带走真正需要的原语（约 400 行），行为与 full 版一致
      （同一套列宽/截断/行池逻辑，视觉上用同一套配色），但互不影响。

    刻意保留的坑位修复（照抄 full 版，别"优化"掉）
      * 行是普通 Frame，点击必须用 OnMouseUp —— OnClick 是 Button 专有，
        写上去会抛错并打断整页渲染（症状：窗口能开、里面空的）。
      * 行复用前必须 pairs 清空 cells（稀疏数组，ipairs 遇 nil 就停）。
      * 列宽按 w 比例分配，最后一列吃掉取整误差。
      * 文本先 SetText 再量宽度，超宽二分截断（FontString 不会自己裁）。
--------------------------------------------------------------------------]]

local ADDON, ns = ...

local UI = {}
ns.Board = UI            -- 置顶窗（Pin.lua）借这套方法当第二个渲染宿主

local R = {}
ns.Render = R

--==========================================================================
-- 配色（与 full 版同一套，已过视觉验收；改这里会同时改到置顶窗）
--==========================================================================
local GOLD, GOLD_DIM = "fff2c94e", "ffc08a3e"
local GOLD_BR         = "fff7d97e"
local TEXT, TEXT2, MUTED = "fff0e6cc", "ffdccfae", "ffb8ab8c"
local GOOD, WARN, BAD = "ff8cc63f", "ffe9c058", "ffe06a50"

R.GOLD, R.GOLD_DIM, R.GOLD_BR = GOLD, GOLD_DIM, GOLD_BR
R.TEXT, R.TEXT2, R.MUTED = TEXT, TEXT2, MUTED
R.GOOD, R.WARN, R.BAD = GOOD, WARN, BAD

local PAD = 16
local ROW_H = 20

R.PAD, R.ROW_H = PAD, ROW_H

local BG      = { 0.055, 0.045, 0.035, 0.96 }
local PANEL   = { 0.100, 0.082, 0.062, 0.85 }
local CELL_BG = { 1, 1, 1, 0.035 }
local EDGE    = { 0.42, 0.33, 0.17, 1 }

R.BG, R.PANEL, R.EDGE = BG, PANEL, EDGE

--==========================================================================
-- 格式化
--==========================================================================
local function num(v)
    return tonumber(v) or 0
end
R.num = num

-- 铜 → 金：>=1亿金用「亿」，>=1万金用「万」，否则整数
local function goldStr(copper)
    local g = num(copper) / 10000
    local a = math.abs(g)
    if a >= 1e8 then return string.format("%.2f亿", g / 1e8) end
    if a >= 1e4 then return string.format("%.1f万", g / 1e4) end
    return string.format("%d", math.floor(g + 0.5))
end
R.goldStr = goldStr

local function colorText(code, s)
    if not code or code == "" then return tostring(s) end
    return "|c" .. code .. tostring(s) .. "|r"
end
R.colorText = colorText

--==========================================================================
-- 列宽保护：超宽文本按像素截断
--   FontString 在 SetWordWrap(false) 之后不会裁剪，超宽直接盖到隔壁列。
--   按 UTF-8 字符切（不能按字节切，会拦腰砍断中文）。
--==========================================================================
local ELLIPSIS = "…"

local function utf8chars(s)
    local t, i = {}, 1
    while i <= #s do
        local b = s:byte(i)
        local n = 1
        if b >= 0xF0 then n = 4 elseif b >= 0xE0 then n = 3
        elseif b >= 0xC0 then n = 2 end
        t[#t + 1] = s:sub(i, i + n - 1)
        i = i + n
    end
    return t
end

-- 拆成 { cc = 颜色, chars = 字符数组 } 片段；颜色可嵌套（栈维护）
local function parseColored(s)
    s = tostring(s)
    local segs, buf, stack = {}, {}, {}
    local function flush()
        if #buf > 0 then
            segs[#segs + 1] = { cc = stack[#stack], chars = utf8chars(table.concat(buf)) }
            buf = {}
        end
    end
    local i = 1
    while i <= #s do
        local two = s:sub(i, i + 1)
        if two == "|c" then
            flush(); stack[#stack + 1] = s:sub(i + 2, i + 9); i = i + 10
        elseif two == "|r" then
            flush(); stack[#stack] = nil; i = i + 2
        else
            buf[#buf + 1] = s:sub(i, i)
            i = i + 1
        end
    end
    flush()
    return segs
end

local function buildFit(segs, k)
    local out, used, lastCC = {}, 0, nil
    for _, sg in ipairs(segs) do
        if used >= k then break end
        local take = math.min(#sg.chars, k - used)
        if sg.cc then out[#out + 1] = "|c" .. sg.cc; lastCC = sg.cc end
        for j = 1, take do out[#out + 1] = sg.chars[j] end
        used = used + take
    end
    out[#out + 1] = ELLIPSIS
    if lastCC then out[#out + 1] = "|r" end
    return table.concat(out)
end

-- 必须先 SetText 再量（GetStringWidth 量的是当前文本）
local function fitText(fs, text, maxW)
    fs:SetText(text)
    if fs:GetStringWidth() <= maxW then return text end
    local segs = parseColored(text)
    local total = 0
    for _, sg in ipairs(segs) do total = total + #sg.chars end
    local lo, hi, best = 1, total, 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        fs:SetText(buildFit(segs, mid))
        if fs:GetStringWidth() <= maxW then best = mid; lo = mid + 1
        else hi = mid - 1 end
    end
    if best <= 0 then fs:SetText(""); return "" end
    local s = buildFit(segs, best)
    fs:SetText(s)
    return s
end
R.fitText = fitText

-- 手画一块纯色纹理（不用 Backdrop 模板，那套模板名各版本改过）
local function box(parent, r, g, b, a)
    local t = parent:CreateTexture(nil, "BACKGROUND")
    t:SetColorTexture(r, g, b, a)
    return t
end
R.box = box

--==========================================================================
-- 控件池
--==========================================================================
-- 行记住自己的宿主：滚轮要转交给**本窗**的滚动框。
--   full 版曾硬编码 UI.scroll，导致置顶窗里的行把滚轮转给主看板。
local function NewRow(parent, owner)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(ROW_H)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    -- ★ 组头顶部粗线（与自用版同款）：行内 2px texture，只在组头行 Show
    r.top = r:CreateTexture(nil, "BORDER")
    r.top:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
    r.top:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, 0)
    r.top:SetHeight(2)
    r.top:Hide()
    r.cells = {}
    r:EnableMouse(true)
    r:SetScript("OnMouseWheel", function(_, delta)
        local sc = owner and owner.scroll
        if sc and sc:IsShown() then
            local h = sc:GetScript("OnMouseWheel")
            if h then h(sc, delta) end
        end
    end)
    return r
end

function UI:Row()
    self.nRow = self.nRow + 1
    local r = self.rows[self.nRow]
    if not r then
        r = NewRow(self.content, self)
        self.rows[self.nRow] = r
    end
    r:Show()
    r:ClearAllPoints()
    r:SetHeight(ROW_H)
    -- 复用前清脚本：否则点空白处会触发上一屏那一行的动作（"插件乱跳"）
    r:SetScript("OnMouseUp", nil)
    r:SetScript("OnEnter", nil)
    r:SetScript("OnLeave", nil)
    -- cells 是稀疏数组，必须 pairs
    for _, c in pairs(r.cells) do c:Hide() end
    if r._bar then r._bar:Hide(); r._bar = nil end
    -- 上一屏可能是组头行（有顶部粗线）：复用前必须藏掉
    if r.top then r.top:Hide() end
    return r
end

function UI:Cell(row, idx)
    local c = row.cells[idx]
    if not c then
        c = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c:SetWordWrap(false)
        row.cells[idx] = c
    end
    c:Show()
    return c
end

function UI:Label(size)
    self.nLabel = self.nLabel + 1
    local fs = self.labels[self.nLabel]
    if not fs then
        fs = self.content:CreateFontString(nil, "OVERLAY", size or "GameFontNormal")
        self.labels[self.nLabel] = fs
        fs._size = size or "GameFontNormal"
    end
    -- 同一 FontString 不能改模板，字号档位变了只能另建
    if size and fs._size ~= size then
        fs:Hide()
        fs = self.content:CreateFontString(nil, "OVERLAY", size)
        fs._size = size
        self.labels[self.nLabel] = fs
    end
    fs:Show()
    fs:ClearAllPoints()
    fs:SetJustifyH("LEFT")
    return fs
end

function UI:Bar(parent, width, height)
    self.nBar = self.nBar + 1
    local holder = self.bars[self.nBar]
    if not holder then
        holder = CreateFrame("Frame", nil, parent)
        holder.track = holder:CreateTexture(nil, "BACKGROUND")
        holder.track:SetAllPoints()
        holder.track:SetColorTexture(1, 1, 1, 0.10)
        holder.fill = holder:CreateTexture(nil, "ARTWORK")
        holder.fill:SetPoint("TOPLEFT")
        holder.fill:SetPoint("BOTTOMLEFT")
        holder.fill:SetColorTexture(0.91, 0.75, 0.34, 1)
        self.bars[self.nBar] = holder
    end
    holder:SetParent(parent)
    holder:Show()
    holder:SetWidth(width)
    holder:SetHeight(height or 6)
    holder._w = width
    return holder
end

function UI:Reset()
    local i
    for i = 1, self.nRow do self.rows[i]:Hide() end
    for i = 1, self.nLabel do self.labels[i]:Hide() end
    for i = 1, self.nBar do self.bars[i]:Hide() end
    self.nRow, self.nLabel, self.nBar = 0, 0, 0
end

--==========================================================================
-- 绘制原语
--==========================================================================
local function setBar(holder, pct)
    pct = math.max(0, math.min(100, num(pct)))
    holder.fill:SetWidth(math.max(1, holder._w * pct / 100))
    if pct >= 100 then holder.fill:SetColorTexture(0.55, 0.78, 0.25, 1)
    else holder.fill:SetColorTexture(0.91, 0.75, 0.34, 1) end
end

-- 列宽按比例铺满（最后一列吃掉取整误差）
local function widthsOf(head, total)
    local sum = 0
    for _, c in ipairs(head) do sum = sum + num(c.w) end
    if sum <= 0 then return {} end
    local out, acc = {}, 0
    for i, c in ipairs(head) do
        local w = math.floor(num(c.w) / sum * total)
        if i == #head then w = total - acc else acc = acc + w end
        out[i] = w
    end
    return out
end

-- spec = { head = {{t,w,a}}, rows = {{ {t,c}, ... }}, click = fn(row,ri), tip = fn(row) }
function UI:DrawTable(spec, y, width)
    local head = spec.head or {}
    local ws = widthsOf(head, width)
    local x0 = 0
    local i

    -- 表头
    local hr = self:Row()
    hr:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -y)
    hr:SetWidth(width)
    hr.bg:SetColorTexture(1, 1, 1, 0.055)
    for i = 1, #head do
        local c = self:Cell(hr, i)
        c:SetFontObject("GameFontNormalSmall")
        fitText(c, colorText(GOLD_DIM, head[i].t), ws[i] - 12)
        c:SetWidth(ws[i] - 12)
        c:SetJustifyH(head[i].a == "r" and "RIGHT" or "LEFT")
        c:SetPoint("TOPLEFT", hr, "TOPLEFT", x0 + 8, -4)
        x0 = x0 + ws[i]
    end
    y = y + ROW_H

    for ri, row in ipairs(spec.rows or {}) do
        local r = self:Row()
        r:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -y)
        r:SetWidth(width)
        local odd = (ri % 2 == 1)
        local function baseBg()
            if row.hdr then
                -- ★ 组头行淡金底 + 顶部粗线（按地图分框，与自用版同款）
                r.bg:SetColorTexture(0.91, 0.75, 0.34, 0.10)
            elseif odd then r.bg:SetColorTexture(CELL_BG[1], CELL_BG[2], CELL_BG[3], CELL_BG[4])
            else r.bg:SetColorTexture(1, 1, 1, 0.012) end
        end
        baseBg()
        r.bg:Show()
        -- 组头顶粗线（GOLD_DIM）：画在行上边缘，把相邻两组隔开
        if row.hdr and r.top then
            r.top:SetColorTexture(0.75, 0.54, 0.24, 0.55)
            r.top:Show()
        end

        local clickable = (spec.click ~= nil)
        if clickable then r:EnableMouse(true) end

        if spec.tip or clickable then
            r:SetScript("OnEnter", function(f)
                if spec.tip and GameTooltip then
                    GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
                    GameTooltip:ClearLines()
                    for _, line in ipairs(spec.tip(row) or {}) do
                        GameTooltip:AddLine(line.t, line.r or 1, line.g or 0.82, line.b or 0.51)
                    end
                    GameTooltip:Show()
                end
                if clickable then r.bg:SetColorTexture(1, 0.82, 0.31, 0.12) end
            end)
            r:SetScript("OnLeave", function()
                if GameTooltip then GameTooltip:Hide() end
                if clickable then baseBg() end
            end)
        else
            r:SetScript("OnEnter", nil)
            r:SetScript("OnLeave", nil)
        end

        if clickable then
            -- OnMouseUp，不是 OnClick（行是普通 Frame，没有 OnClick）
            r:SetScript("OnMouseUp", function(_, button)
                spec.click(row, ri, button)
            end)
        else
            r:SetScript("OnMouseUp", nil)
        end

        x0 = 0
        for i = 1, #head do
            local cell = row[i]
            local txt, col = "", nil
            if type(cell) == "table" then txt, col = cell.t, cell.c else txt = cell end
            if txt ~= nil and txt ~= "" then
                local c = self:Cell(r, i)
                c:SetFontObject("GameFontHighlightSmall")
                fitText(c, col and colorText(col, txt) or tostring(txt), ws[i] - 12)
                c:SetWidth(ws[i] - 12)
                c:SetJustifyH(head[i].a == "r" and "RIGHT" or "LEFT")
                c:SetPoint("TOPLEFT", r, "TOPLEFT", x0 + 8, -4)
            end
            x0 = x0 + ws[i]
        end
        y = y + ROW_H
    end
    return y
end

-- 一排数字格；卡高固定 68，有无进度条占同样位置（翻页视线不跳）
function UI:DrawGrid(cards, y, width)
    local n = #cards
    if n == 0 then return y end
    local cw = math.floor((width - (n - 1) * 10) / n)
    -- 明细行（card.lines）：整格取最高的卡，四张同高
    local maxLines = 0
    for _, c in ipairs(cards) do
        local ln = (type(c.lines) == "table") and #c.lines or 0
        if ln > maxLines then maxLines = ln end
    end
    local h = (maxLines > 0) and (46 + maxLines * 14 + 6) or 68
    local x = 0
    for _, card in ipairs(cards) do
        local f = self:Row()
        f:SetPoint("TOPLEFT", self.content, "TOPLEFT", x, -y)
        f:SetWidth(cw)
        f:SetHeight(h)
        f.bg:SetColorTexture(PANEL[1], PANEL[2], PANEL[3], 0.9)
        f.bg:Show()
        if card.tkey and self.CardToggle then
            -- 可交互卡（v1.4.2）：点一下收起/展开明细，hover 提亮提示可点。
            --   只有调用方给了 tkey 才生效（full 版四格没有 tkey，行为不变）。
            f:SetScript("OnMouseUp", function() self:CardToggle(card.tkey) end)
            f:SetScript("OnEnter", function()
                f.bg:SetColorTexture(PANEL[1], PANEL[2], PANEL[3], 1)
            end)
            f:SetScript("OnLeave", function()
                f.bg:SetColorTexture(PANEL[1], PANEL[2], PANEL[3], 0.9)
            end)
        else
            f:SetScript("OnEnter", nil)
            f:SetScript("OnLeave", nil)
        end

        local lb = self:Label("GameFontNormalSmall")
        -- ★ 必须挂到卡片框 f 上：字原先挂在 content 上，会被卡片自己的底色
        --   （子框永远画在父级文字之上）罩一层 90% 深棕 —— 真机表现就是
        --   「颜色多亮都发暗」（2026-10-17 真机反馈，颜色提亮治标不治本）
        lb:SetParent(f)
        fitText(lb, colorText(TEXT2, card.l), cw - 20)
        lb:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -8)

        local vl = self:Label("GameFontNormalLarge")
        vl:SetParent(f)
        -- 大数必须可读：暗态（MUTED = 0 值/无数据）也提到 TEXT，与 full 版同款
        local vc = card.vc or GOLD_BR
        if vc == MUTED then vc = TEXT end
        fitText(vl, colorText(vc, card.v), cw - 20)
        vl:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -24)

        if maxLines > 0 then
            -- 明细模式：有 lines 的卡画明细；没有的卡把 subtitle 摆进第一行位，
            -- 否则同格其它卡有明细时，雷龙进度的「还差 X 金」这类副标题会整行消失
            local lines = (type(card.lines) == "table") and card.lines or {}
            if #lines == 0 and card.s and card.s ~= "" then
                lines = { { t = card.s, c = TEXT2 } }
            end
            local ly = -46
            for i = 1, maxLines do
                local ln = lines[i]
                if ln then
                    local fs = self:Label("GameFontNormalSmall")
                    fs:SetParent(f)
                    fitText(fs, colorText(ln.c or TEXT2, ln.t), cw - 20)
                    fs:SetPoint("TOPLEFT", f, "TOPLEFT", 10, ly)
                end
                ly = ly - 14
            end
        else
            local ss = self:Label("GameFontNormalSmall")
            ss:SetParent(f)
            fitText(ss, colorText(TEXT2, card.s or ""), cw - 20)
            ss:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -46)
        end

        if card.p ~= nil then
            local bar = self:Bar(f, cw - 20, 5)
            -- 贴卡片底：明细行把卡片撑高后，进度条仍贴底不悬空
            -- （原 TOPLEFT -58 在 68 高时距底 5px，等价换算，旧观感不变）
            bar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 5)
            setBar(bar, card.p)
            f._bar = bar
        end
        x = x + cw + 10
    end
    return y + h + 14
end

function UI:DrawHead(text, hint, y, width)
    local fs = self:Label("GameFontNormal")
    fs:SetText(colorText(GOLD, text))
    fs:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -y)
    if hint and hint ~= "" then
        local hs = self:Label("GameFontNormalSmall")
        hs:SetText(colorText(MUTED, hint))
        hs:SetPoint("LEFT", fs, "RIGHT", 10, 0)
    end
    return y + 26
end

function UI:DrawNote(text, y)
    local fs = self:Label("GameFontNormalSmall")
    fs:SetText(colorText(MUTED, text))
    fs:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -y)
    return y + 18
end

-- 整页重建的安全包装：置顶窗复用这套方法时，主窗口可能从没建过
function UI:SafeRefresh()
    if self.content and self.frame and self.frame:IsShown() then
        local ok, err = pcall(self.Refresh, self)
        if not ok then print("|cffff4d4d为了雷菌 刷新出错：|r" .. tostring(err)) end
    end
end

if ns._mark then ns._mark("Render.lua") end
