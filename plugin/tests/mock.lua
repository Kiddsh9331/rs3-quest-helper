-- Minimal stand-in for the RS plugin API, enough to load and drive the
-- test plugin outside the game. Records everything for assertions.
M = { logs = {}, handlers = {}, created = {}, entities = {}, db = {}, perms = { httpAccess = true, chatAccess = true } }

function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    M.logs[#M.logs + 1] = table.concat(parts, " ")
end
function formatStr(f, ...) return f end

Vector3 = { new = function(x, y, z) return { x = x, y = y, z = z } end }
Vector4 = { new = function(r, g, b, a) return { r, g, b, a } end }

id = {
    Font = { MUSEO_SANS_15PT_REGULAR = 1 },
    Inv = { INV = 93, MONEY_POUCH = 623 },
    StyleSheet = { DEFAULT = 1, BUTTON_DEFAULT = 2 },
    Component = { TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP = 999 },
    Interface = { DIALOGUE_OPTIONS = 1188 },
}

PersistentDB = {}
local function dbGet(_, k) return M.db[k] end
local function dbSet(_, k, v) M.db[k] = v; return true end
PersistentDB.Get, PersistentDB.GetString, PersistentDB.GetBool, PersistentDB.GetStructuredData = dbGet, dbGet, dbGet, dbGet
PersistentDB.Set, PersistentDB.SetString, PersistentDB.SetBool, PersistentDB.SetStructuredData = dbSet, dbSet, dbSet, dbSet
PersistentDB.GetInt, PersistentDB.SetInt = dbGet, dbSet
function PersistentDB:Delete(k) M.db[k] = nil return true end

-- ---------- ui ----------
local Component = {}
Component.__index = Component
M.maxDynamicID = 0
local function newComponent(kind, parent, categoryID, dynamicID)
    local c = setmetatable({ kind = kind, parent = parent, children = {}, hooks = {}, destroyed = false,
        xyGlobal = { x = 0, y = 0 }, width = 100, height = 20, visibleGlobal = true, staticID = 0,
        categoryID = categoryID, dynamicID = dynamicID or -1 }, Component)
    if parent then parent.children[#parent.children + 1] = c end
    if dynamicID and dynamicID > M.maxDynamicID then M.maxDynamicID = dynamicID end
    M.created[#M.created + 1] = c
    return c
end
function Component:SetSize(w, h) self.w, self.h = w, h end
function Component:SetPos(x, y) self.x, self.y = x, y end
function Component:SetX() end
function Component:SetY() end
function Component:AlignTo() end
function Component:SetHeaderLayout(...) assert(select("#", ...) == 5) end
function Component:Subscribe(hook, a, b) self.hooks[hook] = b or a end
function Component:Destroy() self.destroyed = true end
function Component:IterateDynamicComponents(cb)
    for _, child in ipairs(self.dynamic or {}) do if cb(child, true) then return end end
end
-- A real click lands in its own logic tick; presses are debounced per tick.
function Component:Press()
    if M.handlers.Logic then M.handlers.Logic({}) end
    return self.hooks["press"](self)
end

ui = {
    ComponentType = { LABEL = "label", BUTTON = "button", CHECK = "check", SPRITE = "sprite" },
    AlignMode = { TOPLEFT = 0, CENTRE = 1, BOTTOMRIGHT = 2 },
    Hook = { ONBUTTONPRESSED = "press", ONCLICK = "click", ONSCROLLWHEEL = "wheel", ONRESIZE = "resize" },
    Interfaces = {},
}
for _, kind in ipairs({ "Text", "Button", "Panel", "GroupBox", "Rectangle", "Layer", "Check", "Line" }) do
    ui[kind] = { new = function(parent, categoryID, dynamicID)
        assert(parent ~= nil, kind .. " created without a parent")
        return newComponent(kind, parent, categoryID, dynamicID)
    end }
end

M.layer = newComponent("Layer")         -- the shared plugin layer (card, option boxes)
M.layer.interfaceID = 1477
M.panelRoot = newComponent("Layer")     -- the ribbon panel's content layer
M.panelRoot.interfaceID = 1604
M.panelRoot.width, M.panelRoot.height = 420, 900
M.interfaces = {} -- [interfaceID] = { [staticID] = component }
function ui.Interfaces:GetInterface(interfaceID) return M.interfaces[interfaceID] end
function ui.Interfaces:GetComponent(a, b)
    if b == nil then return a == id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP and M.layer or nil end
    local iface = M.interfaces[a]
    return iface and iface[b] or nil
end
-- A backpack item icon: a sprite tagged with the item's object ID.
function M.sprite(objectID, x)
    local c = newComponent("Sprite")
    c.type, c.associatedObjectID, c.xyGlobal = ui.ComponentType.SPRITE, objectID, { x = x or 600, y = 500 }
    return c
end
function M.label(text, x)
    local c = newComponent("Label")
    c.type, c.content, c.xyGlobal = ui.ComponentType.LABEL, text, { x = x or 10, y = 50 }
    return c
end

-- ---------- game data ----------
M.questVar = { configName = "QUEST_KNIGHTS_SWORD", value = 0 }
M.knightsSword = { started = false, finished = false }
-- ID 2 is an old deprecated copy of The Knight's Sword with no progress
-- data: the plugin must prefer ID 5, the live one (the bug seen in game).
local questNames = { [1] = "Goblin Diplomacy", [2] = "The Knight's Sword", [5] = "The Knight's Sword",
    [9] = "Vampyre Slayer", [12] = "Priest in Peril", [20] = "Witch's House" }
config = {
    Quest = { FromID = function(i)
        if i == 3 then error("bad id") end
        local name = questNames[i]
        if name == nil then return nil end
        if i == 2 then
            return { id = 2, name = name, deprecated = true, hasStartedQuest = false, canStartQuest = true, masterQuestVars = {} }
        end
        local q = { id = i, configName = "Q" .. i, name = name, deprecated = false, canStartQuest = true,
            hasFinishedQuest = (i == 1), hasStartedQuest = false,
            masterQuestVars = { { varPlayer = M.questVar, startState = 1, endState = 7 } },
            preReqSkills = {}, preReqQuests = {}, preReqQuestPoints = 0 }
        if i == 9 then
            q.preReqSkills = { { skillType = 2, minimumLevel = 10 } }
            q.preReqQuests = { { name = "Goblin Diplomacy", hasFinishedQuest = true } }
            q.preReqQuestPoints = 3
        end
        if i == 5 then
            setmetatable(q, { __index = function(_, k)
                if k == "hasStartedQuest" then return M.knightsSword.started end
                if k == "hasFinishedQuest" then return M.knightsSword.finished end
            end })
            q.hasStartedQuest, q.hasFinishedQuest = nil, nil
        end
        return q
    end },
    Inv = { INV = 93, MONEY_POUCH = { id = 623, configName = "MONEY_POUCH", size = 1 }, FromID = function(i)
        if i == 623 then return { id = 623, configName = "MONEY_POUCH", size = 1 } end
        return nil
    end },
}

-- ---------- player, inventory, mouse ----------
M.backpack = {}
M.pouch = 0 -- coins in the money pouch (inventory 623)
Inventory = { Find = function(inv)
    local invID = type(inv) == "table" and inv.id or inv
    if invID == 623 then
        return { isValid = true, slotCount = 1, GetSlots = function()
            if M.pouch > 0 then return { { obj = { name = "Coins", id = 995 }, count = M.pouch } } end
            return {}
        end }
    end
    assert(invID == 93, "unknown inventory " .. tostring(invID))
    return { isValid = true, slotCount = 28, usedSlotCount = #M.backpack, freeSlotCount = 28 - #M.backpack,
        GetSlots = function()
            local slots = {}
            for i, item in ipairs(M.backpack) do slots[i] = { obj = { name = item[1], id = item[3] or (1000 + i) }, count = item[2] } end
            return slots
        end }
end }
M.player = { position = { x = 3001 * 512, y = 0, z = 3100 * 512 }, coordGrid = { level = 0 } }
M.levels = { [2] = 5 } -- Strength 5
Player = { GetEntity = function() return M.player end, GetLevelCapped = function(skill) return M.levels[skill] or 1 end }
M.mouse = { x = 500, y = 300 }
Mouse = { GetPosition = function() return { x = M.mouse.x, y = M.mouse.y } end }
ScreenConvert = { Vector3ToScreen = function(v) return { x = 400, y = 300 } end }
MiniMenuEntryType = { INTERFACE = 1, LOC = 3, NPC = 4, PLAYER = 7 }
GameKey = { D = 33, F = 35 }
ModifierKey = { SHIFT = 1, CONTROL = 2, ALT = 4 }
function M.select(verb, subject, entryType)
    M.fire("MiniMenuEntrySelected", { entry = { verbText = verb, subjectText = subject, actionEntryType = entryType or 4 } })
end

Plugin = { urls = { wiki = "https://runescape.wiki" }, HasPermission = function(p) return M.perms[p] end }
PluginPermissions = { httpAccess = "httpAccess", chatAccess = "chatAccess" }
ChatType = { NPC_CHAT = 99 }

HTTPRequest = { new = function(base, path)
    M.lastUrl = base .. "/" .. path
    return { Get = function(self, cb)
        cb({ successful = true, responseCode = 200, data = "{{Checklist|x}} {{Checklist|y}}", url = M.lastUrl })
    end }
end }

-- ---------- events ----------
Event = setmetatable({}, { __index = function(t, name)
    local e = {
        Subscribe = function(key, fn) M.handlers[name] = fn end,
        Unsubscribe = function(key) M.handlers[name] = nil end,
    }
    rawset(t, name, e)
    return e
end })
function M.fire(name, payload) assert(M.handlers[name], "no handler for " .. name)(payload or {}) end

-- ---------- world ----------
M.npcs = { ["Squire Asrol"] = { { config = { gridSize = 1 }, coordGrid = "tile-a", isValid = true,
    aabb = { minimum = { x = 0, y = 0, z = 0 }, maximum = { x = 400, y = 900, z = 400 }, centre = { x = 200, y = 450, z = 200 } },
    position = { x = 2975 * 512, y = 0, z = 3343 * 512 } } } }
NPCList = { ByName = function(name) return M.npcs[name] or {} end }
M.locs = {}
LocList = { ByDistance = function(coord, range)
    assert(coord ~= nil and range > 0)
    return M.locs
end }
-- A scenery object with its right-click options.
function M.loc(name, tile, ops)
    return { displayName = name, coordGrid = tile, width = 1, length = 1,
        position = { x = 0, y = 0, z = 0 }, config = { opNames = ops or {} } }
end
M.draws = 0
M.drawn = {} -- every ShapeList.Draw call's settings
World = { GetGroundHeight = function(level, x, z) return 300, true end }
ShapeData = { new = function() return {} end }
ShapeEntityAlignType = { MODEL = 2 }
CoordGrid = { new = function(...) return { ... } end }
local Entity = {}
Entity.__index = Entity
function Entity:SetShapeData(d) assert(#d.positions == #d.rgba, "positions/rgba mismatch") self.data = d return true end
function Entity:SetDrawDistance() end
function Entity:Destroy() self.isValid = false end
ShapeList = {
    CreateEntity = function(name)
        local e = setmetatable({ name = name, isValid = true, visible = true }, Entity)
        M.entities[name] = e
        return e
    end,
    DestroyEntity = function(name) return false end,
    Draw = function(settings)
        assert(#settings.shapePositions == #settings.shapeRGBA, "Draw positions/rgba mismatch")
        M.draws = M.draws + 1
        M.drawn[#M.drawn + 1] = settings
    end,
}
