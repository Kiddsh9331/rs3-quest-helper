--[[ RS3 Quest Buddy: the RS3 Quest Helper Alt1 app's quest guides inside the game client.

Loaded by main.lua. Steps come from quests.lua, generated from the
RuneScape Wiki's quick guides by the Alt1 app's own parser. edition.lua
says whether this is the test build (debug tools, recording on) or the
release build made by tools/package.py.

Modules:
  advance.lua  which step an interaction belongs to; item matching (pure logic)
  world.lua    NPC boxes, scenery outlines, tile beacon, direction arrow
  card.lua     the movable step card and dialogue option boxes over the game
  view.lua     draws the ribbon panel in the Alt1 app's style
  probe.lua    reading dialogue option text out of the game's interfaces
  path.lua     the walking path for the dotted line (A* around walls)
  travel.lua   which lodestone to teleport to when the next place is far
  diag.lua     errors and status saved for debugging
  recorder.lua a timeline of the play session, for replaying bugs offline
  edition.lua  test build or release build (see above)
  devtools.lua the test build's Debug section (not in the release build)

The guide advances by itself (Auto: on) when the player:
  * interacts with something the current or a near-upcoming step names
    (jumps straight to that step),
  * finishes a step they were engaged in and the quest's progress var moves,
  * picks up the item an "Obtain/Mine/Buy..." step asks for,
  * completes the quest. ]]

local Quests = require("quests")       -- list of quests, plus .pages and .items from the wiki
local Advance = require("advance")
local Probe = require("probe")
local World = require("world")
local Card = require("card")
local Travel = require("travel")
local View = require("view")
local Diag = require("diag")
local Recorder = require("recorder")
local Edition = require("edition")
local DevTools = Edition.devTools and require("devtools") or nil

local BUILD = "0.3.0 settings"                 -- written at the top of each recording; bump on every install
local VAR_LOG_MAX = 40
local DIALOGUE_WATCH_TICKS = 40          -- ~24s after "Talk-to" to spot the dialogue opening
local DIALOGUE_MAX_NEW = 3               -- more new interfaces at once is a UI reload, not a conversation
local MAX_LEARNED_INTERFACES = 8
local ARRIVED_DISTANCE = 12              -- tiles from a travel step's destination that count as there
local INHERIT_LOOKBACK = 6               -- steps searched back for "them"/"him" NPCs
local BACKPACK_SCAN_EVERY = 10           -- ticks between full scans while the backpack isn't found
local ITEM_VAR_TICKS = 3                 -- a progress rise this soon after an item moved the step is the same event
local ENTER_NEAR = 25                    -- tiles from an "Enter ..." step's place where its doors are outlined
local WALL_STATS_EVERY = 50              -- ticks between notes of what the path saw (for the recording)
local UNDERGROUND_Y = 6400               -- map rows from here north are dungeons
local CARD_SUBS = 8                      -- a step's notes on the card; long lists stay in the panel
local DOT_SIZES = { small = 64, medium = 90, large = 130 }   -- path dot half-widths (a tile is 512)
local NEXT_DOT_SIZE = { small = "medium", medium = "large", large = "small" }
local TUNE = {
    arrivedRough = 20,      -- tiles that count as "there" for a rough spot ("the room to the north")
    roughTiles = 10,        -- how far "to the north" of the last place a rough spot is put
    cardTextMax = 300,      -- characters of a step's instruction on the card; the rest is in the panel
    ownTeleportFar = 60,    -- tiles; a step's own teleport replaces the dots from further than this
    clickSettle = 3,        -- ticks after clicking the step's own object before it counts
    resizeSettle = 10,      -- ticks after the panel stops resizing before it's redrawn
}
-- The quest list's filters and letter jumps; the card sizes cycle.
local LIST = {
    filters = { "all", "started", "todo", "done" },
    labels = { all = "All", started = "Started", todo = "Not started", done = "Done" },
    groups = { { "A-D", "A", "D" }, { "E-H", "E", "H" }, { "I-L", "I", "L" }, { "M-P", "M", "P" },
        { "Q-T", "Q", "T" }, { "U-Z", "U", "Z" } },
    nextCardSize = { small = "medium", medium = "large", large = "small" },
}

local pages = Quests.pages or {}         -- [lower-case wiki page] = { kind, x, y, plane }
local itemInfo = Quests.items or {}      -- [lower-case item] = how to get or make it
local recipes = Quests.recipes or {}     -- [lower-case item] = { mats, facility, skill }
local tradeable = Quests.tradeable or {} -- [lower-case item] = true when sold on the Grand Exchange

-- dialogInterfaces3: earlier lists got polluted, first by a UI reload after
-- a cutscene ("learned" the backpack and ability bars), then by tooltips
-- that happened to open during a conversation. Only interfaces showing
-- numbered options are learned now; a new key starts the list clean.
local DB_QUEST, DB_STEPS, DB_VARLOG, DB_PREFS, DB_DIALOG_IFACES =
    "quest", "steps", "varLog", "prefs", "dialogInterfaces3"

-- ---------- state ----------

local questKey = PersistentDB:GetString(DB_QUEST)                       -- quest the guide is on
local stepIndex = PersistentDB:GetStructuredData(DB_STEPS) or {}        -- [questKey] = next step to do (1-based)
local subDone = PersistentDB:GetStructuredData("subDone") or {}           -- ["questKey:index"] = sub-bullets ticked on a list step
local varLog = PersistentDB:GetStructuredData(DB_VARLOG) or {}          -- [questKey] = { "step 3: 10 -> 20", ... }
local dialogInterfaces = PersistentDB:GetStructuredData(DB_DIALOG_IFACES) or {} -- where options were seen
local prefs = PersistentDB:GetStructuredData(DB_PREFS) or {}
local function pref(name, default)
    if prefs[name] == nil then return default end
    return prefs[name]
end

Recorder.enabled = pref("record", Edition.recordByDefault)
Recorder.Start(Diag.loadNumber)
Diag.onNote = function(message) Recorder.Add("note", message) end

local screen = questKey and "guide" or "list"
local reports = { probe = "", fetch = "", chat = "", dialogue = "", action = "", auto = "" }
local lastVarValue = nil
local backpack = nil            -- { [lower-case item name] = count }, nil when unreadable
local backpackIDs = {}          -- { [lower-case item name] = object ID }
local bagState = { free = nil, pouchInv = nil, pouch = 0 } -- empty slots; the money pouch inventory and its coins
local backpackInterfaces = {}   -- interfaces where backpack item icons were found
local backpackScanCooldown = 0
local finishedSeen = false
local serverTick = 0            -- server ticks since load
local lastItemStep = -100       -- serverTick when the backpack last moved the step (see onBackpackChange)
local travelHint = nil          -- { name, walk }: teleport suggestion for the current step
local climbsDone = 0            -- climbs made on the current step ("the ladder, then the staircase")

