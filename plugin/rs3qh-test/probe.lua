-- Dialogue probe: reads the text of the game's loaded interfaces. The Alt1
-- app has to pixel-match the dialogue box; a plugin can read the option
-- labels directly, once it knows which interface holds them.
--
-- Everything here is wrapped in pcall: the API doesn't document which
-- built-in interfaces hold the dialogue, so the probe must survive
-- components that aren't what it expects.

local Probe = {}

-- Generous upper bounds; unloaded interface IDs are a cheap nil lookup.
local MAX_INTERFACE_ID = 3000
local MAX_STATIC_ID = 600
local MAX_DYNAMIC_DEPTH = 6

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then return result end
    return nil
end

-- id.Interface maps names to IDs; flip it so reports can name interfaces.
local interfaceNames = {}
pcall(function()
    for name, value in pairs(id.Interface) do interfaceNames[value] = name end
end)

function Probe.InterfaceName(interfaceID)
    return interfaceNames[interfaceID] or ("interface " .. tostring(interfaceID))
end

local function componentText(component)
    return safe(function()
        local kind = component.type
        if kind == ui.ComponentType.LABEL then return component.content end
        if kind == ui.ComponentType.BUTTON or kind == ui.ComponentType.CHECK then
            return component.label
        end
        return nil
    end)
end

function Probe.IsLabel(component)
    return safe(function() return component.type == ui.ComponentType.LABEL end) == true
end

function Probe.TypeName(component)
    local kind = safe(function() return component.type end)
    for name, value in pairs(ui.ComponentType or {}) do
        if value == kind then return name:lower() end
    end
    return tostring(kind)
end

-- Only components the player can actually see: reading hidden interface
-- state is prohibited by the plugin guidelines, so "unknown" counts as hidden.
local function isVisible(component)
    return safe(function() return component.visibleGlobal end) == true
end

local function visit(component, fn, depth)
    if isVisible(component) then fn(component) end
    if depth >= MAX_DYNAMIC_DEPTH then return end
    -- Only layout components have children; for anything else this errors
    -- harmlessly inside the pcall.
    pcall(function()
        component:IterateDynamicComponents(function(child)
            visit(child, fn, depth + 1)
            return false -- keep iterating
        end)
    end)
end

function Probe.IsLoaded(interfaceID)
    return safe(function() return ui.Interfaces:GetInterface(interfaceID) end) ~= nil
end

-- Calls fn(component) for every visible component of a loaded interface;
-- returns false when the interface isn't loaded.
local function walk(interfaceID, fn)
    if not Probe.IsLoaded(interfaceID) then return false end
    for staticID = 0, MAX_STATIC_ID do
        local component = safe(function() return ui.Interfaces:GetComponent(interfaceID, staticID) end)
        if component ~= nil then visit(component, fn, 0) end
    end
    return true
end

-- Texts in one interface, appended to `out`; nil when it isn't loaded.
function Probe.TextsIn(interfaceID, out)
    out = out or {}
    local loaded = walk(interfaceID, function(component)
        local text = componentText(component)
        if text ~= nil and text ~= "" then
            out[#out + 1] = { interfaceID = interfaceID, component = component, text = text }
        end
    end)
    return loaded and out or nil
end

-- Item icons (sprites tagged with an object ID) in one interface whose ID is
-- in `wanted` ({ [objectID] = true }), appended to `out`.
function Probe.ItemIconsIn(interfaceID, wanted, out)
    walk(interfaceID, function(component)
        local objectID = safe(function()
            if component.type == ui.ComponentType.SPRITE then return component.associatedObjectID end
        end)
        if objectID ~= nil and wanted[objectID] then
            out[#out + 1] = { interfaceID = interfaceID, component = component, objectID = objectID }
        end
    end)
    return out
end

-- Set of loaded interface IDs ({ [id] = true }): cheap enough to take every
-- tick, and diffing two of them shows which interface a conversation opened.
function Probe.LoadedSet()
    local set = {}
    for interfaceID = 0, MAX_INTERFACE_ID do
        if Probe.IsLoaded(interfaceID) then set[interfaceID] = true end
    end
    return set
end

-- Every loaded interface's texts except `exclude` (the plugin's own).
function Probe.ScanAll(exclude)
    local texts, loaded = {}, {}
    for interfaceID in pairs(Probe.LoadedSet()) do
        if not (exclude and exclude[interfaceID]) then
            Probe.TextsIn(interfaceID, texts)
            loaded[#loaded + 1] = interfaceID
        end
    end
    table.sort(loaded)
    return texts, loaded
end

-- ---------- matching guide chat against what's on screen ----------

-- "<col=ff0000>1. Chat</col>" -> "chat"
function Probe.Normalise(text)
    text = text:gsub("<[^>]*>", " "):lower()
    text = text:gsub("^%s*%d+[%.:]?%s+", "")
    return (text:gsub("[^%w]", ""))
end

-- "1 Chat / 2 Ask about X / Accept" -> { "chat", "askaboutx", "accept" }
function Probe.ChatCandidates(chat)
    local out = {}
    if chat == nil then return out end
    for part in (chat .. " / "):gmatch("(.-) / ") do
        local text = Probe.Normalise((part:gsub("^%s*%d+%s*", "")))
        if #text >= 2 then out[#out + 1] = text end
    end
    return out
end

-- Exact match, or containment when the guide truncates a long option. The
-- label may only be a little longer than the candidate, so a paragraph that
-- happens to quote the option (like the guide's own step text) never counts.
function Probe.TextMatches(label, candidate)
    if label == candidate then return true end
    if #label >= 6 and #candidate >= 6 and #label <= #candidate + 12 then
        return label:find(candidate, 1, true) ~= nil or candidate:find(label, 1, true) ~= nil
    end
    return false
end

-- Entries from `texts` whose text matches one of the chat candidates.
function Probe.Matches(texts, candidates)
    local matches = {}
    for _, entry in ipairs(texts) do
        local label = Probe.Normalise(entry.text)
        for _, candidate in ipairs(candidates) do
            if Probe.TextMatches(label, candidate) then
                matches[#matches + 1] = entry
                break
            end
        end
    end
    return matches
end

return Probe
