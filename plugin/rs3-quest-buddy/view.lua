-- Draws the panel from a list of row descriptions, styled after the Alt1
-- app: dark rows, gold headings, a progress bar, step cards with a gold
-- border on the current step.
--
-- Two things keep it reliable across hours of play:
--   * Render is skipped when the rows haven't changed (View.Signature).
--   * Component IDs are assigned explicitly from two alternating ranges.
--     Every dynamic component under one static parent needs a unique ID
--     (max 4096); left to auto-increment, frequent redraws ran out and the
--     panel went blank.

local Diag = require("diag")

local View = {}

local FONT = id.Font.MUSEO_SANS_15PT_REGULAR
local LINE_HEIGHT = 18
-- Average width of one character in this font, measured from where lines
-- wrap in game: a 344-unit text fits 48 characters but not 50, so 7.02
-- to 7.17. Too high reserves empty lines under every paragraph; too low
-- cuts text off.
local UNITS_PER_CHAR = 7.1
local contentWidth = 400          -- the panel body's width, set by View.Render
local STEP_INDENT = 16            -- per indent level inside a step
local ID_RANGE = 2000

-- The Alt1 app's palette (style.css :root).
View.colour = {
    text = "e8e2d0", muted = "a89f88", gold = "e7c15a", green = "7fbf4d",
    red = "c0564a", chat = "6fa8dc", panel = "262c26", panel2 = "2f372f", border = "4a5a3a",
}

local function vec(hex, alpha)
    local r, g, b = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
    return Vector4.new(r / 255, g / 255, b / 255, alpha or 1.0)
end
View.Vec = vec

-- "<col=...>" wrapper for inline colour inside text.
function View.Col(name, text)
    return "<col=" .. (View.colour[name] or name) .. ">" .. text .. "</col>"
end

-- Labels and text must not contain a bare "<" that isn't a tag.
function View.Escape(text)
    return (tostring(text):gsub("<", "("):gsub(">", ")"))
end

-- Characters that fit on one line of a text `width` units wide.
function View.CharsFor(width)
    return math.max(10, math.floor(width / UNITS_PER_CHAR))
end

-- Lines `content` takes when word-wrapped at `charsPerLine`. Wrapping at
-- word boundaries leaves lines short, so counting characters alone came out
-- too low and long steps were cut off.
function View.LineCount(content, charsPerLine)
    local lines = 0
    for part in (content .. "<br>"):gmatch("(.-)<br>") do
        local plain = part:gsub("<[^>]*>", "")
        local count, used = 1, 0
        for word in plain:gmatch("%S+") do
            local length = #word
            if used == 0 then
                used = length
            elseif used + 1 + length <= charsPerLine then
                used = used + 1 + length
            else
                count, used = count + 1, length
            end
            while used > charsPerLine do count, used = count + 1, used - charsPerLine end
        end
        lines = lines + count
    end
    return lines
end

-- Lines as the game itself would wrap them, when the API offers the font's
-- measuring call (config.Font:GetStringHeightAndLineCount); nil otherwise,
-- or when the answer looks wrong, and the estimate above is used.
local measureState = nil -- "api" or "estimate", noted once in diagnostics
local function measuredLines(content, width)
    if width == nil or width <= 0 then return nil end
    local ok, lines = pcall(function()
        local font = config.Font.MUSEO_SANS_15PT_REGULAR
        local _, count = font:GetStringHeightAndLineCount(content, width)
        return count
    end)
    if not ok or type(lines) ~= "number" or lines < 1 or lines > 60 then
        if measureState == nil then
            measureState = "estimate"
            Diag.Snapshot("textMeasure", measureState)
        end
        return nil
    end
    if measureState ~= "api" then
        measureState = "api"
        Diag.Snapshot("textMeasure", measureState)
    end
    return math.floor(lines)
end

-- `width` (interface units) lets the game measure the text itself.
function View.TextHeight(content, charsPerLine, width)
    local lines = measuredLines(content, width) or View.LineCount(content, charsPerLine)
    return lines * LINE_HEIGHT + 4
end

-- ---------- ids ----------

local rangeStart, nextID = 1, 0
local function newID()
    nextID = nextID + 1
    if nextID >= ID_RANGE then error("panel needs more than " .. ID_RANGE .. " components") end
    return rangeStart + nextID