local questByKey, flatSteps = {}, {}
for _, quest in ipairs(Quests) do
    local list = {}
    for _, section in ipairs(quest.sections) do
        for i, step in ipairs(section.steps) do
            list[#list + 1] = { section = section, sectionStart = (i == 1), step = step, index = #list + 1 }
        end
    end
    questByKey[quest.key] = quest
    flatSteps[quest.key] = list
end

local function currentQuest() return questKey and questByKey[questKey] end
-- Saved values come back as floats (16.0); keep step numbers integers.
local function currentIndex() return math.tointeger(questKey and stepIndex[questKey] or 1) or 1 end
local function currentEntry()
    local list = questKey and flatSteps[questKey]
    return list and list[currentIndex()]
end

local function norm(text) return (text:lower():gsub("[^%w]", "")) end
local function onOff(value) return value and "on" or "off" end
local function safe(fn)
    local ok, result = pcall(fn)
    if ok then return result end
    return nil
end

-- ---------- game quest data ----------

-- The quest's master progress variable entry ({ varPlayer, startState, endState }).
local function masterVar(questType)
    local master = safe(function()
        local list = questType.masterQuestVars
        return list[1] or list[0]
    end)
    if master ~= nil then return master end
    return safe(function()
        for _, entry in pairs(questType.masterQuestVars) do return entry end
    end)
end

-- In-game QuestType by display name. Several configs can share a name (old
-- deprecated copies), so keep the best: not deprecated, with progress data.
local questTypes = nil
local function questTypeFor(quest)
    if questTypes == nil then
        questTypes = {}
        local scores = {}
        for questID = 0, 2000 do
            local ok, questType = pcall(config.Quest.FromID, questID)
            if ok and questType ~= nil then
                local name = safe(function() return questType.name end)
                if type(name) == "string" and name ~= "" then
                    local score = 0
                    if safe(function() return questType.deprecated end) == false then score = score + 2 end
                    if masterVar(questType) ~= nil then score = score + 1 end
                    local key = norm(name)
                    if scores[key] == nil or score > scores[key] then
                        questTypes[key], scores[key] = questType, score
                    end
                end
            end
        end
    end
    return questTypes[norm(quest.name)]
end

local function questStatus(quest)
    local questType = questTypeFor(quest)
    if questType == nil then return "not in game data" end
    return safe(function()
        if questType.hasFinishedQuest then return "complete" end
        if questType.hasStartedQuest then return "started" end
        if questType.canStartQuest then return "can start" end
        return "requirements not met"
    end) or "status unreadable"
end

local STATUS_LOOK = {
    ["complete"] = { "Done", "green" },
    ["started"] = { "Started", "gold" },
    ["can start"] = { "Not started", "muted" },
    ["requirements not met"] = { "Missing reqs", "red" },
}

local function progressValue(quest)
    local questType = questTypeFor(quest)
    local master = questType and masterVar(questType)
    if master == nil then return nil end
    return safe(function() return master.varPlayer.value end)
end

-- The game's own requirements for the quest (config.Quest.preReqSkills and
-- preReqQuests): skills with the player's level, prerequisite quests with
-- their status, quest points. Lines as panel blocks, sorted.
local function requirementBlocks(quest)
    local questType = questTypeFor(quest)
    if questType == nil then return {} end
    local blocks = {}
    for _, req in pairs(safe(function() return questType.preReqSkills end) or {}) do
        local skill, level = safe(function() return req.skillType end), safe(function() return req.minimumLevel end)
        if type(level) == "number" and level > 0 then
            local name = Advance.SKILL_NAMES[math.tointeger(tonumber(skill) or -1) or -1] or tostring(skill)
            local have = safe(function() return Player.GetLevelCapped(skill) end)
            local colour = "text"
            if type(have) == "number" then colour = have >= level and "green" or "red" end
            blocks[#blocks + 1] = { text = string.format("- %d %s%s", level, name,
                type(have) == "number" and string.format(" (you: %d)", have) or ""), colour = colour }
        end
    end
    for _, req in pairs(safe(function() return questType.preReqQuests end) or {}) do
        local name = safe(function() return req.name end)
        if type(name) == "string" and name ~= "" then
            local done = safe(function() return req.hasFinishedQuest end)
            blocks[#blocks + 1] = { text = "- " .. View.Escape(name), colour = done == nil and "text" or (done and "green" or "red") }
        end
    end
    local points = safe(function() return questType.preReqQuestPoints end)
    if type(points) == "number" and points > 0 then
        blocks[#blocks + 1] = { text = string.format("- %d quest points", points), colour = "text" }
    end
    table.sort(blocks, function(a, b) return a.text < b.text end)
    return blocks
end

-- Debug line: which config was picked and its progress var.
local function questInfo(quest)
    local questType = questTypeFor(quest)
    if questType == nil then return "Quest config: not found" end
    local master = masterVar(questType)
    local info = string.format("Quest config %s #%s, deprecated %s",
        tostring(safe(function() return questType.configName end)),
        tostring(safe(function() return questType.id end)),
        tostring(safe(function() return questType.deprecated end)))
    if master == nil then return info .. "<br>Progress var: none readable" end
    return info .. string.format("<br>Progress var %s = %s (start %s, end %s)",
        tostring(safe(function() return master.varPlayer.configName end)), tostring(progressValue(quest)),
        tostring(safe(function() return master.startState end)), tostring(safe(function() return master.endState end)))
end

-- ---------- backpack ----------

-- Item counts by lower-case name; also remembers each item's object ID so
-- its icon can be found in the backpack interface.
-- The money pouch isn't in the docs; look for an inventory config whose
-- name says pouch or money (id.Inv), else the classic id 623. false when
-- there's none to read.
local function pouchInventory()
    if bagState.pouchInv ~= nil then return bagState.pouchInv end
    local found = false
    safe(function()
        local names = {}
        for name in pairs(id.Inv) do
            local upper = tostring(name):upper()
            if upper:find("POUCH", 1, true) or upper:find("MONEY", 1, true) then names[#names + 1] = name end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local inv = Inventory.Find(config.Inv[name])
            if inv ~= nil and inv.isValid ~= false then found = config.Inv[name] break end
        end
        if found == false then
            local cfg = config.Inv.FromID(623)
            local inv = cfg ~= nil and Inventory.Find(cfg)
            if inv ~= nil and inv.isValid ~= false then found = cfg end
        end
    end)
    bagState.pouchInv = found
    Diag.Snapshot("moneyPouch", found and tostring(safe(function() return found.configName end) or found) or "not found")
    return found
end

local function readBackpack()
    return safe(function()
        local counts, ids = {}, {}
        local inv = Inventory.Find(config.Inv.INV)
        local used = 0
        for _, slot in pairs(inv:GetSlots()) do
            local name = slot ~= nil and slot.obj ~= nil and Advance.Clean(slot.obj.name) or ""
            if name ~= "" then -- empty slots come back as nameless objects
                counts[name] = (counts[name] or 0) + (slot.count or 1)
                ids[name] = safe(function() return slot.obj.id end)
                used = used + 1
            end
        end
        -- Empty slots, from the inventory itself when it says (Inv.freeSlotCount).
        local free = safe(function() return inv.freeSlotCount end)
        if type(free) ~= "number" then
            local total = safe(function() return inv.slotCount end)
            free = (type(total) == "number" and total or 28) - used
        end
        bagState.free = free
        -- Coins live in the money pouch, not the backpack: count them as if
        -- they were in it, so "5 coins" and "buy X for five coins" work.
        bagState.pouch = 0
        local pouch = pouchInventory()
        if pouch then
            safe(function()
                for _, slot in pairs(Inventory.Find(pouch):GetSlots()) do
                    local name = slot ~= nil and slot.obj ~= nil and Advance.Clean(slot.obj.name) or ""
                    if name == "coins" then bagState.pouch = bagState.pouch + (slot.count or 0) end
                end
            end)
            if bagState.pouch > 0 then counts["coins"] = (counts["coins"] or 0) + bagState.pouch end
        end
        backpackIDs = ids
        return counts
    end)
end

local function infoFor(name)
    return itemInfo[name:lower()] or itemInfo[Advance.Singular(name:lower())]
end

-- Does a section's "needed" list include this item?
local function sectionNeeds(section, need)
    local want = Advance.Singular(need.name)
    for _, entry in ipairs(section.needed) do
        for _, item in ipairs(Advance.SplitNeeded(entry)) do
            if Advance.Singular(Advance.ParseNeeded(item).name) == want then return true end
        end
    end
    return false
end

-- Which steps use an item: the last step that mentions it (after that it's
-- no longer needed) and the "use X on Y" steps that each hand one over.
-- Make steps count colour words too ("Dye one goblin mail blue" uses blue dye),
-- and "Talk to Thurgo with the materials" uses everything its section needs.
local function itemUse(quest, need)
    quest.useCache = quest.useCache or {}
    local cached = quest.useCache[need.name]
    if cached ~= nil then return cached end
    local use = { last = nil, gives = {} }
    local colour = need.name:match("^(%a+)")
    for i, entry in ipairs(flatSteps[quest.key]) do
        local step = entry.step
        local text = Advance.FullText(step)
        local named = Advance.Mentions(text, need.name) or Advance.Mentions(text, Advance.Singular(need.name))
        local byColour = Advance.IsMakeStep(step) and colour ~= nil and Advance.Mentions(step.text, colour)
        local asMaterial = Advance.UsesMaterials(step) and sectionNeeds(entry.section, need)
        if named or byColour or asMaterial then use.last = i end
        if named and Advance.IsUseStep(step) and not Advance.IsMakeStep(step) then use.gives[#use.gives + 1] = i end
    end
    quest.useCache[need.name] = use
    return use
end

-- How many of an item are still needed at step `current`, or nil when the
-- item isn't needed any more (already used, or turned into something else).
local function stillNeeded(quest, need, current)
    local use = itemUse(quest, need)
    if use.last ~= nil and current > use.last then return nil end
    local given = 0
    for _, index in ipairs(use.gives) do
        if index < current then given = given + 1 end
    end
    return math.max(1, need.qty - given)
end

local function recipeFor(name)
    return recipes[name:lower()] or recipes[Advance.Singular(name:lower())]
end

local function haveText(need, text)
    if backpack == nil then return View.Escape(text) end
    return View.Col(Advance.HaveCount(backpack, need) >= need.qty and "green" or "red", View.Escape(text))
end

-- How a missing item is made, as indented blocks, following the materials
-- you don't have yet a few levels down:
--   from Uncooked berry pie (Range, Cooking 10)
--     Uncooked berry pie: from Pie shell + Redberries (Cooking 10)
--       Pie shell: from Pie dish + Pastry dough (Cooking 1)
local RECIPE_DEPTH = 4
local function recipeBlocks(name, indent, out, depth, seen)
    local recipe = recipeFor(name)
    if recipe == nil or depth > RECIPE_DEPTH or seen[Advance.Singular(name:lower())] then return false end
    seen[Advance.Singular(name:lower())] = true
    local mats, missing = {}, {}
    for _, mat in ipairs(recipe.mats) do
        local need = Advance.ParseNeeded(mat)
        mats[#mats + 1] = haveText(need, mat)
        if backpack == nil or Advance.HaveCount(backpack, need) < need.qty then missing[#missing + 1] = need.name end
    end
    local extra = {}
    if recipe.facility ~= "" then extra[#extra + 1] = View.Escape(recipe.facility) end
    if recipe.skill ~= "" then extra[#extra + 1] = View.Escape(recipe.skill) end
    local text = "from " .. table.concat(mats, " + ") .. (#extra > 0 and (" (" .. table.concat(extra, ", ") .. ")") or "")
    if depth > 1 then text = View.Escape(name:sub(1, 1):upper() .. name:sub(2)) .. ": " .. text end
    out[#out + 1] = { text = text, colour = "muted", indent = indent }
    for _, mat in ipairs(missing) do recipeBlocks(mat, indent + 1, out, depth + 1, seen) end
    return true
end

-- Ingredients the guide itself lists in brackets ("Orange dye (Combine Red
-- dye and Yellow dye)"), minus notes like "(obtainable during quest)".
local function guideParts(need)
    local parts = {}
    for _, part in ipairs(need.parts) do
        if not part:find("quest") and not part:find("obtain") then parts[#parts + 1] = part end
    end
    return parts
end

local function isTradeable(name)
    return tradeable[name:lower()] or tradeable[Advance.Singular(name:lower())]
end

-- Is this one item the backpack can show? Not advice like "Combat gear and
-- food" or "Ice gloves for defeating flambeed, or expect to fight unarmed",
-- which would stay red forever. "A shield or antifire potion" is fine:
-- either counts.
local KIT_WORDS = { "gear", "food", "equipment", "armour", "weapon", "supplies", "space", "spellbook", "potions",
    "access", "ability", "abilities", "style" }
local function checkable(need)
    local name = need.name
    if (pages[name] and pages[name].kind == "item") or tradeable[name] ~= nil or recipes[name] then return true end
    if name:find(",", 1, true) then return false end
    for option in (name .. " or "):gmatch("(.-) or ") do
        local _, words = Advance.OptionNeed(option).name:gsub("%S+", "")
        if words > 4 then return false end
        for _, word in ipairs(KIT_WORDS) do
            if option:find(word, 1, true) then return false end
        end
    end
    return true
end

-- Blocks for a list of items ({ label, need, qty?, recommended?, hint? }):
-- one line each, green when carried and red when missing, with "(1/2)"
-- counts. Under a missing item, how to get it: the guide's own note when it
-- has one ("Bars can be withdrawn at the anvil"), else for ironmen how it's
-- made, and for everyone else a Grand Exchange hint when it's tradeable.
-- With `withInfo`, the wiki's description too. Recommended items are listed plainly.
local function itemBlocks(items, indent, withInfo)
    local out = {}
    local ironman = pref("ironman", false)
    for _, item in ipairs(items) do
        local label = View.Escape((item.label:gsub("%s*%b()", "")))
        local need, qty = item.need, item.qty or item.need.qty
        if need.slots and not item.recommended and bagState.free ~= nil then
            -- "3 free inventory slots": against the backpack's empty slots.
            local free = bagState.free
            out[#out + 1] = { text = "- " .. label .. string.format(" (free: %d/%d)", math.min(free, need.slots), need.slots),
                colour = free >= need.slots and "green" or "red", indent = indent }
        elseif item.recommended or backpack == nil or not checkable(need) then
            -- Kit advice ("combat gear and food") is muted: nothing to check.
            out[#out + 1] = { text = "- " .. label .. (item.recommended and " (recommended)" or ""),
                colour = (item.recommended or not checkable(need)) and "muted" or "text", indent = indent }
        else
            local have = Advance.HaveCount(backpack, item.either or need)
            local count = qty > 1 and string.format(" (%d/%d)", math.min(have, qty), qty) or ""
            out[#out + 1] = { text = "- " .. label .. count, colour = have >= qty and "green" or "red", indent = indent }
            if have < qty then
                if item.hint then
                    out[#out + 1] = { text = View.Escape(item.hint), colour = "muted", indent = indent + 1 }
                elseif not ironman and isTradeable(need.name) then
                    out[#out].text = out[#out].text .. View.Col("muted", "  (Grand Exchange)")
                elseif not recipeBlocks(need.name, indent + 1, out, 1, {}) then
                    local parts = guideParts(need)
                    if #parts > 0 then
                        local shown = {}
                        for i, part in ipairs(parts) do shown[i] = haveText({ name = part, qty = 1 }, part) end
                        out[#out + 1] = { text = "from " .. table.concat(shown, " + "), colour = "muted", indent = indent + 1 }
                    end
                end
                if withInfo then
                    local info = infoFor(need.name)
                    if info then out[#out + 1] = { text = View.Escape(info), colour = "muted", indent = indent + 1 } end
                    for _, part in ipairs(guideParts(need)) do
                        local partInfo = Advance.HaveCount(backpack, { name = part }) == 0 and infoFor(part)
                        if partInfo then out[#out + 1] = { text = View.Escape(partInfo), colour = "muted", indent = indent + 1 } end
                    end
                end
            end
        end
    end
    return out
end

-- The quest's items still needed at step `current`, from the guide's
-- per-section lists (used-up items left out), for the panel's overview.
local function overviewItems(quest, neededList, current)
    local items = {}
    for _, entry in ipairs(neededList) do
        for _, label in ipairs(Advance.SplitNeeded(entry)) do
            local need = Advance.ParseNeeded(label)
            local qty = stillNeeded(quest, need, current)
            if qty ~= nil then items[#items + 1] = { label = label, need = need, qty = qty } end
        end
    end
    return items
end

-- Every needed item in the quest, parsed (with ingredients as items too).
local function neededParsed(quest)
    if quest.neededCache == nil then
        local all = {}
        for _, section in ipairs(quest.sections) do
            for _, entry in ipairs(section.needed) do
                for _, item in ipairs(Advance.SplitNeeded(entry)) do
                    local need = Advance.ParseNeeded(item)
                    all[#all + 1] = need
                    for _, part in ipairs(need.parts) do all[#all + 1] = { name = part, qty = 1, parts = {} } end
                end
            end
        end
        quest.neededCache = all
    end
    return quest.neededCache
end

-- Can you carry it? Known from the wiki (an item page, or one the Grand
-- Exchange or a recipe knows), or one of the quest's own items. "Get: boat"
-- or "Get: to the top" aren't.
local function isItem(quest, name)
    local lower = name:lower()
    local single = Advance.Singular(lower)
    for _, key in ipairs({ lower, single }) do
        local info = pages[key]
        if (info and info.kind == "item") or tradeable[key] ~= nil or recipes[key] then return true end
    end
    for _, need in ipairs(neededParsed(quest)) do
        if Advance.Singular(need.name) == single then return true end
    end
    return false
end

-- What a step's own words say to get, keeping only real items.
local function acquireTargets(quest, step)
    local out = {}
    for _, need in ipairs(Advance.AcquireTargets(step)) do
        if isItem(quest, need.name) then out[#out + 1] = need end
    end
    return out
end

local function questItems(quest)
    local all, seen = {}, {}
    for _, section in ipairs(quest.sections) do
        for _, item in ipairs(section.needed) do
            if not seen[item] then
                seen[item] = true
                all[#all + 1] = item
            end
        end
    end
    return all
end

-- ---------- step text ----------

local function stepCandidates(entry)
    if entry == nil then return {} end
    local candidates = Probe.ChatCandidates(entry.step.chat)
    for _, sub in ipairs(entry.step.subs or {}) do
        for _, candidate in ipairs(Probe.ChatCandidates(sub.chat)) do candidates[#candidates + 1] = candidate end
    end
    return candidates
end


-- ---------- what a step points at ----------

-- Steps like "Use the orange goblin mail on one of them" don't name the
-- NPC again; borrow the last NPCs named a few steps back.
local function refersBack(step)
    if Advance.IsMakeStep(step) then return false end
    local text = " " .. step.text:lower() .. " "
    return Advance.IsUseStep(step) or text:find(" h[ie][mr][%s%.,]") ~= nil
        or text:find(" them[%s%.,]") ~= nil or text:find(" again") ~= nil or text:find("talk") ~= nil
end

-- Destination preference: the most specific place wins. Pages with no
-- infobox kind but a map (inns, shops) beat whole towns: "Go to the Blue
-- Moon Inn located in Varrock" means the inn, not Varrock's centre.
local NAV_PRIORITY = { npc = 1, scenery = 2, place = 3, [""] = 3, location = 4 }

-- Roughly where a step happens, without asking other steps: its own map,
-- else the first linked page with a spot.
local function roughSpot(step)
    if step.tile then return { x = step.tile.x, y = step.tile.y } end
    for _, page in ipairs(step.npcs or {}) do
        local info = pages[page:lower()]
        if info and info.x then return { x = info.x, y = info.y } end
    end
    return nil
end

local stepTargets -- defined below; spotOf asks earlier steps

-- Where a page's thing is. NPCs found in several places (Ariane, Zanik)
-- have `alts`: where this quest met them before ("Return to Morgan"), else
-- the one nearest where the last few steps were.
local function spotOf(quest, index, info, name)
    local spot = { x = info.x, y = info.y, plane = info.plane }
    if info.alts == nil then return spot end
    for back = index - 1, 1, -1 do
        local earlier = stepTargets(quest, back)
        for _, other in ipairs(earlier.npcs) do
            if other == name and earlier.nav ~= nil then return earlier.nav end
        end
    end
    local list = flatSteps[quest.key]
    for back = index - 1, math.max(1, index - INHERIT_LOOKBACK), -1 do
        local near = roughSpot(list[back].step)
        -- Dungeon coordinates sit far north of the surface: no use comparing.
        if near and near.y < UNDERGROUND_Y then
            local best, bestDistance = spot, math.huge
            for _, alt in ipairs(info.alts) do
                local distance = math.abs(alt.x - near.x) + math.abs(alt.y - near.y)
                if distance < bestDistance then best, bestDistance = alt, distance end
            end
            return { x = best.x, y = best.y, plane = best.plane }
        end
    end
    return spot
end

-- NPCs linked anywhere in the quest, so a later step that just says
-- "Return to Morgan" (no link) still finds him.
local function questNPCs(quest)
    if quest.npcCache == nil then
        local names, seen = {}, {}
        for _, entry in ipairs(flatSteps[quest.key]) do
            for _, page in ipairs(entry.step.npcs or {}) do
                local info = pages[page:lower()]
                if info and info.kind == "npc" and not seen[page] then
                    seen[page] = true
                    names[#names + 1] = { name = (page:gsub("%s*%b()", "")), info = info }
                end
            end
        end
        quest.npcCache = names
    end
    return quest.npcCache
end

-- { npcs = display names, items = item names to use, nav = destination tile }
-- for flat step `index` of `quest`. Cached on the step.
function stepTargets(quest, index)
    local list = flatSteps[quest.key]
    local entry = list[index]
    if entry == nil then return { npcs = {}, items = {} } end
    if entry.targets ~= nil then return entry.targets end
    local step = entry.step
    local targets = { npcs = {}, items = {} }
    local navRank = 99
    -- "Teleport to Falador and run north to the Goblin Village": a travel
    -- step's destination is the last place it names, not the first.
    local travel = Advance.IsTravelStep(step)
    for _, page in ipairs(step.npcs or {}) do
        local info = pages[page:lower()] or {}
        if info.kind == "item" then
            targets.items[#targets.items + 1] = Advance.BaseName(page)
        elseif info.kind == "npc" or (info.kind == nil and Advance.LooksLikeName(step.text, page)) then
            -- An NPC, or an unplaced page written as a name in the step:
            -- worth a look. Not achievements, quests, skills, spells
            -- ("other") or "your backpack" and "the minimap".
            targets.npcs[#targets.npcs + 1] = page:gsub("%s*%b()", "")
        end
        local rank = NAV_PRIORITY[info.kind or ""] or 5
        -- Where an item is found only matters when the step gets it: "With
        -- the slashed book, go to the middle room" isn't about the bookcase.
        local spot = info.x ~= nil and (info.kind ~= "item" or Advance.IsAcquireStep(step))
        if spot and (rank < navRank or (travel and rank == navRank)) then
            targets.nav, navRank = spotOf(quest, index, info, (page:gsub("%s*%b()", ""))), rank
        end
    end
    local hasNPC = false
    for _, page in ipairs(step.npcs or {}) do
        if (pages[page:lower()] or {}).kind == "npc" then hasNPC = true end
    end
    -- Unlinked mentions of the quest's NPCs ("Return to Morgan."), or of
    -- part of a name when only one of the quest's NPCs fits ("Return to
    -- Veldaban" for Commander Veldaban, "the Duke" for Duke Horacio).
    local function addNPC(npc)
        targets.npcs[#targets.npcs + 1] = npc.name
        hasNPC = true
        if npc.info.x ~= nil and NAV_PRIORITY.npc < navRank then
            targets.nav, navRank = spotOf(quest, index, npc.info, npc.name), NAV_PRIORITY.npc
        end
    end
    local listed = {}
    for _, name in ipairs(targets.npcs) do listed[name] = true end
    for _, npc in ipairs(questNPCs(quest)) do
        if not listed[npc.name] and Advance.Mentions(step.text, npc.name) then
            listed[npc.name] = true
            addNPC(npc)
        end
    end
    if not hasNPC then
        local fits, fitting = 0, nil
        for _, npc in ipairs(questNPCs(quest)) do
            if not listed[npc.name] and Advance.MentionsPart(step.text, npc.name) then
                fits, fitting = fits + 1, npc
            end
        end
        if fits == 1 then addNPC(fitting) end
    end
    if not hasNPC and refersBack(step) then
        for back = index - 1, math.max(1, index - INHERIT_LOOKBACK), -1 do
            local earlier = stepTargets(quest, back)
            local named = false
            for _, page in ipairs(list[back].step.npcs or {}) do
                if (pages[page:lower()] or {}).kind == "npc" then named = true end
            end
            if named then
                for _, name in ipairs(earlier.npcs) do targets.npcs[#targets.npcs + 1] = name end
                targets.nav = targets.nav or earlier.nav
                step.inheritedNpcs = earlier.npcs  -- lets "Use X on General Wartface" match this step
                break
            end
        end
    end
    -- Items a use/make step works with: linked items, plus quest items the
    -- text mentions by name or colour ("Dye one goblin mail blue").
    if Advance.IsUseStep(step) or Advance.IsMakeStep(step) then
        for _, need in ipairs(neededParsed(quest)) do
            local first = need.name:match("^(%a+)")
            -- Colour words only on make steps: "Dye one goblin mail blue" uses blue
            -- dye, but "Use the orange goblin mail" doesn't use orange dye.
            local byColour = first and Advance.IsMakeStep(step) and Advance.Mentions(step.text, first)
            if Advance.Mentions(step.text, need.name) or byColour then
                targets.items[#targets.items + 1] = need.name
            end
        end
    end
    if step.tile then targets.nav = { x = step.tile.x, y = step.tile.y, plane = step.tile.plane } end
    -- "Give Thurgo the portrait": an NPC whose page has no map is where an
    -- earlier step met him (that step's map).
    if targets.nav == nil and #targets.npcs > 0 then
        local wanted = {}
        for _, name in ipairs(targets.npcs) do wanted[name] = true end
        for back = index - 1, 1, -1 do
            local earlier = stepTargets(quest, back)
            local metThere = false
            for _, name in ipairs(earlier.npcs) do metThere = metThere or wanted[name] == true end
            if metThere and earlier.nav ~= nil then
                targets.nav = earlier.nav
                break
            end
        end
    end
    -- "Teleport to Varrock" with nothing linked: the lodestone itself.
    if targets.nav == nil and travel then
        local lode = Travel.Named(step.text)
        if lode then targets.nav = { x = lode.x, y = lode.y, plane = 0 } end
    end
    -- "Head inside the room to the north", "Run south to the farming
    -- patches": no place, but a side. Roughly that way from the last place
    -- (dots, no marker, a wider "arrived").
    if targets.nav == nil and travel then
        local dir = Advance.CompassIn(step.text)
        local from = nil
        for back = index - 1, math.max(1, index - INHERIT_LOOKBACK), -1 do
            local earlier = stepTargets(quest, back).nav
            if earlier ~= nil and not earlier.rough then
                from = earlier
                break
            end
        end
        if dir ~= nil and from ~= nil then
            targets.nav = { x = from.x + dir[1] * TUNE.roughTiles, y = from.y + dir[2] * TUNE.roughTiles, plane = from.plane,
                rough = true }
        end
    end
    -- "Go to the cave" with "Talk to Bob" (mapped) next: the cave is there.
    local nextEntry = list[index + 1]
    if targets.nav == nil and travel and nextEntry ~= nil and not Advance.IsTravelStep(nextEntry.step) then
        local near = roughSpot(nextEntry.step)
        if near ~= nil then targets.nav = { x = near.x, y = near.y, rough = true } end
    end
    entry.targets = targets
    return targets
end

-- Items linked by the next couple of steps that the quest doesn't list as
-- needed: things a "make" step produces ("orange goblin mail").
local function producedItems(quest, index)
    local needed, produced = {}, {}
    for _, need in ipairs(neededParsed(quest)) do needed[Advance.Singular(need.name)] = true end
    local list = flatSteps[quest.key]
    for i = index + 1, math.min(#list, index + 2) do
        for _, page in ipairs(list[i].step.npcs or {}) do
            local name = Advance.BaseName(page)
            if (pages[page:lower()] or {}).kind == "item" and not needed[Advance.Singular(name)] then
                produced[#produced + 1] = name
            end
        end
    end
    return produced
end

-- Which objects to outline for a step:
--   * travel steps: none (the beacon shows the way; outlining every sign
--     or lamp that shares a word with a town name just adds noise)
--   * "Enter the manor": doors and gates
--   * "Walk down the stairs": only stairs/ladders whose menu goes that way
--   * otherwise: objects the step names, unless the name is just part of a
--     linked place ("Village" in "Draynor Village")
-- "to the east" of the player: dx, dz in tiles (north is +z).
local SIDE_TESTS = {
    east = function(dx) return dx > 0 end, west = function(dx) return dx < 0 end,
    north = function(_, dz) return dz > 0 end, south = function(_, dz) return dz < 0 end,
}

-- Only near where an "Enter ..." step happens: not every gate on the way there.
local function nearEntrance(nav)
    local here = World.playerTile
    return nav == nil or here == nil or math.abs(here.x - nav.x) + math.abs(here.z - nav.y) <= ENTER_NEAR
end

local function sceneryMatcher(entry)
    if entry == nil then return nil end
    local step = entry.step
    local quest = currentQuest()
    local nav = quest and stepTargets(quest, entry.index).nav
    -- "Go to the western room and mine an elemental rock" still outlines the
    -- rock, and so does "Head east to a stone door" with no map spot to show.
    if Advance.TravelFinishes(step) and nav ~= nil then return nil end
    local linked = {}
    for _, page in ipairs(step.npcs or {}) do
        linked[#linked + 1] = { name = Advance.BaseName(page), kind = (pages[page:lower()] or {}).kind }
    end
    local enter, direction = Advance.IsEnterStep(step), Advance.ClimbDirection(step)
    local ore = Advance.MinedOre(step)
    local goals = Advance.ClimbGoals(step)
    -- Sub-bullets count when the step introduces a list ("...from the
    -- following crates:" then "- Up a ladder in the middle of the gate"), or
    -- when they're about the step's items ("Bars can be withdrawn at the
    -- anvil"). Otherwise they're side notes ("Open the door to his room and
    -- wait"), and outlining every door they mention is noise.
    local source = step.text
    if step.text:match(":%s*$") then
        source = Advance.FullText(step)
    elseif quest ~= nil then
        for _, sub in ipairs(step.subs or {}) do
            for _, need in ipairs(neededParsed(quest)) do
                local lastWord = need.name:match("(%a+)$")
                if Advance.Mentions(sub.text, need.name)
                    or (lastWord and #lastWord >= 4 and Advance.Mentions(sub.text, lastWord)) then
                    source = source .. " " .. sub.text
                    break
                end
            end
        end
    end
    local text = source:lower()
    -- Named as the thing to click, or just a landmark? "Search the crate"
    -- outlines crates; "Talk to Adam, north of the well" doesn't outline wells.
    local function namesObject(name)
        local object, landmark = Advance.MentionRoles(source, name)
        for _, page in ipairs(step.npcs or {}) do
            -- Linked, but only where it is: "Climb the ladder behind the altar".
            if Advance.BaseName(page) == name then return object > 0 or landmark == 0 end
        end
        for _, other in ipairs(step.inheritedNpcs or {}) do
            if Advance.BaseName(other) == name then return true end
        end
        -- Three letters is enough: "Search the bed", "Open the box".
        return #name >= 3 and object > 0
    end
    -- "stairs" in a guide can be a "Staircase" in game: match by kind, unless
    -- they're only where something is ("Talk to Straven near the stairs").
    local climbKinds = {}
    for _, kind in ipairs({ "stair", "ladder", "trapdoor" }) do
        local asObject, asLandmark = Advance.MentionRoles(source, kind, true)
        if text:find(kind, 1, true) and (asObject > 0 or asLandmark == 0) then climbKinds[#climbKinds + 1] = kind end
    end
    -- Which one of several the step means ("the lever by the water wheel"):
    -- asked per scene name, as "Crates", "crate" and "crates" alike.
    local placements = {}
    local function place(name)
        if placements[name] == nil then
            local last = name:match("(%a+)$") or ""
            placements[name] = Advance.Placement(source, name) or Advance.Placement(source, (name:gsub("s$", "")))
                or Advance.Placement(source, (name:gsub("es$", "")))
                or (#last >= 4 and last ~= name and Advance.Placement(source, last)) or false
        end
        return placements[name] or nil
    end
    return function(loc)
        local name = Advance.Clean(loc.displayName or "")
        if name == "" then return false end
        if enter then
            -- "Enter the cave": the cave entrance. When nothing it names is
            -- in sight, the doors and gates there (fallbackMatcher).
            return nearEntrance(nav) and (namesObject(name) or namesObject(name:match("^(%S+)") or ""))
        end
        -- "Mine a blurite ore": the rocks with that ore.
        if ore ~= nil and name:find(ore, 1, true) and name:find("rock", 1, true) then return true end
        local climbable, anyClimb = false, false
        for _, kind in ipairs(climbKinds) do climbable = climbable or name:find(kind, 1, true) ~= nil end
        for _, goal in ipairs(goals) do anyClimb = anyClimb or name:find(goal.kind, 1, true) ~= nil end
        -- "Climb the ladder to the east, then the first staircase to the
        -- west": the climb that's next, on the side it says. Other things
        -- the step names ("Unlock the Prison Door and climb down the
        -- staircase") are outlined as well.
        if (climbable or anyClimb) and #goals > 0 and climbKinds[1] ~= nil then
            -- "Go upstairs and search the wardrobe": up there, the stairs
            -- back down aren't the way on.
            if climbsDone >= #goals then return false end
            local goal = goals[climbsDone + 1]
            if not name:find(goal.kind, 1, true) then return false end
            local here, there = World.playerTile, nil
            pcall(function() there = { x = loc.position.x / 512, z = loc.position.z / 512 } end)
            local side = goal.side and SIDE_TESTS[goal.side]
            if side and here and there and not side(there.x - here.x, there.z - here.z) then return false end
        -- "Elemental rocks" for "mine an elemental rock" (not plain "Rocks"
        -- for "the sharp rock").
        elseif not climbable and not namesObject(name)
            and not (name:find(" ", 1, true) and namesObject(Advance.Singular(name))) then
            return false
        end
        -- A "Falador" sign or lodestone isn't the town the step names, and a
        -- plain "Rock" isn't the "blurite rock" it links (but "Search the
        -- chest" still outlines the chest when the bank chest is linked too).
        local linkedItself = false
        for _, page in ipairs(linked) do
            if page.name == name and (page.kind == "location" or page.kind == "place") then return false end
            linkedItself = linkedItself or page.name == name
        end
        for _, page in ipairs(linked) do
            if not linkedItself and page.name ~= name and page.name:find(name, 1, true) then return false end
        end
        -- Only the climb's own ladders and stairs go by direction: the crate
        -- in "Search the crate, then climb down" has no "down" in its menu.
        if (climbable or anyClimb) and (direction == "down" or direction == "up") then
            local ops = ""
            pcall(function()
                for _, op in pairs(loc.config.opNames) do ops = ops .. " " .. tostring(op):lower() end
            end)
            if ops ~= "" and not ops:find(direction, 1, true) then return false end
        end
        return true
    end, place
end

-- Upstairs, when the step's target isn't in sight, the way on is usually
-- the stairs: steps right after a climb fall back to outlining them.
local function climbMatcher(loc)
    if World.playerTile == nil or (World.playerTile.level or 0) == 0 then return false end
    local name = Advance.Clean(loc.displayName or "")
    return name:find("stair", 1, true) ~= nil or name:find("ladder", 1, true) ~= nil
end

-- What's outlined when nothing the step names is in sight: for "Enter the
-- manor", the doors and gates there (a trapdoor only when the step says so);
-- upstairs after a climb, the stairs.
local function fallbackMatcher(quest, index)
    local list = flatSteps[quest.key]
    if list[index] == nil or Advance.IsTravelStep(list[index].step) then return nil end
    if Advance.IsEnterStep(list[index].step) then
        local nav = stepTargets(quest, index).nav
        return function(loc)
            local name = Advance.Clean(loc.displayName or "")
            return nearEntrance(nav) and ((name:find("door") ~= nil and not name:find("trapdoor"))
                or name:find("gate") ~= nil)
        end
    end
    for back = index - 1, math.max(1, index - 2), -1 do
        if Advance.ClimbDirection(list[back].step) ~= nil then return climbMatcher end
    end
    return nil
end

local FIGHT_KIT_WORDS = { "food", "combat", "armour", "weapon", "gear", "fight", "attack", "heal", "prayer", "potion" }

-- What to bring for a step, from the quest page's required/recommended
-- lists: anything the step's text names, and on fight steps the combat kit.
local function stepNeeds(quest, entry)
    if entry == nil then return {} end
    if entry.needs ~= nil then return entry.needs end
    local needs = {}
    local fight = Advance.IsFightStep(entry.step)
    -- A step that gets an item shouldn't also say to bring it.
    local acquiring = {}
    if Advance.IsAcquireStep(entry.step) then
        for _, need in ipairs(acquireTargets(quest, entry.step)) do acquiring[Advance.Singular(need.name)] = true end
    end
    local function consider(line, recommended)
        local first = (line:match("^(.-)%s*%(") or line:match("^(.-)%s+or%s") or line):gsub("^%d+%s*", "")
        if acquiring[Advance.Singular(Advance.ParseNeeded(first).name)] then return end
        local named = #first >= 4 and Advance.Mentions(entry.step.text, (first:gsub("^an?%s+", "")))
        local kit = false
        if fight then
            local lower = line:lower()
            for _, word in ipairs(FIGHT_KIT_WORDS) do kit = kit or lower:find(word, 1, true) ~= nil end
        end
        if named or kit then needs[#needs + 1] = (recommended and "(recommended) " or "") .. line end
    end
    for _, line in ipairs(quest.required or {}) do consider(line, false) end
    for _, line in ipairs(quest.recommended or {}) do consider(line, true) end
    if fight and #needs == 0 then needs[1] = "Combat gear and food" end
    entry.needs = needs
    return needs
end

-- Items this step itself needs: what its text names from the quest's
-- required/recommended lists ("with a Redberry pie"), its section's items
-- when it says "with the materials", what a use/make step uses, and combat
-- kit on fight steps. Not the whole section's list: "Report back to the
-- squire" doesn't need the iron bars any more.
local function stepItems(quest, entry)
    if entry == nil then return {} end
    if entry.items ~= nil then return entry.items end
    local items, seen = {}, {}
    local function add(label, recommended)
        local need = Advance.ParseNeeded(label)
        local key = Advance.Singular(need.name)
        if seen[key] or #need.name < 3 then return end
        seen[key] = true
        items[#items + 1] = { label = label, need = need, recommended = recommended }
    end
    for _, line in ipairs(stepNeeds(quest, entry)) do
        local recommended = line:find("^%(recommended%) ") ~= nil
        add((line:gsub("^%(recommended%) ", "")), recommended)
    end
    if Advance.UsesMaterials(entry.step) then
        for _, needed in ipairs(entry.section.needed) do
            for _, item in ipairs(Advance.SplitNeeded(needed)) do add(item, false) end
        end
    end
    if Advance.IsUseStep(entry.step) or Advance.IsMakeStep(entry.step) then
        for _, name in ipairs(stepTargets(quest, entry.index).items) do add((name:gsub("^%l", string.upper)), false) end
    end
    -- A side note about one of the items is its hint ("Bars can be withdrawn
    -- at the anvil in Thurgo's hut"), shown under the item instead of twice.
    entry.hintSubs = {}
    for _, item in ipairs(items) do
        local lastWord = item.need.name:match("(%a+)$")
        for _, sub in ipairs(entry.step.subs or {}) do
            if item.hint == nil and not sub.chat and (Advance.Mentions(sub.text, item.need.name)
                or (lastWord and #lastWord >= 4 and Advance.Mentions(sub.text, lastWord))) then
                item.hint = Advance.WithoutPictureRefs(sub.text)
                entry.hintSubs[sub] = true
            end
        end
    end
    entry.items = items
    return items
end

-- "Locations:" with the places as sub-bullets: a list step. Alt+D ticks
-- its sub-bullets one at a time (subDone) before moving on.
local function isListStep(step)
    return step.text:match(":%s*$") ~= nil and #(step.subs or {}) > 0
end
local function subsDone(entry)
    return subDone[tostring(questKey) .. ":" .. entry.index] or 0
end

-- A step as paragraphs ({ text, colour, indent }) for the card and the
-- panel: the instruction, the chat options, notes indented under it, then
-- what to bring and what to get, each item checked against the backpack
-- (left off steps already `done`). The compact card keeps the instruction,
-- chat and missing items only.
local function stepBlocks(quest, entry, forCard, done)
    if entry == nil then return { { text = "All steps done. Pick another quest from the list." } } end
    local step = entry.step
    local bring = stepItems(quest, entry)
    local compact = forCard and pref("cardDetail", "full") == "compact"
    local listStep = isListStep(step)
    local blocks = { { text = View.Escape(Advance.WithoutPictureRefs(step.text)) } }
    if forCard and #blocks[1].text > TUNE.cardTextMax then
        local cut = blocks[1].text:sub(1, TUNE.cardTextMax):match("^(.*)%s") or blocks[1].text:sub(1, TUNE.cardTextMax)
        blocks[1].text = cut .. "... " .. View.Col("muted", "(more in the panel)")
    end
    if step.chat then blocks[#blocks + 1] = { text = "Chat: " .. View.Escape(Probe.ChatLabel(step.chat)), colour = "chat" } end
    if Advance.HasPictureRef(step.text) and not done then
        blocks[#blocks + 1] = { text = "The wiki shows a picture for this step.", colour = "muted", indent = 1 }
    end
    if step.tile and not forCard then
        blocks[#blocks + 1] = { text = string.format("Map %d,%d", step.tile.x, step.tile.y), colour = "green" }
    end
    local shown, hidden = 0, 0
    local ticked = (listStep and not done) and subsDone(entry) or -1
    for i, sub in ipairs(step.subs or {}) do
        if (done or not entry.hintSubs[sub]) and not (compact and not listStep) then
            shown = shown + 1
            if forCard and shown > CARD_SUBS then
                hidden = hidden + 1
            else
                local mark, colour = "- ", "muted"
                if i <= ticked then mark = "[done] " elseif i == ticked + 1 then mark, colour = "> ", "gold" end
                blocks[#blocks + 1] = { text = mark .. View.Escape(Advance.WithoutPictureRefs(sub.text)) ..
                    (sub.chat and (" " .. View.Col("chat", "Chat: " .. View.Escape(sub.chat))) or ""), colour = colour, indent = 1 }
            end
        end
    end
    if hidden > 0 then
        blocks[#blocks + 1] = { text = string.format("- and %d more in the panel", hidden), colour = "muted", indent = 1 }
    end
    if done then return blocks end
    if compact then
        local missing = {}
        for _, item in ipairs(bring) do
            if not item.recommended and backpack ~= nil and checkable(item.need)
                and Advance.HaveCount(backpack, item.need) < (item.qty or item.need.qty or 1) then
                missing[#missing + 1] = item
            end
        end
        bring = missing
    end
    if #bring > 0 then
        blocks[#blocks + 1] = { text = "Bring:", colour = "gold" }
        for _, b in ipairs(itemBlocks(bring, 1, false)) do blocks[#blocks + 1] = b end
    end
    if Advance.IsAcquireStep(step) and not Advance.IsFightStep(step) then
        local get = {}
        for _, need in ipairs(acquireTargets(quest, step)) do get[#get + 1] = { label = need.label, need = need } end
        if #get > 0 then
            blocks[#blocks + 1] = { text = "Get:", colour = "gold" }
            for _, b in ipairs(itemBlocks(get, 1, false)) do blocks[#blocks + 1] = b end
            -- Fight Arena's armour with a full backpack: the borrow fails but
            -- the quest's var still moves. Say so before the click.
            local missing = 0
            for _, item in ipairs(get) do
                if backpack ~= nil and Advance.HaveCount(backpack, item.need) == 0 then missing = missing + 1 end
            end
            if bagState.free ~= nil and missing > 0 and bagState.free < missing then
                blocks[#blocks + 1] = { text = string.format("Backpack full: free %d slot%s first.", missing,
                    missing == 1 and "" or "s"), colour = "red", indent = 1 }
            end
        end
    end
    return blocks
end

-- ---------- card ----------

local function drawCard()
    local quest = currentQuest()
    if not pref("card", true) or quest == nil then
        Card.Hide()
        return
    end
    local entry = currentEntry()
    local list = flatSteps[quest.key]
    local blocks = stepBlocks(quest, entry, true)
    if travelHint ~= nil then
        table.insert(blocks, 1, { colour = "gold", text = travelHint.own and ("Teleport: " .. travelHint.name .. ", as the step says.")
            or string.format("Teleport: %s lodestone, then about %d tiles on foot.", travelHint.name, travelHint.walk) })
    end
    Card.Show(Card.Title(quest.name, string.format("%d / %d", math.min(currentIndex(), #list), #list)),
        blocks, (currentIndex() - 1) / math.max(1, #list))
end

-- ---------- panel ----------

local panelRoot, panelBody, panelSignature = nil, nil, nil
local focusedStep = nil -- "quest:step" the panel last scrolled to
-- resizedAt: serverTick of the last ONRESIZE on the panel; width: the
-- panel's width at the last redraw; listScroll: where the quest list was
-- scrolled to when a guide was opened.
local panelState = { resizedAt = nil, width = nil, listScroll = 0 }
local buildRows -- defined below; describes the current screen as rows

-- Redraw the panel if what it shows changed. Cheap to call often.
local function refreshPanel()
    if panelRoot == nil then return end
    local ok, rows = Diag.Guard("build rows", buildRows)
    if not ok then return end
    local signature = View.Signature(rows)
    if signature == panelSignature and panelBody ~= nil then return end
    panelState.width = safe(function() return panelRoot.width end)
    panelSignature = signature
    local stepKey = screen == "guide" and (tostring(questKey) .. ":" .. currentIndex()) or nil
    local focus = stepKey ~= nil and stepKey ~= focusedStep
    focusedStep = stepKey
    local rendered
    ok, rendered = Diag.Guard("render panel", View.Render, panelRoot, rows, panelBody, focus)
    panelBody = ok and rendered or nil
end

-- ---------- dialogue ----------

-- The plugin's own interfaces: never scan these for dialogue, or the
-- guide's text (which quotes the options) matches itself.
local function ownInterfaces()
    local own = {}
    local panelID = panelRoot and safe(function() return panelRoot.interfaceID end)
    if panelID then own[panelID] = true end
    local cardID = Card.InterfaceID()
    if cardID then own[cardID] = true end
    return own
end

local function learnDialogInterface(interfaceID)
    if ownInterfaces()[interfaceID] then return end
    for _, known in ipairs(dialogInterfaces) do
        if known == interfaceID then return end
    end
    dialogInterfaces[#dialogInterfaces + 1] = interfaceID
    Recorder.Add("learn", interfaceID, Probe.InterfaceName(interfaceID))
    while #dialogInterfaces > MAX_LEARNED_INTERFACES do table.remove(dialogInterfaces, 1) end
    PersistentDB:SetStructuredData(DB_DIALOG_IFACES, dialogInterfaces)
    Diag.Snapshot("dialogInterfaces", table.concat(dialogInterfaces, ","))
end

-- After "Talk-to", watch for interfaces that weren't loaded before: that's
-- the conversation. Learning it here means no manual scan is needed.
local dialogueWatch = nil -- { baseline = set, ticksLeft = n }

local function startDialogueWatch()
    dialogueWatch = { baseline = Probe.LoadedSet(), ticksLeft = DIALOGUE_WATCH_TICKS }
end

local function checkDialogueWatch()
    if dialogueWatch == nil then return end
    dialogueWatch.ticksLeft = dialogueWatch.ticksLeft - 1
    local own, opened = ownInterfaces(), {}
    for interfaceID in pairs(Probe.LoadedSet()) do
        if not dialogueWatch.baseline[interfaceID] and not own[interfaceID] then opened[#opened + 1] = interfaceID end
    end
    if #opened == 0 then
        if dialogueWatch.ticksLeft <= 0 then
            reports.dialogue = "Talk-to: no new interface opened within " .. DIALOGUE_WATCH_TICKS .. " ticks."
            dialogueWatch = nil
        end
        return
    end
    table.sort(opened)
    if #opened > DIALOGUE_MAX_NEW then
        -- The whole interface came back (end of a cutscene, a teleport):
        -- not a conversation. Keep watching for the real one.
        dialogueWatch.baseline = Probe.LoadedSet()
        Diag.Note("ignored " .. #opened .. " interfaces opening at once (UI reload, not a conversation)")
        return
    end
    local parts = {}
    for _, interfaceID in ipairs(opened) do
        local texts = Probe.TextsIn(interfaceID, {}) or {}
        local sample = {}
        for i = 1, math.min(#texts, 6) do sample[#sample + 1] = View.Escape(texts[i].text) end
        parts[#parts + 1] = Probe.InterfaceName(interfaceID) .. ": " .. table.concat(sample, " | ")
        -- Only a window with numbered options ("1.") or the step's own option
        -- text: tooltips and other panels open during conversations too.
        local options = #Probe.Matches(texts, stepCandidates(currentEntry())) > 0
        for _, entry in ipairs(texts) do options = options or entry.text:match("^%s*%d+%.%s*$") ~= nil end
        if options then learnDialogInterface(interfaceID) end
    end
    reports.dialogue = "Conversation opened " .. table.concat(parts, "<br>")
    Diag.Note(reports.dialogue)
    dialogueWatch = nil
end

-- Turn the current step's options blue wherever a conversation was seen.
-- Only text labels are recoloured: a match can also be the option's button,
-- and colouring a button tints its background, which flashed a blue box
-- over the option. The recording notes any matches skipped that way.
local function updateOptionMarks()
    local candidates = stepCandidates(currentEntry())
    if #candidates == 0 or #dialogInterfaces == 0 then
        Recorder.AddIfChanged("optionmarks", "")
        Card.MarkOptions({})
        return
    end
    local texts, own = {}, ownInterfaces()
    for _, interfaceID in ipairs(dialogInterfaces) do
        if not own[interfaceID] then Probe.TextsIn(interfaceID, texts) end
    end
    local targets, marked, skipped = {}, {}, {}
    for _, match in ipairs(Probe.Matches(texts, candidates)) do
        if Probe.IsLabel(match.component) then
            targets[#targets + 1] = match.component
            marked[#marked + 1] = match.text
        else
            skipped[#skipped + 1] = match.text .. " (" .. Probe.TypeName(match.component) .. ")"
        end
    end
    Recorder.AddIfChanged("optionmarks", table.concat(marked, " | "),
        #skipped > 0 and ("not recoloured: " .. table.concat(skipped, " | ")) or nil)
    Card.MarkOptions(targets)
end

-- Outline the backpack items the current step uses. The backpack's
-- interface is found by scanning everything once (throttled) for icons of
-- items we know are in it, then only that interface is checked.
local function updateItemMarks()
    local quest, entry = currentQuest(), currentEntry()
    if quest == nil or entry == nil or backpack == nil then
        Card.MarkItems({})
        return
    end
    local wanted = {}
    for _, name in ipairs(stepTargets(quest, currentIndex()).items) do
        local need = { name = name }
        for have, objectID in pairs(backpackIDs) do
            if objectID and Advance.HaveCount({ [have] = 1 }, need) > 0 then wanted[objectID] = true end
        end
    end
    if next(wanted) == nil then
        Card.MarkItems({})
        return
    end
    local icons = {}
    for _, interfaceID in ipairs(backpackInterfaces) do Probe.ItemIconsIn(interfaceID, wanted, icons) end
    if #icons == 0 and backpackScanCooldown <= 0 then
        backpackScanCooldown = BACKPACK_SCAN_EVERY
        local own = ownInterfaces()
        for interfaceID in pairs(Probe.LoadedSet()) do
            if not own[interfaceID] then
                local before = #icons
                Probe.ItemIconsIn(interfaceID, wanted, icons)
                if #icons > before then backpackInterfaces[#backpackInterfaces + 1] = interfaceID end
            end
        end
        Diag.Snapshot("backpackInterfaces", table.concat(backpackInterfaces, ","))
    end
    backpackScanCooldown = backpackScanCooldown - 1
    local components = {}
    for _, icon in ipairs(icons) do components[#components + 1] = icon.component end
    Card.MarkItems(components)
end

-- ---------- moving through steps ----------

-- `why` is shown as the auto report; `source` says who moved the step for
-- the recording (defaults to "auto" with a why, "manual" without).
local function setStep(index, why, source)
    local quest = currentQuest()
    local list = flatSteps[questKey]
    if list == nil then return end
    local from = currentIndex()
    climbsDone = 0
    stepIndex[questKey] = math.max(1, math.min(index, #list + 1))
    PersistentDB:SetStructuredData(DB_STEPS, stepIndex)
    if why then reports.auto = string.format("Auto: step %d (%s)", stepIndex[questKey], why) end
    local targets = stepTargets(quest, currentIndex())
    local match, place = sceneryMatcher(currentEntry())
    World.SetTargets(targets.npcs, match, targets.nav, fallbackMatcher(quest, currentIndex()), place)
    local nav = targets.nav and (targets.nav.x .. "," .. targets.nav.y .. (targets.nav.rough and " rough" or "")) or "none"
    Diag.Snapshot("stepTargets", string.format("step %d npcs=%s items=%s nav=%s", currentIndex(),
        table.concat(targets.npcs, "|"), table.concat(targets.items, "|"), nav))
    if from ~= currentIndex() or source ~= nil then
        Recorder.Add("step", questKey, from, currentIndex(), why, source or (why and "auto" or "manual"))
    end
    Recorder.AddIfChanged("targets", questKey, currentIndex(), table.concat(targets.npcs, "|"),
        table.concat(targets.items, "|"), nav)
    updateOptionMarks()
    updateItemMarks()
    drawCard()
    refreshPanel()
end

local function openQuest(key)
    if screen ~= "guide" then panelState.listScroll = View.ScrollOffset() end
    questKey = key
    screen = "guide"
    lastVarValue = progressValue(questByKey[key])
    finishedSeen = questStatus(questByKey[key]) == "complete"
    PersistentDB:SetString(DB_QUEST, key)
    Recorder.Add("open", key, currentIndex(), questStatus(questByKey[key]), lastVarValue)
    -- Start at the top (status, items needed), not at the current step: the
    -- panel only scrolls to a step once it changes while the guide is open.
    focusedStep = key .. ":" .. currentIndex()
    View.ScrollToTop()
    setStep(currentIndex())
end

-- Back to step 1 with a clean progress log, for replaying a quest.
local function restartQuest(quest)
    stepIndex[quest.key] = nil
    varLog[quest.key] = nil
    for key in pairs(subDone) do
        if key:sub(1, #quest.key + 1) == quest.key .. ":" then subDone[key] = nil end
    end
    PersistentDB:SetStructuredData("subDone", subDone)
    PersistentDB:SetStructuredData(DB_VARLOG, varLog)
    lastVarValue = progressValue(quest)
    finishedSeen = questStatus(quest) == "complete"
    reports.auto = "Restarted from step 1."
    focusedStep = quest.key .. ":1"
    View.ScrollToTop()
    setStep(1, nil, "restart")
end
local restartPending = false -- Restart needs a second click to confirm

-- The tester saw something go wrong: mark the moment in the recording so
-- it can be found and replayed later.
local function flagProblem(how)
    if not Recorder.enabled then
        reports.auto = "Recording is off, so there's nothing to flag. Turn it on first."
    else
        Recorder.flags = Recorder.flags + 1
        Recorder.Add("flag", Recorder.flags, how, questKey, currentIndex())
        Recorder.Flush()
        reports.auto = string.format("Flagged problem #%d at step %d. Say what went wrong when you report back.",
            Recorder.flags, currentIndex())
    end
    refreshPanel()
end

-- Something was clicked in the game world or an interface.
-- "Search the crate", "Pull the lever": clicking the thing the step is
-- about finishes it, a few ticks later, unless the game says nothing
-- happened ("You find nothing", "The door is locked").
local pendingClick = nil -- { index, tick, subject }
local noteOwnClick -- defined below (needs acquireWants)

local function onInteraction(event)
    local entry = event.entry
    local verb = safe(function() return entry.verbText end) or ""
    local subject = safe(function() return entry.subjectText end) or ""
    local entryType = safe(function() return entry.actionEntryType end)
    reports.action = "Last action: " .. View.Escape(Advance.Clean(verb)) .. " | " ..
        View.Escape(Advance.Clean(subject)) .. " (type " .. tostring(entryType) .. ")"

    if MiniMenuEntryType ~= nil and entryType == MiniMenuEntryType.INTERFACE then
        -- Possibly a dialogue option: note which interface it came from.
        local interfaceID = safe(function() return entry.ComponentData.component.interfaceID end)
            or safe(function() return entry.ComponentData.interfaceID end)
        reports.action = reports.action .. " in " .. (interfaceID and Probe.InterfaceName(interfaceID) or "?")
        Recorder.Add("click", verb, subject, entryType, interfaceID)
        return
    end
    -- Other players' names stay out of the recording.
    local isPlayer = MiniMenuEntryType ~= nil and entryType == MiniMenuEntryType.PLAYER
    Recorder.Add("click", verb, isPlayer and "(a player)" or subject, entryType)
    if Advance.Clean(verb):find("talk", 1, true) then startDialogueWatch() end

    local quest = currentQuest()
    if quest == nil or not pref("auto", true) then return end
    -- "Enter the manor": going through a door or gate is the step (not
    -- "Enter the cave and talk to Claus").
    local cleanSubject = Advance.Clean(subject)
    if currentEntry() ~= nil and Advance.IsEnterStep(currentEntry().step) and Advance.MainAction(currentEntry().step) == nil
        and (cleanSubject:find("door") or cleanSubject:find("gate")) then
        setStep(currentIndex() + 1, "went through the " .. cleanSubject)
        return
    end
    -- Make sure the steps around know their borrowed NPCs before matching.
    for i = math.max(1, currentIndex() - Advance.LOOKBACK), math.min(#flatSteps[quest.key], currentIndex() + Advance.LOOKAHEAD) do
        stepTargets(quest, i)
    end
    local index = Advance.MatchInteraction(flatSteps[quest.key], currentIndex(), verb, subject)
    if index ~= nil and index > currentIndex() then
        setStep(index, "you used " .. Advance.Clean(subject))
        return
    end
    if MiniMenuEntryType ~= nil and entryType == MiniMenuEntryType.LOC then
        noteOwnClick(quest, Advance.Clean(verb), cleanSubject)
    end
end

-- The quest's progress var rose: the step being done is finished. (Seen in
-- testing: Goblin Diplomacy's var moves exactly on its dialogue/use steps.)
local function onVarChange(quest, oldValue, newValue)
    local entries = varLog[quest.key] or {}
    entries[#entries + 1] = string.format("step %d: %s -> %s", currentIndex(), tostring(oldValue), tostring(newValue))
    while #entries > VAR_LOG_MAX do table.remove(entries, 1) end
    varLog[quest.key] = entries
    PersistentDB:SetStructuredData(DB_VARLOG, varLog)
    if not Edition.release then log("[rs3qb] " .. quest.name .. " progress " .. entries[#entries]) end
    local rose = type(newValue) == "number" and type(oldValue) == "number" and newValue > oldValue
    -- The backpack already moved the step; the var moving a tick later is
    -- the same event (Thurgo taking the pie, cutting the key out of the
    -- book), not the next step.
    local sameEvent = serverTick - lastItemStep <= ITEM_VAR_TICKS
    if pref("auto", true) and rose and not sameEvent and currentIndex() <= #flatSteps[quest.key] then
        setStep(currentIndex() + 1, "quest progress moved")
    end
end

-- What an acquire step wants in the backpack: items its own words name
-- ("buy a beer"), linked items, and quest items it mentions.
local function acquireWants(quest, entry)
    if not Advance.IsAcquireStep(entry.step) then return {} end
    local wants = acquireTargets(quest, entry.step)
    for _, need in ipairs(Advance.ItemsMentioned(entry.step, neededParsed(quest))) do wants[#wants + 1] = need end
    for _, page in ipairs(entry.step.npcs or {}) do
        if (pages[page:lower()] or {}).kind == "item" then wants[#wants + 1] = Advance.ParseNeeded(page) end
    end
    return wants
end

-- Have the backpack items this acquire step asks for all arrived?
local function acquireDone(quest, entry)
    if backpack == nil then return false end
    local wants = acquireWants(quest, entry)
    if #wants == 0 then return false end
    for _, need in ipairs(wants) do
        if Advance.HaveCount(backpack, need) < (need.qty or 1) then return false end
    end
    return true
end

-- A make step ("Dye one goblin mail blue and another orange") is done once
-- the backpack holds what the next steps go on to use.
local function makeDone(quest, index)
    local produced = producedItems(quest, index)
    if #produced == 0 then return false end
    for _, name in ipairs(produced) do
        if Advance.HaveCount(backpack, { name = name }) == 0 then return false end
    end
    return true
end

-- Backpack changed: refresh item checks; finish obtain/make steps.
-- "bones=1;goblin mail=3", sorted, for the recording.
local function bagText(counts)
    if counts == nil then return "unreadable" end
    local parts = {}
    for name, count in pairs(counts) do parts[#parts + 1] = name .. "=" .. count end
    table.sort(parts)
    if bagState.free ~= nil then parts[#parts + 1] = "free=" .. bagState.free end
    return table.concat(parts, ";")
end

-- "Talk to Thurgo with the materials", "Give Thurgo the portrait": the
-- step is done when the items it needs leave the backpack.
local HANDOVER_VERBS = { talk = true, give = true, use = true, bring = true, show = true, hand = true,
    deliver = true, report = true, ["return"] = true }

local function handedOver(quest, entry, before)
    if not HANDOVER_VERBS[entry.step.text:lower():match("^%s*(%a+)") or ""] then return nil end
    for _, item in ipairs(stepItems(quest, entry)) do
        if not item.recommended then
            local had, has = Advance.HaveCount(before, item.need), Advance.HaveCount(backpack, item.need)
            if had > 0 and has < had then return item.need.name end
        end
    end
    return nil
end

-- Did any of `wants` (parsed items) go up since `before`?
local function gained(before, wants)
    for _, need in ipairs(wants) do
        if Advance.HaveCount(backpack, need) > Advance.HaveCount(before, need) then return true end
    end
    return false
end

-- Backpack changed: refresh item checks; finish steps that were about items:
--   * hand-over steps whose items left the backpack
--   * obtain/make steps whose items arrived (also a step or two ahead:
--     mining the ore while the guide still says "follow the dungeon")
--   * a step whose new item the next step uses (searching the cupboard
--     gives the portrait that "Give Thurgo the portrait" wants)
local function onBackpackChange()
    local before = backpack
    backpack = readBackpack()
    Recorder.AddIfChanged("bag", bagText(backpack))
    local quest, entry = currentQuest(), currentEntry()
    if pref("auto", true) and quest ~= nil and entry ~= nil and backpack ~= nil then
        local list = flatSteps[quest.key]
        local function itemStep(index, why)
            lastItemStep = serverTick
            setStep(index, why)
        end
        local handed = before ~= nil and handedOver(quest, entry, before)
        if handed then
            itemStep(currentIndex() + 1, "handed over the " .. handed)
            return
        end
        if Advance.IsAcquireStep(entry.step) and acquireDone(quest, entry) then
            itemStep(currentIndex() + 1, "got the items")
            return
        end
        if Advance.IsMakeStep(entry.step) and makeDone(quest, currentIndex()) then
            itemStep(currentIndex() + 1, "made the items")
            return
        end
        if before ~= nil then
            for i = currentIndex() + 1, math.min(#list, currentIndex() + 2) do
                local later = list[i]
                if Advance.IsAcquireStep(later.step) and gained(before, acquireWants(quest, later))
                    and acquireDone(quest, later) then
                    itemStep(i + 1, "got the items")
                    return
                end
            end
            local nextEntry = list[currentIndex() + 1]
            if nextEntry ~= nil and #stepTargets(quest, currentIndex()).npcs == 0
                and not Advance.IsTravelStep(entry.step) then
                for name, count in pairs(backpack) do
                    if count > 0 and (before[name] or 0) == 0 and Advance.Mentions(nextEntry.step.text, name) then
                        itemStep(currentIndex() + 1, "got the " .. name)
                        return
                    end
                end
            end
        end
    end
    updateItemMarks()
    drawCard()
end

-- Where the player was last tick, to notice stairs/ladders (a level change
-- or a big jump, e.g. into a basement area).
local lastPlayerSpot = nil
-- Is this click the current step's own thing to do? The step's main action
-- is a click verb, it isn't waiting for an item or using one, and the
-- object is one the step outlines (so "Search the crate" on a crate, not on
-- the chest beside it).
local function ownClickStep(quest, entry)
    local step = entry.step
    local action = Advance.MainAction(step)
    if action == nil or not Advance.CLICK_VERBS[action] then return false end
    if Advance.IsUseStep(step) or Advance.IsMakeStep(step) or #acquireWants(quest, entry) > 0 then return false end
    -- "With thread and leather, fix the bellows": the click only works with
    -- the items in the bag, and the step is finished by the game, not the
    -- click. And without chat access the "You need..." line that would
    -- cancel the click never arrives, so don't guess.
    if #stepTargets(quest, entry.index).items > 0 then return false end
    if not Plugin.HasPermission(PluginPermissions.chatAccess) then return false end
    -- "Search the cupboard" with "Give Thurgo the portrait" next: the
    -- portrait turning up finishes it (onBackpackChange), not the click. So
    -- for any next step that hands over or uses something.
    local nextEntry = flatSteps[quest.key][entry.index + 1]
    if nextEntry ~= nil then
        local first = nextEntry.step.text:lower():match("^%s*(%a+)") or ""
        if (HANDOVER_VERBS[first] and first ~= "talk") or Advance.IsUseStep(nextEntry.step)
            or #stepTargets(quest, entry.index + 1).items > 0 then
            return false
        end
    end
    return #Advance.ItemsMentioned(step, neededParsed(quest)) == 0 and #producedItems(quest, entry.index) == 0
end

noteOwnClick = function(quest, verb, subject)
    local entry = currentEntry()
    if entry == nil or verb == "use" or verb == "examine" or verb == "walk here" then return end
    if not ownClickStep(quest, entry) then return end
    local match = sceneryMatcher(entry)
    if match == nil then return end
    local here = World.playerTile or { x = 0, z = 0 }
    local ok, hit = pcall(match, { displayName = subject, config = { opNames = { verb } },
        position = { x = here.x * 512, y = 0, z = here.z * 512 } })
    if ok and hit then pendingClick = { index = currentIndex(), tick = serverTick, subject = subject } end
end

-- A few ticks after such a click, with no "nothing happens" line and the
-- step still the same (the quest var may have moved it already), move on.
local function checkPendingClick()
    if pendingClick == nil then return end
    if currentQuest() == nil or pendingClick.index ~= currentIndex() then
        pendingClick = nil
        return
    end
    if serverTick - pendingClick.tick < TUNE.clickSettle then return end
    local subject = pendingClick.subject
    pendingClick = nil
    if pref("auto", true) then
        lastItemStep = serverTick -- the quest var moving right after is the same event
        setStep(currentIndex() + 1, "you clicked the " .. subject)
    end
end

local CLIMB_JUMP_TILES = 20
local FOUND_DISTANCE = 8 -- tiles from what an "until ... seen" step looks for

local function playerSpot()
    return safe(function()
        local player = Player.GetEntity()
        return { x = player.position.x / 512, z = player.position.z / 512,
            level = safe(function() return player.coordGrid.level end) or 0 }
    end)
end

-- Per-tick checks that finish the current step from where the player is:
--   * travel steps on arrival (unless the step also says to get something,
--     like "Go upstairs ... to get a garlic": then the garlic decides, or
--     to do something there, like "... and talk to Robin")
--   * stairs/ladder steps on a level change or a big jump (when climbing
--     is the step's job, not just the way to it)
--   * acquire steps whose items are already in the backpack
local function checkPosition()
    local spot, previous = playerSpot(), lastPlayerSpot
    lastPlayerSpot = spot
    local quest, entry = currentQuest(), currentEntry()
    if quest == nil or entry == nil or not pref("auto", true) then return end
    local step = entry.step
    local waitsForItems = #acquireWants(quest, entry) > 0
    if waitsForItems then
        if acquireDone(quest, entry) then setStep(currentIndex() + 1, "already have the items") end
        return
    end
    if Advance.ClimbDirection(step) ~= nil and spot ~= nil and previous ~= nil then
        local moved = math.sqrt((spot.x - previous.x) ^ 2 + (spot.z - previous.z) ^ 2)
        if spot.level ~= previous.level or moved > CLIMB_JUMP_TILES then
            -- "Climb the ladder, then the first staircase": one climb per goal.
            climbsDone = climbsDone + 1
            local needed = math.max(1, #Advance.ClimbGoals(step))
            if climbsDone < needed then
                reports.auto = string.format("Auto: climb %d of %d done", climbsDone, needed)
                Recorder.Add("climb", climbsDone, needed)
                return
            end
            -- "Go upstairs and talk to Doris": the stairs were only the way there.
            if not Advance.ClimbFinishes(step) then
                Recorder.Add("climb", climbsDone, needed)
                return
            end
            local direction = Advance.ClimbDirection(step)
            setStep(currentIndex() + 1, "took the " .. (step.text:lower():match("(stair%a*)") or "way") ..
                (direction ~= "any" and (" " .. direction) or ""))
            return
        end
    end
    if Advance.IsUntilStep(step) then
        local distance = World.NearestMarkedDistance()
        if distance ~= nil and distance <= FOUND_DISTANCE then
            setStep(currentIndex() + 1, "found it")
            return
        end
    end
    -- Not "Go to the inn and talk to Robin": the talk (or quest progress) does.
    if Advance.TravelFinishes(step) then
        local nav = stepTargets(quest, currentIndex()).nav
        local distance = nav and World.DistanceTo(nav)
        local near = nav and nav.rough and TUNE.arrivedRough or ARRIVED_DISTANCE
        if distance ~= nil and distance <= near then setStep(currentIndex() + 1, "arrived") end
    end
end

-- ---------- panel rows ----------

local function setPref(name, value)
    prefs[name] = value
    PersistentDB:SetStructuredData(DB_PREFS, prefs)
end

-- Walking guidance (dots, the tile marker, teleport hints), as set, and
-- only in a build that has it (see edition.lua).
local function guidance(name) return Edition.guidance and pref(name, true) end
local function applyGuidance()
    Card.SetSize(pref("cardSize", "medium"))
    World.pathEnabled = guidance("path")
    World.beaconEnabled = guidance("beacon")
    World.dotSize = DOT_SIZES[pref("dots", "medium")] or DOT_SIZES.medium
end

local CREDITS = "Quest guides from the RuneScape Wiki (runescape.wiki), CC BY-NC-SA 3.0. " ..
    "Not made or endorsed by Jagex."
local settingsFrom = "list" -- the screen Settings goes back to

local function settingsButton()
    return { label = "Settings", press = function()
        settingsFrom = screen
        screen = "settings"
        View.ScrollToTop()
        refreshPanel()
    end }
end

-- "Card: on" that flips a saved setting, then runs `after`.
local function toggle(label, name, default, after)
    return { label = label .. ": " .. onOff(pref(name, default)), press = function()
        setPref(name, not pref(name, default))
        if after then after() end
        refreshPanel()
    end }
end

local function settingsRows()
    local rows = {
        { kind = "buttons", buttons = { { label = "Back", press = function()
            screen = settingsFrom
            View.ScrollToTop()
            refreshPanel()
        end } } },
        { kind = "title", text = "Settings" },
        { kind = "heading", text = "Guide" },
        { kind = "buttons", buttons = {
            toggle("Card", "card", true, drawCard),
            toggle("Auto", "auto", true),
        } },
        { kind = "buttons", buttons = {
            { label = "Card detail: " .. pref("cardDetail", "full"), press = function()
                setPref("cardDetail", pref("cardDetail", "full") == "full" and "compact" or "full")
                drawCard()
                refreshPanel()
            end },
            { label = "Card size: " .. pref("cardSize", "medium"), press = function()
                setPref("cardSize", LIST.nextCardSize[pref("cardSize", "medium")] or "medium")
                Card.SetSize(pref("cardSize", "medium"))
                drawCard()
                refreshPanel()
            end },
        } },
        { kind = "text", colour = "muted", text = "Card: the current step on the game screen. Auto: move on " ..
            "by itself when you do a step (talk, pick up, climb, arrive). \"Done, next\" always works. " ..
            "Card detail: compact keeps the instruction, chat and missing items; notes and owned items stay in the " ..
            "panel. Card size: a share of the screen width." },
    }
    if Edition.guidance then
        rows[#rows + 1] = { kind = "heading", text = "Finding the way" }
        rows[#rows + 1] = { kind = "buttons", buttons = {
            toggle("Path", "path", true, applyGuidance),
            { label = "Dots: " .. pref("dots", "medium"), press = function()
                setPref("dots", NEXT_DOT_SIZE[pref("dots", "medium")] or "medium")
                applyGuidance()
                Recorder.Add("dots", pref("dots", "medium"))
                refreshPanel()
            end },
        } }
        rows[#rows + 1] = { kind = "buttons", buttons = {
            toggle("Marker", "beacon", true, applyGuidance),
            toggle("Teleport hints", "teleport", true),
        } }
        rows[#rows + 1] = { kind = "text", colour = "muted", text = "Path: dots on the ground towards the next " ..
            "place. Marker: a gold square on the step's map tile. Teleport hints: which lodestone gets you closer." }
    end
    rows[#rows + 1] = { kind = "heading", text = "Bug reports" }
    local reportButtons = { { label = "Recording: " .. onOff(Recorder.enabled), press = function()
        setPref("record", not Recorder.enabled)
        Recorder.SetEnabled(pref("record", Edition.recordByDefault))
        refreshPanel()
    end } }
    if Recorder.enabled then
        reportButtons[#reportButtons + 1] = { label = "Flag a problem (Alt+F)", press = function() flagProblem("button") end }
    end
    rows[#rows + 1] = { kind = "buttons", buttons = reportButtons }
    rows[#rows + 1] = { kind = "text", colour = "muted", text = "Recording keeps a log of your last few sessions " ..
        "in this plugin's own storage on your device: where you walk, your backpack, what you click, quest " ..
        "progress and the text of conversations (never players' chat or names). Nothing is sent anywhere. " ..
        "It lets a problem be replayed if you send it in." }
    rows[#rows + 1] = { kind = "heading", text = "About" }
    rows[#rows + 1] = { kind = "text", colour = "muted", text = CREDITS }
    return rows
end

local function listRows()
    local rows = {
        { kind = "buttons", buttons = { settingsButton() } },
        { kind = "title", text = Edition.name or "RS3 Quest Buddy" },
        { kind = "text", text = string.format("%d quests and miniquests. Pick one to start.", #Quests), colour = "muted" },
        { kind = "text", text = CREDITS, colour = "muted" },
        { kind = "spacer" },
    }
    -- Filter by status, and jump to a first letter.
    local filter = pref("listFilter", "all")
    local filterButtons = {}
    for _, name in ipairs(LIST.filters) do
        filterButtons[#filterButtons + 1] = { label = (filter == name and "> " or "") .. LIST.labels[name],
            press = function()
                setPref("listFilter", name)
                View.ScrollToTop()
                refreshPanel()
            end }
    end
    rows[#rows + 1] = { kind = "buttons", buttons = filterButtons }
    local groupRow = {}
    local jumpButtons = {}
    for _, group in ipairs(LIST.groups) do
        jumpButtons[#jumpButtons + 1] = { label = group[1], press = function()
            if groupRow[group[1]] then View.ScrollToRow(groupRow[group[1]]) end
        end }
    end
    rows[#rows + 1] = { kind = "buttons", buttons = jumpButtons }
    -- The ones you're doing first, then the rest A to Z, finished ones last.
    local order = { started = 1, complete = 3 }
    local sorted = {}
    for i, quest in ipairs(Quests) do sorted[i] = { quest = quest, rank = order[questStatus(quest)] or 2, at = i } end
    table.sort(sorted, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.at < b.at
    end)
    local shown = 0
    for _, item in ipairs(sorted) do
        local quest = item.quest
        local status = questStatus(quest)
        local list = flatSteps[quest.key]
        local done = math.min((math.tointeger(stepIndex[quest.key] or 1) or 1) - 1, #list)
        -- "Started": by the game, or steps ticked here.
        local started = status == "started" or (done > 0 and status ~= "complete")
        local wanted = filter == "all" or (filter == "started" and started)
            or (filter == "done" and status == "complete")
            or (filter == "todo" and not started and status ~= "complete")
        if wanted then
            local look = STATUS_LOOK[status] or { status, "muted" }
            local label = look[1]
            if done > 0 and look[1] ~= "Done" then label = string.format("%s  %d/%d", look[1], done, #list) end
            rows[#rows + 1] = { kind = "quest", name = quest.name, status = label, statusColour = look[2],
                press = function() openQuest(quest.key) end }
            shown = shown + 1
            -- The first A to Z row of each letter group, for the jump buttons.
            local first = quest.name:sub(1, 1):upper()
            for _, group in ipairs(LIST.groups) do
                if item.rank == 2 and groupRow[group[1]] == nil and first >= group[2] and first <= group[3] then
                    groupRow[group[1]] = #rows
                end
            end
        end
    end
    if shown == 0 then rows[#rows + 1] = { kind = "text", text = "No quests match this filter.", colour = "muted" } end
    return rows
end

-- What the test build's devtools.lua gets to work with.
local devApp = {
    reports = reports, varLog = varLog, questInfo = questInfo, currentQuest = currentQuest,
    questTypeFor = questTypeFor, windowSizeEvents = 0,
    currentEntry = currentEntry, stepCandidates = stepCandidates, ownInterfaces = ownInterfaces,
    learnDialogInterface = learnDialogInterface, updateOptionMarks = updateOptionMarks,
    refreshPanel = function() refreshPanel() end,
}

local function guideRows()
    local quest = currentQuest()
    local list = flatSteps[quest.key]
    local current = currentIndex()
    local rows = {
        { kind = "buttons", buttons = {
            { label = "Quest list", press = function()
                screen = "list"
                refreshPanel()
                View.ScrollTo(panelState.listScroll) -- back where the list was
            end },
            settingsButton(),
            { label = "Current step", press = function() View.ScrollToAnchor() end },
        } },
        { kind = "title", text = quest.name },
    }
    local look = STATUS_LOOK[questStatus(quest)] or { questStatus(quest), "muted" }
    rows[#rows + 1] = { kind = "text", text = look[1], colour = look[2] }
    rows[#rows + 1] = { kind = "progress", done = math.min(current - 1, #list), total = #list }

    -- Items first, like the Alt1 app: the guide's per-section lists plus the
    -- quest page's required list, minus anything already used up, checked
    -- against the backpack; recommended items underneath.
    local showInfo = pref("itemInfo", false)
    local showOverview = pref("overview", true)
    local wanted = overviewItems(quest, questItems(quest), current)
    local seenItems = {}
    for _, entry in ipairs(questItems(quest)) do
        for _, item in ipairs(Advance.SplitNeeded(entry)) do seenItems[Advance.ParseNeeded(item).name] = true end
    end
    for _, line in ipairs(quest.required or {}) do
        local firstItem = (line:match("^(.-)%s*%(") or line:match("^(.-)%s+or%s") or line):gsub("^an?%s+", "")
        local need = Advance.ParseNeeded(firstItem)
        if not line:match("^OR%s") and not seenItems[need.name] then
            seenItems[need.name] = true
            -- "Beer or 2 coins to purchase a pint": either counts (the hints
            -- under a missing line still follow the first item).
            local either = line:find("%s+or%s+") and Advance.ParseNeeded((line:gsub("%s*%b()", ""))) or nil
            local qty = stillNeeded(quest, need, current)
            if qty ~= nil then wanted[#wanted + 1] = { label = line, need = need, either = either, qty = qty } end
        end
    end
    local items = itemBlocks(wanted, 0, showInfo)
    local overviewButtons = { { label = showOverview and "Hide overview" or "Show overview", press = function()
        setPref("overview", not showOverview)
        refreshPanel()
    end } }
    overviewButtons[#overviewButtons + 1] = { label = "Ironman: " .. onOff(pref("ironman", false)), press = function()
        setPref("ironman", not pref("ironman", false))
        Recorder.Add("ironman", onOff(pref("ironman", false)))
        drawCard()
        refreshPanel()
    end }
    if showOverview and #items > 0 then
        overviewButtons[#overviewButtons + 1] = { label = showInfo and "Hide descriptions" or "Item descriptions", press = function()
            setPref("itemInfo", not showInfo)
            refreshPanel()
        end }
    end
    rows[#rows + 1] = { kind = "buttons", buttons = overviewButtons }
    local requirements = showOverview and requirementBlocks(quest) or {}
    if #requirements > 0 then
        rows[#rows + 1] = { kind = "heading", text = "Requirements" }
        rows[#rows + 1] = { kind = "blocks", blocks = requirements }
    end
    if showOverview and #items > 0 then
        rows[#rows + 1] = { kind = "heading", text = "Items needed" }
        rows[#rows + 1] = { kind = "blocks", blocks = items }
    end
    if showOverview and #(quest.recommended or {}) > 0 then
        local recommended = {}
        for i, line in ipairs(quest.recommended) do recommended[i] = "- " .. View.Escape(line) end
        rows[#rows + 1] = { kind = "heading", text = "Recommended" }
        rows[#rows + 1] = { kind = "text", text = table.concat(recommended, "<br>"), colour = "muted" }
    end

    -- Every step, like the Alt1 app's list; the panel scrolls to the
    -- current one when it changes.
    local lastSection = nil
    for i = 1, #list do
        local entry = list[i]
        if entry.section ~= lastSection then
            rows[#rows + 1] = { kind = "heading", text = entry.section.title }
            lastSection = entry.section
        end
        rows[#rows + 1] = { kind = "step", blocks = stepBlocks(quest, entry, false, i < current),
            state = i < current and "done" or (i == current and "current" or "todo"),
            anchor = (i == current) or (current > #list and i == #list),
            toggle = function(ticked) setStep(ticked and i + 1 or i, nil, "checkbox") end }
    end
    if current > #list then
        rows[#rows + 1] = { kind = "text", text = "All steps done.", colour = "green" }
    end
    rows[#rows + 1] = { kind = "buttons", buttons = {
        { label = "Back", press = function() setStep(current - 1, nil, "back button") end },
        { label = "Done, next", style = "primary", press = function() setStep(current + 1, nil, "done button") end },
    } }
    if reports.auto ~= "" then rows[#rows + 1] = { kind = "text", text = reports.auto, colour = "muted" } end

    rows[#rows + 1] = { kind = "spacer", height = 8 }
    rows[#rows + 1] = { kind = "buttons", buttons = {
        { label = "Mark complete", press = function()
            restartPending = false
            setStep(#list + 1, "marked complete", "mark complete button")
        end },
        { label = restartPending and "Click again to restart" or "Restart quest", press = function()
            if restartPending then
                restartPending = false
                restartQuest(quest)
            else
                restartPending = true
                refreshPanel()
            end
        end },
    } }
    local extra = {}
    if Recorder.enabled then
        extra[#extra + 1] = { label = "Flag a problem (Alt+F)", press = function() flagProblem("button") end }
    end
    if DevTools then
        extra[#extra + 1] = { label = pref("debug", false) and "Hide debug" or "Show debug", press = function()
            restartPending = false
            setPref("debug", not pref("debug", false))
            refreshPanel()
        end }
    end
    if #extra > 0 then rows[#rows + 1] = { kind = "buttons", buttons = extra } end
    if DevTools and pref("debug", false) then
        for _, row in ipairs(DevTools.Rows(devApp, quest)) do rows[#rows + 1] = row end
    end
    return rows
end

buildRows = function()
    if screen == "settings" then return settingsRows() end
    if screen == "guide" and currentQuest() ~= nil then return guideRows() end
    return listRows()
end

-- The game clears the layer right before this fires, so build from scratch.
Event.ContentLayerReady.Subscribe("rs3qb-panel", function(event)
    panelRoot, panelBody, panelSignature = event.component, nil, nil
    -- Resizing the panel changes where text wraps: redraw once it settles.
    pcall(function()
        panelRoot:Subscribe(ui.Hook.ONRESIZE, "rs3qb-resize", function() panelState.resizedAt = serverTick end)
    end)
    -- Drop any learned "dialogue" interface that is really our own panel.
    for i = #dialogInterfaces, 1, -1 do
        if ownInterfaces()[dialogInterfaces[i]] then table.remove(dialogInterfaces, i) end
    end
    refreshPanel()
end)

-- ---------- events ----------

local lastMarkedSaved = nil -- what World marked, as last written to diagnostics

-- Cutscenes: the API has no flag for them, but the game unloads nearly all
-- of its interface (minimap, action bar, chat) while one plays. Compare the
-- number of loaded interfaces with its usual level and hide our overlays
-- when it collapses.
local CUTSCENE_RATIO = 0.5
local interfaceBaseline = nil
local inCutscene = false

local function checkCutscene()
    local count = 0
    for _ in pairs(Probe.LoadedSet()) do count = count + 1 end
    interfaceBaseline = interfaceBaseline or count
    local now = count < interfaceBaseline * CUTSCENE_RATIO
    if not now then interfaceBaseline = interfaceBaseline * 0.9 + count * 0.1 end
    if now ~= inCutscene then
        inCutscene = now
        lastPlayerSpot = nil -- the player is moved around during cutscenes
        World.SetHidden(now)
        Card.SetHidden(now)
        Recorder.Add("cutscene", now and "on" or "off", count, math.floor(interfaceBaseline))
        Diag.Note(string.format("cutscene %s (%d interfaces loaded, usually %d)",
            now and "started" or "ended", count, math.floor(interfaceBaseline)))
    end
end

-- What the recording samples each tick: where the player is (after moving
-- a couple of tiles, or a smaller move once they stop), quest statuses, and
-- (recordDialogue) the text of any conversation on screen.
local POS_MIN_TILES = 2
local recordedSpot, recordedSpotTick, recordTicks = nil, 0, 0
local recordedStatus = {}

local function recordTick()
    if not Recorder.enabled then return end
    recordTicks = recordTicks + 1
    local spot = playerSpot()
    if spot ~= nil then
        local last = recordedSpot
        local far = last == nil or spot.level ~= last.level
            or math.abs(spot.x - last.x) + math.abs(spot.z - last.z) >= POS_MIN_TILES
        local settled = last ~= nil and (spot.x ~= last.x or spot.z ~= last.z) and recordTicks - recordedSpotTick >= 3
        if far or settled then
            recordedSpot, recordedSpotTick = spot, recordTicks
            Recorder.Add("pos", string.format("%.1f", spot.x), string.format("%.1f", spot.z), spot.level)
        end
    end
    -- Just the open quest: reading all ~370 every tick is wasted work.
    local quest = currentQuest()
    if quest ~= nil then
        local status = questStatus(quest)
        if status ~= recordedStatus[quest.key] then
            recordedStatus[quest.key] = status
            Recorder.Add("status", quest.key, status)
        end
    end
end

-- Runs after the tick's own checks, so a conversation learned this tick is
-- already included.
local function recordDialogue()
    if Recorder.enabled and #dialogInterfaces > 0 then
        local texts, own, shown = {}, ownInterfaces(), {}
        for _, interfaceID in ipairs(dialogInterfaces) do
            if not own[interfaceID] then Probe.TextsIn(interfaceID, texts) end
        end
        for i = 1, math.min(#texts, 12) do shown[i] = texts[i].text:sub(1, 120) end
        Recorder.AddIfChanged("dialog", table.concat(shown, " | "))
    end
end

-- The open quest's progress var, so the recording has the exact moments
-- the game moved it along.
local recordedVars = {}
local function recordVars()
    if not Recorder.enabled then return end
    local quest = currentQuest()
    if quest ~= nil then
        local value = progressValue(quest)
        if value ~= recordedVars[quest.key] then
            Recorder.Add("var", quest.key, recordedVars[quest.key], value)
            recordedVars[quest.key] = value
        end
    end
end

-- Far from the next place: suggest a lodestone (on the card and under the
-- player's feet) instead of a path of dots that would run off the screen.
local function updateTravelHint()
    local quest, entry = currentQuest(), currentEntry()
    local hint = nil
    if quest ~= nil and entry ~= nil and not inCutscene then
        local nav = stepTargets(quest, currentIndex()).nav
        local spot = playerSpot()
        -- "Teleport to the laboratories via Drakan's medallion": the step's
        -- own teleport, not a lodestone; the dots take over once close.
        local own = Advance.NamedTeleport(entry.step.text)
        if own ~= nil then
            local distance = nav ~= nil and spot ~= nil and math.sqrt((spot.x - nav.x) ^ 2 + (spot.z - nav.y) ^ 2) or nil
            hint = { name = own, own = true, far = distance == nil or distance > TUNE.ownTeleportFar }
        elseif nav ~= nil and spot ~= nil and guidance("teleport") then
            hint = Travel.Suggest(spot.x, spot.z, nav.x, nav.y)
        end
    end
    local suppress = hint ~= nil and (not hint.own or hint.far)
    if (hint and hint.name) == (travelHint and travelHint.name) then
        travelHint = hint -- same hint; the walking distance may have changed
        World.pathSuppressed = suppress
        return
    end
    travelHint = hint
    World.pathSuppressed = suppress
    Card.SetFloating(hint and (hint.own and ("Teleport: " .. hint.name) or ("Teleport to " .. hint.name .. " lodestone")) or nil)
    Recorder.Add("hint", hint and hint.name or "")
    drawCard()
end

Event.ServerLogic.Subscribe("rs3qb-tick", function()
    serverTick = serverTick + 1
    Recorder.Tick()
    Diag.Guard("record", recordTick)
    Diag.Guard("tick", function()
        checkCutscene()
        updateTravelHint() -- first: it decides whether World draws a path
        World.Update()
        if serverTick % WALL_STATS_EVERY == 0 and World.wallStats ~= "" then
            Recorder.AddIfChanged("walls", World.wallStats)
        end
        local info = World.pathInfo
        Recorder.AddIfChanged("nav", travelHint and ("teleport " .. travelHint.name) or (info and
            ("dots to " .. info.target .. (info.walkable and (info.detour and ", around obstacles" or ", walkable")
                or ", straight line"))) or "none")
        if not Card.IsShown() then drawCard() end
        checkDialogueWatch()
        updateOptionMarks()
        updateItemMarks()
        if not inCutscene then checkPosition() end
        checkPendingClick()
        if World.lastMarked ~= lastMarkedSaved then
            lastMarkedSaved = World.lastMarked
            Diag.Snapshot("marked", World.lastMarked)
            Recorder.Add("marked", World.lastMarked)
        end

        -- Quest finished in game: jump to the end.
        local quest = currentQuest()
        if quest ~= nil and not finishedSeen and questStatus(quest) == "complete" then
            finishedSeen = true
            if pref("auto", true) then setStep(#flatSteps[quest.key] + 1, "quest complete") end
        end
        -- In case ONRESIZE never fires: notice a changed width now and then.
        if panelState.resizedAt == nil and panelRoot ~= nil and serverTick % WALL_STATS_EVERY == 0
            and safe(function() return panelRoot.width end) ~= panelState.width then
            panelState.resizedAt = serverTick
        end
        if panelState.resizedAt ~= nil and serverTick - panelState.resizedAt >= TUNE.resizeSettle then
            panelState.resizedAt, panelSignature = nil, nil
        end
        refreshPanel() -- no-op unless something shown changed
    end)
    Diag.Guard("record dialogue", recordDialogue)
end)

-- The game window changed size: the card refits itself on the next tick.
Event.WindowSizeChanged.Subscribe("rs3qb-window", function()
    devApp.windowSizeEvents = devApp.windowSizeEvents + 1
    Diag.Guard("window", Card.OnWindowResized)
end)

Event.Logic.Subscribe("rs3qb-card", function()
    View.Tick()
    pcall(Card.Follow)
end)
Event.Draw.Subscribe("rs3qb-draw", function() World.Draw() end)
Event.MiniMenuEntrySelected.Subscribe("rs3qb-menu", function(event)
    Diag.Guard("interaction", onInteraction, event)
end)
Event.InventoryUpdated.Subscribe("rs3qb-inv", function() Diag.Guard("inventory", onBackpackChange) end)

-- Alt+D completes the current step while playing, for steps the plugin
-- can't detect on its own. Alt+F flags a problem in the recording.
Event.KeyDown.Subscribe("rs3qb-keys", function(event)
    Diag.Guard("hotkey", function()
        if event.isRepeat or GameKey == nil or ModifierKey == nil or currentQuest() == nil then return end
        if event.gameKey == GameKey.D and (event.modifiers & ModifierKey.ALT) ~= 0 then
            local entry = currentEntry()
            if entry ~= nil and isListStep(entry.step) and subsDone(entry) + 1 < #entry.step.subs then
                -- "Locations:" with three places: one place per press.
                subDone[tostring(questKey) .. ":" .. entry.index] = subsDone(entry) + 1
                PersistentDB:SetStructuredData("subDone", subDone)
                reports.auto = string.format("Alt+D: %d of %d done on this step", subsDone(entry), #entry.step.subs)
                drawCard()
                refreshPanel()
            else
                setStep(currentIndex() + 1, "Alt+D", "Alt+D")
            end
        elseif event.gameKey == GameKey.F and (event.modifiers & ModifierKey.ALT) ~= 0 then
            flagProblem("Alt+F")
        end
    end)
end)

Event.VarTransmit.Subscribe("rs3qb-var", function()
    Diag.Guard("record vars", recordVars)
    local quest = currentQuest()
    if quest == nil then return end
    local value = progressValue(quest)
    if value == nil or value == lastVarValue then return end
    local previous = lastVarValue
    lastVarValue = value
    if previous ~= nil then Diag.Guard("var change", onVarChange, quest, previous, value) end
end)

-- Optional: chat confirms quest completion and shows whether NPC lines
-- arrive as chat messages at all.
local chatSubscribed = false
local KILL_MESSAGES = { "you have slain", "you have defeated", "you have killed", "you defeated" }
-- Chat types worth recording: game messages, examines and NPC lines.
-- Players' own messages (public, private, clan, friends) are never kept.
local RECORDED_CHAT = { [0] = true, [4] = true, [27] = true, [28] = true, [29] = true, [116] = true, [145] = true }

local function onChat(event)
    local message = safe(function() return event.chatMessage end)
    if type(message) ~= "string" then return end
    local chatType = safe(function() return event.chatType end)
    if RECORDED_CHAT[chatType] then Recorder.Add("chat", chatType, message) end
    local lower = Advance.Clean(message)
    if ChatType ~= nil and safe(function() return event.chatType end) == ChatType.NPC_CHAT then
        reports.chat = "Last NPC chat line: " .. View.Escape(message)
    end
    if lower:find("quest complete", 1, true) then
        reports.chat = "Quest complete message seen: " .. View.Escape(message)
    end
    -- "You find nothing": the click on the step's object didn't do it.
    if pendingClick ~= nil then
        for _, phrase in ipairs(Advance.NOTHING_MESSAGES) do
            if lower:find(phrase, 1, true) then
                pendingClick = nil
                break
            end
        end
    end
    -- A fight step ends when the game says the target died.
    local entry = currentEntry()
    if entry ~= nil and pref("auto", true) and Advance.IsFightStep(entry.step) then
        for _, phrase in ipairs(KILL_MESSAGES) do
            if lower:find(phrase, 1, true) then
                setStep(currentIndex() + 1, "fight won")
                return
            end
        end
    end
end
local function syncChatSubscription()
    local allowed = Plugin.HasPermission(PluginPermissions.chatAccess)
    if allowed and not chatSubscribed then
        Event.ChatMessage.Subscribe("rs3qb-chat", function(event) Diag.Guard("chat", onChat, event) end)
    elseif not allowed and chatSubscribed then
        Event.ChatMessage.Unsubscribe("rs3qb-chat")
    end
    chatSubscribed = allowed
end
syncChatSubscription()
Event.OptionalPermissionChanged.Subscribe("rs3qb-perms", function()
    syncChatSubscription()
    refreshPanel()
end)

-- ---------- startup ----------

applyGuidance()
backpack = readBackpack()
Recorder.Add("start", BUILD, questKey, currentIndex(), "auto " .. onOff(pref("auto", true)),
    "chat " .. onOff(chatSubscribed))
do
    local saved = {}
    for key, index in pairs(stepIndex) do saved[#saved + 1] = key .. "=" .. tostring(math.tointeger(index) or index) end
    table.sort(saved)
    Recorder.Add("steps", table.concat(saved, ";"))
    Recorder.Add("ifaces", table.concat(dialogInterfaces, ","))
end
Diag.Guard("record vars", recordVars)
Recorder.AddIfChanged("bag", bagText(backpack))
if currentQuest() ~= nil then
    lastVarValue = progressValue(currentQuest())
    finishedSeen = questStatus(currentQuest()) == "complete"
    Diag.Snapshot("questInfo", questInfo(currentQuest()))
    Diag.Guard("first step", setStep, currentIndex())
end
Diag.Guard("first card", drawCard)
Diag.Note("loaded: " .. #Quests .. " quests")

-- Offline replays of a recording (tests/replay.py) redo the tester's own
-- step changes through this, and the all-quests check (tests/check_quests.py)
-- asks the step logic directly; RS3QB_REPLAY never exists in the game.
if RS3QB_REPLAY ~= nil then
    RS3QB_REPLAY.setStep = function(index, source) setStep(index, nil, source) end
    RS3QB_REPLAY.openQuest = openQuest
    RS3QB_REPLAY.inside = {
        flatSteps = flatSteps, stepTargets = stepTargets, sceneryMatcher = sceneryMatcher,
        stepItems = stepItems, stepBlocks = stepBlocks, acquireWants = acquireWants,
        producedItems = producedItems, neededParsed = neededParsed, isTradeable = isTradeable,
        recipeFor = recipeFor, setPref = setPref, currentIndex = currentIndex, ownClickStep = ownClickStep,
        bagNow = function() return backpack, bagState end,
        setBackpack = function(counts) backpack = counts end,
    }
end

-- Must stay global: the plugin system calls it on disable and client exit.
function PluginShutdown()
    Recorder.Add("end")
    Recorder.Flush()
    World.Shutdown()
    Card.Shutdown()
end
