-- Everything the plugin draws over the game screen itself:
--   * the step card (like the Alt1 overlay): title bar with a progress strip
--     under it, then the step as separate paragraphs (instruction, chat,
--     indented notes, items needed). Click its title bar to pick it up, move
--     the mouse, click again to drop it; the position is saved.
--     (Click-to-pick-up rather than press-and-drag: the API has no "mouse
--     button is down" query, so a missed release can't strand it.)
--   * a line of text under the player's feet (a teleport suggestion)
--   * the dialogue option to pick: its text turned blue, and the original
--     colour put back afterwards
--   * outlines around backpack items the step wants you to use
--
-- The plugin layer is shared with other plugins, so our components use
-- their own category ID and fixed dynamic IDs, reused rather than
-- recreated, which also keeps them from running out of IDs.

local Card = {}

local View = require("view")

local FONT = id.Font.MUSEO_SANS_15PT_REGULAR
local CATEGORY = 177              -- our components' category on the shared plugin layer
local WIDTH = 480
local HEADER_HEIGHT = 26
local STRIP_HEIGHT = 5            -- progress strip under the title
local PAD = 10
local INDENT = 16                 -- per indent level
local CARD_TEXT_INSET = 8         -- the card wraps a little sooner than its width suggests (63 characters in 460)
local MAX_BLOCKS = 40
local MAX_MARKS = 6
local FLOAT_ID = 90               -- the text under the player's feet
local FLOAT_WIDTH = 360
local OPTION_COLOUR = Vector4.new(0.35, 0.75, 1.0, 1.0)   -- chosen dialogue option text
local ITEM_COLOUR = Vector4.new(0.0, 1.0, 1.0, 1.0)       -- backpack item outline
local DB_POSITION = "cardPosition"

local box, header = nil, nil
local strip, stripFill = nil, nil
local blockTexts = {}             -- Text components for the paragraphs, reused
local cardBase = 100              -- alternates 100 / 200 so a rebuilt card never reuses live IDs
local moving, grabX, grabY = false, 0, 0
local overlaysHidden = false      -- true during cutscenes
local title = ""
local position = PersistentDB:GetStructuredData(DB_POSITION) -- { x, y } or nil = top centre

local function pluginLayer()
    local ok, layer = pcall(function()
        return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    end)
    return ok and layer or nil
end

local function mousePosition()
    local ok, at = pcall(Mouse.GetPosition)
    if ok and at ~= nil then return at.x, at.y end
    return nil
end

local function headerLabel()
    return title .. (moving and "   (click to drop)" or "")
end

local function toggleMove()
    if box == nil then return end
    if not moving then
        local mx, my = mousePosition()
        if mx == nil then return end
        grabX, grabY = mx - box.xyGlobal.x, my - box.xyGlobal.y
        moving = true
    else
        moving = false
        position = { x = box.x, y = box.y }
        PersistentDB:SetStructuredData(DB_POSITION, position)
    end
    header.label = headerLabel()
end

local function build(height)
    local layer = pluginLayer()
    if layer == nil then return false end -- not in game yet; the caller retries
    cardBase = (cardBase == 100) and 200 or 100
    blockTexts = {}
    box = ui.GroupBox.new(layer, CATEGORY, cardBase)
    box.stylesheetID = id.StyleSheet.DEFAULT
    box:SetHeaderLayout(0, 0, 0, 0, 0)
    -- Size the box before adding children: text laid out against a
    -- zero-size parent never wraps (the first card showed one cut-off line).
    box:SetSize(WIDTH, height)
    if position ~= nil then
        box:SetPos(position.x, position.y)
    else
        box:SetX(0, 0.5, -0.5)
        box:SetY(70)
    end
    header = ui.Button.new(box, CATEGORY, cardBase + 1)
    header.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    header:SetPos(4, 4)
    header:SetSize(-8, HEADER_HEIGHT - 4, 1.0, 0.0)
    header:Subscribe(ui.Hook.ONBUTTONPRESSED, toggleMove)
    -- Progress: a dark track under the title, filled green as steps are done.
    strip = ui.Rectangle.new(box, CATEGORY, cardBase + 2)
    strip:SetPos(6, HEADER_HEIGHT + 2)
    strip:SetSize(WIDTH - 12, STRIP_HEIGHT)
    strip.colour = Vector4.new(0.15, 0.17, 0.15, 1.0)
    strip.fill = true
    stripFill = ui.Rectangle.new(box, CATEGORY, cardBase + 3)
    stripFill:SetPos(6, HEADER_HEIGHT + 2)
    stripFill:SetSize(0, STRIP_HEIGHT)
    stripFill.colour = Vector4.new(0.5, 0.75, 0.3, 1.0)
    stripFill.fill = true
    return true
end

local function blockText(i)
    if blockTexts[i] == nil then
        local t = ui.Text.new(box, CATEGORY, cardBase + 10 + i)
        t.font = FONT
        t.maxLines = 0
        t:AlignTo(ui.AlignMode.TOPLEFT)
        blockTexts[i] = t
    end
    return blockTexts[i]
end

-- Lay `blocks` ({ text, colour, indent }) out top to bottom; returns the
-- card height they need.
local function layout(blocks)
    local y = HEADER_HEIGHT + STRIP_HEIGHT + 8
    for i = 1, math.min(#blocks, MAX_BLOCKS) do
        local b = blocks[i]
        local x = PAD + (b.indent or 0) * INDENT
        local width = WIDTH - x - PAD
        local height = View.TextHeight(b.text, View.CharsFor(width - CARD_TEXT_INSET))
        local t = blockText(i)
        t:SetPos(x, y)
        t:SetSize(width, height)
        t.colour = View.Vec(View.colour[b.colour or "text"] or View.colour.text)
        t.content = b.text
        t.hidden = false
        y = y + height + (b.gap or 2)
    end
    for i = #blocks + 1, MAX_BLOCKS do
        if blockTexts[i] ~= nil then blockTexts[i].hidden = true end
    end
    return y + 6
end

-- Card.HeightFor(blocks): the height Show will make the card.
function Card.HeightFor(blocks)
    local y = HEADER_HEIGHT + STRIP_HEIGHT + 8
    for i = 1, math.min(#blocks, MAX_BLOCKS) do
        local width = WIDTH - PAD - (blocks[i].indent or 0) * INDENT - PAD
        y = y + View.TextHeight(blocks[i].text, View.CharsFor(width - CARD_TEXT_INSET)) + (blocks[i].gap or 2)
    end
    return y + 6
end

-- Show or update the card: title, `blocks` of text, and progress (0..1).
function Card.Show(newTitle, blocks, progress)
    local height = Card.HeightFor(blocks)
    if box == nil and not build(height) then return end
    title = newTitle
    header.label = headerLabel()
    box:SetSize(WIDTH, height)
    layout(blocks)
    pcall(function() stripFill:SetSize(math.floor((WIDTH - 12) * math.max(0, math.min(1, progress or 0))), STRIP_HEIGHT) end)
    box.hidden = overlaysHidden
    pcall(function() box:UpdateLayout() end)
end

function Card.Hide()
    if box ~= nil then pcall(function() box:Destroy() end) end
    box, header, strip, stripFill, blockTexts, moving = nil, nil, nil, nil, {}, false
end

function Card.IsShown() return box ~= nil end

-- ---------- text under the player ----------

local floating, floatingText = nil, nil

-- Show `text` under the player's feet (nil hides it).
function Card.SetFloating(text)
    floatingText = text
    if text == nil and floating ~= nil then pcall(function() floating.hidden = true end) end
end

local function followFloating()
    if floatingText == nil then return end
    local layer = pluginLayer()
    if layer == nil then return end
    if floating == nil then
        floating = ui.Text.new(layer, CATEGORY, FLOAT_ID)
        floating.font = FONT
        floating.maxLines = 1
        floating:AlignTo(ui.AlignMode.CENTRE, ui.AlignMode.TOPLEFT)
        floating.colour = Vector4.new(1.0, 0.85, 0.3, 1.0)
        pcall(function() floating.isShadowed = true end)
        floating:SetSize(FLOAT_WIDTH, 20)
    end
    local ok, at = pcall(function() return ScreenConvert.Vector3ToScreen(Player.GetEntity().position) end)
    if not ok or at == nil or overlaysHidden then
        floating.hidden = true
        return
    end
    floating.content = floatingText
    floating:SetPos(at.x - layer.xyGlobal.x - FLOAT_WIDTH / 2, at.y - layer.xyGlobal.y + 14)
    floating.hidden = false
end

-- Hide the card and item outlines (cutscenes) or show them again.
function Card.SetHidden(value)
    overlaysHidden = value
    if box ~= nil then pcall(function() box.hidden = value end) end
    if value and floating ~= nil then pcall(function() floating.hidden = true end) end
end

-- Called every logic tick (50/s): keeps a picked-up card under the mouse,
-- and the text under the player's feet.
function Card.Follow()
    pcall(followFloating)
    if not moving or box == nil then return end
    local mx, my = mousePosition()
    local layer = pluginLayer()
    if mx == nil or layer == nil then return end
    box:SetPos(mx - grabX - layer.xyGlobal.x, my - grabY - layer.xyGlobal.y)
end

function Card.InterfaceID()
    local layer = pluginLayer()
    return layer and layer.interfaceID or nil
end

-- ---------- pooled marks ----------

-- A fixed set of components per kind of mark, shown/hidden instead of
-- created/destroyed. `make(i)` builds slot i's components.
local pools = {}

local function pool(name, make)
    if pools[name] == nil then pools[name] = { make = make, slots = {} } end
    return pools[name]
end

local function slot(p, i)
    if p.slots[i] == nil then p.slots[i] = p.make(i) end
    return p.slots[i]
end

local function hideFrom(p, first)
    for i = first, MAX_MARKS do
        local s = p.slots[i]
        if s ~= nil then
            for _, c in ipairs(s) do c.hidden = true end
        end
    end
end

-- ---------- dialogue option ----------

-- Keyed by the component's IDs: the game may hand back a fresh Lua wrapper
-- for the same component every tick, so the wrapper itself can't be a key.
local recoloured = {}   -- key -> { component, original colour }

local function componentKey(c)
    local ok, key = pcall(function()
        return table.concat({ c.interfaceID, c.staticID, c.categoryID or -1, c.dynamicID or -1 }, ":")
    end)
    return ok and key or tostring(c)
end

local function restoreColours(keep)
    for key, entry in pairs(recoloured) do
        if not keep[key] then
            pcall(function() entry[1].colour = entry[2] end)
            recoloured[key] = nil
        end
    end
end

-- Turn the dialogue options in `targets` (text components) blue.
function Card.MarkOptions(targets)
    local keep = {}
    for i = 1, math.min(#targets, MAX_MARKS) do
        local c = targets[i]
        local key = componentKey(c)
        keep[key] = true
        pcall(function()
            if recoloured[key] == nil then recoloured[key] = { c, c.colour } end
            recoloured[key][1] = c
            c.colour = OPTION_COLOUR
        end)
    end
    restoreColours(keep)
end

-- ---------- backpack items ----------

local itemBoxes = pool("item", function(i)
    local rect = ui.Rectangle.new(pluginLayer(), CATEGORY, 70 + i)
    rect.colour = ITEM_COLOUR
    rect.fill = false
    rect.outlineThickness = 2
    return { rect }
end)

-- Outline the item icons in `targets` (sprite components).
function Card.MarkItems(targets)
    local layer = pluginLayer()
    if layer == nil then return end
    if overlaysHidden then targets = {} end
    local origin = layer.xyGlobal
    for i = 1, math.min(#targets, MAX_MARKS) do
        local c = targets[i]
        pcall(function()
            local rect = slot(itemBoxes, i)[1]
            rect:SetPos(c.xyGlobal.x - origin.x - 1, c.xyGlobal.y - origin.y - 1)
            rect:SetSize(c.width + 2, c.height + 2)
            rect.hidden = false
        end)
    end
    hideFrom(itemBoxes, #targets + 1)
end

function Card.Shutdown()
    Card.Hide()
    if floating ~= nil then pcall(function() floating:Destroy() end) end
    floating, floatingText = nil, nil
    restoreColours({})
    for _, p in pairs(pools) do
        for _, s in pairs(p.slots) do
            for _, c in ipairs(s) do pcall(function() c:Destroy() end) end
        end
        p.slots = {}
    end
end

return Card