end
local function make(kind, parent)
    return kind.new(parent, 0, newID())
end

-- ---------- press handling ----------

-- Row clicks are caught twice on purpose (invisible button + background),
-- in case one of them doesn't receive clicks; this keeps it to one action.
local tick, lastPressTick = 0, -1
function View.Tick() tick = tick + 1 end
local function press(fn)
    return function(...)
        if lastPressTick == tick then return end
        lastPressTick = tick
        Diag.Guard("button", fn, ...)
    end
end

-- ---------- building blocks ----------

local function text(parent, content, colour, x, y, w, h)
    local t = make(ui.Text, parent)
    t:SetPos(x or 0, y or 0)
    if w then t:SetSize(w, h, 0.0, 0.0) else t:SetSize(-(x or 0) * 2, h, 1.0, 0.0) end
    t.font = FONT
    t.maxLines = 0
    t:AlignTo(ui.AlignMode.TOPLEFT)
    t.colour = vec(colour or View.colour.text)
    t.content = content
    return t
end

local function rect(parent, hex, fill)
    local r = make(ui.Rectangle, parent)
    r:SetSize(0, 0, 1.0, 1.0)
    r.colour = vec(hex)
    r.fill = fill ~= false
    return r
end

local onWheel -- defined with scrolling below; rows forward the wheel to it

local function row(parent, height)
    local layer = make(ui.Layer, parent)
    layer:SetSize(0, height, 1.0, 0.0)
    pcall(function() layer:Subscribe(ui.Hook.ONSCROLLWHEEL, "rs3qb-scroll", onWheel) end)
    return layer
end

local BUTTON_STYLES = {
    primary = function() return id.StyleSheet.BUTTON_CORNERED_BOLD_POSITIVE end,
    default = function() return id.StyleSheet.BUTTON_DEFAULT end,
}

local function button(parent, spec, widthShare)
    local b = make(ui.Button, parent)
    b:SetSize(-4, 0, widthShare, 1.0)
    b.stylesheetID = (BUTTON_STYLES[spec.style or "default"] or BUTTON_STYLES.default)() or id.StyleSheet.BUTTON_DEFAULT
    b.label = spec.label
    b:Subscribe(ui.Hook.ONBUTTONPRESSED, press(spec.press))
    return b
end

-- ---------- row kinds ----------

local render = {}

function render.title(body, r, chars)
    local height = View.TextHeight(r.text, chars, contentWidth)
    text(body, r.text, View.colour.gold, nil, nil, nil, height)
    return height
end

function render.heading(body, r)
    local layer = row(body, 24)
    text(layer, r.text:upper(), View.colour.gold, 0, 6, nil, 18)
    return 24
end

function render.text(body, r, chars)
    local height = View.TextHeight(r.text, chars, contentWidth)
    text(body, r.text, r.colour and View.colour[r.colour], nil, nil, nil, height)
    return height
end

function render.buttons(body, r)
    local layer = make(ui.Panel, body)
    layer:SetSize(0, 30, 1.0, 0.0)
    layer.isVertical = false
    layer.spacing = 4
    for _, spec in ipairs(r.buttons) do button(layer, spec, 1 / #r.buttons) end
    return 30
end

function render.progress(body, r)
    local layer = row(body, 20)
    local track = make(ui.Layer, layer)
    track:SetPos(0, 5)
    track:SetSize(-70, 10, 1.0, 0.0)
    rect(track, View.colour.panel2)
    local fill = make(ui.Rectangle, track)
    fill:SetSize(0, 0, r.total > 0 and math.min(r.done / r.total, 1.0) or 0, 1.0)
    fill.colour = vec(View.colour.green)
    fill.fill = true
    local border = rect(track, View.colour.border, false)
    border.outlineThickness = 1
    local label = text(layer, string.format("%d / %d", r.done, r.total), View.colour.muted, 0, 1, 64, 18)
    label:SetX(-64, 1.0)
    return 20
end

-- A quest in the list: name on the left, coloured status on the right.
function render.quest(body, r)
    local layer = row(body, 30)
    local background = rect(layer, View.colour.panel)
    text(layer, r.name, View.colour.text, 10, 6, nil, 18)
    local status = text(layer, r.status, View.colour[r.statusColour] or View.colour.muted, 0, 6, 150, 18)
    status:SetX(-160, 1.0)
    status:AlignTo(ui.AlignMode.BOTTOMRIGHT, ui.AlignMode.TOPLEFT)
    local hit = make(ui.Button, layer)
    hit:SetSize(0, 0, 1.0, 1.0)
    hit.label = ""
    hit.alpha = 0.0
    hit:Subscribe(ui.Hook.ONBUTTONPRESSED, press(r.press))
    pcall(function() background:Subscribe(ui.Hook.ONCLICK, press(r.press)) end)
    return 30
end

-- A guide step: checkbox, then its paragraphs (`r.blocks`: { text, colour,
-- indent }) with notes and items indented under the instruction; gold
-- border when current, dimmed when done.
local function stepBlockHeights(r, chars)
    local heights, total = {}, 0
    for i, b in ipairs(r.blocks) do
        -- Matches render.step: text from x = 34 + indent, 8 units short of the edge.
        local width = contentWidth - 42 - (b.indent or 0) * STEP_INDENT
        heights[i] = View.TextHeight(b.text, View.CharsFor(width), width)
        total = total + heights[i] + 2
    end
    return heights, total
end

function render.step(body, r, chars)
    local heights, textHeight = stepBlockHeights(r, chars)
    local height = textHeight + 10
    local layer = row(body, height)
    rect(layer, r.state == "current" and View.colour.panel2 or View.colour.panel)
    if r.state == "current" then
        local border = rect(layer, View.colour.gold, false)
        border.outlineThickness = 1
    end
    local check = make(ui.Check, layer)
    check.stylesheetID = id.StyleSheet.CHECKBOX_DEFAULT
    check:SetPos(6, 6)
    check:SetSize(20, 20)
    check.value = r.state == "done"
    check:Subscribe(ui.Hook.ONBUTTONPRESSED, press(function(_, ticked)
        if ticked == nil then ticked = check.value end
        r.toggle(ticked)
    end))
    local y = 5
    for i, b in ipairs(r.blocks) do
        local x = 34 + (b.indent or 0) * STEP_INDENT
        local colour = r.state == "done" and View.colour.muted or (View.colour[b.colour or "text"] or View.colour.text)
        local t = text(layer, b.text, colour, x, y, nil, heights[i])
        t:SetSize(-(x + 8), heights[i], 1.0, 0.0)
        y = y + heights[i] + 2
    end
    return height
end

-- Paragraphs with indents and no background (the items overview).
function render.blocks(body, r, chars)
    local heights, total = {}, 0
    for i, b in ipairs(r.blocks) do
        local width = contentWidth - (b.indent or 0) * STEP_INDENT
        heights[i] = View.TextHeight(b.text, View.CharsFor(width), width)
        total = total + heights[i] + 2
    end
    local layer = row(body, total)
    local y = 0
    for i, b in ipairs(r.blocks) do
        local x = (b.indent or 0) * STEP_INDENT
        local t = text(layer, b.text, View.colour[b.colour or "text"] or View.colour.text, x, y, nil, heights[i])
        t:SetSize(-x, heights[i], 1.0, 0.0)
        y = y + heights[i] + 2
    end
    return total
end

function render.spacer(body, r)
    row(body, r.height or 6)
    return r.height or 6
end

-- ---------- render ----------

-- Everything that's visible about the rows; equal signatures mean no redraw.
function View.Signature(rows)
    local parts = {}
    for _, r in ipairs(rows) do
        parts[#parts + 1] = r.kind .. "|" .. tostring(r.text or r.name or "") .. "|" .. tostring(r.status or "") ..
            "|" .. tostring(r.state or "") .. "|" .. tostring(r.done or "") .. "/" .. tostring(r.total or "")
        for _, b in ipairs(r.blocks or {}) do
            parts[#parts + 1] = (b.indent or 0) .. (b.colour or "") .. b.text
        end
        for _, spec in ipairs(r.buttons or {}) do parts[#parts + 1] = spec.label end
    end
    return table.concat(parts, "\n")
end

-- ---------- scrolling ----------

-- The panel clips whatever runs past its bottom edge, so scrolling is just
-- moving the content up: the wheel shifts it by `offset`, kept between 0
-- and how far the content overflows. The offset survives redraws.
local SCROLL_STEP = 40
local BAR_WIDTH = 4
local scroll = { offset = 0, content = 0, view = 0, body = nil, bar = nil, anchorY = nil, rowTops = {} }

-- A thin bar on the right showing where in the content the view is.
local function placeBar()
    local bar = scroll.bar
    if bar == nil then return end
    pcall(function()
        if scroll.content <= scroll.view or scroll.view <= 0 then
            bar.hidden = true
            return
        end
        local track = scroll.view
        local height = math.max(20, math.floor(track * scroll.view / scroll.content))
        local y = math.floor(scroll.offset / (scroll.content - scroll.view) * (track - height))
        bar:SetPos(contentWidth + 10, 8 + y)
        bar:SetSize(BAR_WIDTH, height)
        bar.hidden = false
    end)
end

local function applyScroll()
    scroll.offset = math.max(0, math.min(scroll.offset, scroll.content - scroll.view))
    if scroll.body ~= nil then pcall(function() scroll.body:SetPos(8, 8 - scroll.offset) end) end
    placeBar()
end

-- Wheel down moves the content up, a quarter of the view at a time.
onWheel = function(_, delta)
    if type(delta) ~= "number" then return end
    local step = math.max(SCROLL_STEP, math.floor(scroll.view / 4))
    scroll.offset = scroll.offset + (delta > 0 and step or -step)
    applyScroll()
end

-- Jump back to the top, e.g. when switching quests.
function View.ScrollToTop()
    scroll.offset = 0
    applyScroll()
end

-- Where the view is, and back to a remembered place (the quest list after
-- a look at a guide).
function View.ScrollOffset() return scroll.offset end
function View.ScrollTo(offset)
    scroll.offset = offset or 0
    applyScroll()
end

-- To the row marked `anchor` (the current step) in the last render.
function View.ScrollToAnchor()
    if scroll.anchorY ~= nil then View.ScrollTo(scroll.anchorY - 60) end
end

-- To row `index` of the last render (the quest list's letter jumps).
function View.ScrollToRow(index)
    local top = scroll.rowTops[index]
    if top ~= nil then View.ScrollTo(top - 8) end
end

-- Draw `rows` into `root`, replacing `previous` (the last body returned).
-- With `focus`, scrolls so the row marked `anchor = true` (the current
-- step) is near the top, like the Alt1 app's list. Returns the new body.
function View.Render(root, rows, previous, focus)
    if previous ~= nil then pcall(function() previous:Destroy() end) end
    if scroll.bar ~= nil then pcall(function() scroll.bar:Destroy() end) end
    scroll.bar = nil
    rangeStart, nextID = (rangeStart == 1) and (ID_RANGE + 1) or 1, 0

    local width, height = 0, 0
    pcall(function() width, height = root.width, root.height end)
    contentWidth = width > 100 and (width - 16) or 400
    local chars = View.CharsFor(contentWidth)
    Diag.Snapshot("panelSize", tostring(width) .. "x" .. tostring(height))

    local body = make(ui.Panel, root)
    body.isVertical = true
    body.spacing = 4
    local total, anchorY = 0, nil
    scroll.rowTops = {}
    for i, r in ipairs(rows) do
        if i > 1 then total = total + body.spacing end
        if r.anchor then anchorY = total end
        scroll.rowTops[i] = total
        local ok, rowHeight = Diag.Guard("render " .. r.kind, render[r.kind], body, r, chars)
        if not ok then break end
        total = total + (rowHeight or 0)
    end
    -- The body is as tall as its content so nothing is squeezed; the root clips it.
    body:SetSize(-16, total, 1.0, 0.0)
    scroll.body, scroll.content, scroll.view, scroll.anchorY = body, total, height - 16, anchorY
    if focus and anchorY ~= nil then scroll.offset = anchorY - 60 end
    if total > scroll.view and scroll.view > 0 then
        local bar = make(ui.Rectangle, root)
        bar.colour = vec(View.colour.border)
        bar.fill = true
        scroll.bar = bar
    end
    applyScroll()
    for _, target in ipairs({ root, body }) do
        pcall(function() target:Subscribe(ui.Hook.ONSCROLLWHEEL, "rs3qb-scroll", onWheel) end)
    end
    return body
end

return View
