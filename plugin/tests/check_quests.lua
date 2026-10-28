-- Walks every step of every quest through the plugin's own step logic (with
-- mock.lua standing in for the game) and notes where it would go wrong:
-- text it can't show cleanly, steps that finish too early or never by
-- themselves, items it can't explain, clicks that jump ahead. No game
-- needed: it plays each step out on paper. check_quests.py runs it, checks
-- the "Get:" names against the wiki and writes the report.
--
-- Globals in: PLUGIN_DIR, QUESTS_FILE (a quests.lua built with
-- build_quests.py --all). Returns { findings = {...}, stats = {...} }.

package.loaded.quests = dofile(QUESTS_FILE)
RS3QH_REPLAY = {}
assert(loadfile(PLUGIN_DIR .. "/main.lua"))()
assert(RS3QH_REPLAY.inside, "plugin didn't load: " .. tostring(M.db["diag.loadError"]))

local Advance = require("advance")
local Probe = require("probe")
local Travel = require("travel")
local Quests = require("quests")
local P = RS3QH_REPLAY.inside
local pages = Quests.pages or {}

local findings, stats = {}, { quests = 0, steps = 0 }
local function count(key, n) stats[key] = (stats[key] or 0) + (n or 1) end
local function note(quest, index, kind, detail, text)
    findings[#findings + 1] = { quest = quest.name, step = index, kind = kind, detail = detail or "", text = text or "" }
end

-- Words that start a step whose job isn't climbing, even when it mentions
-- stairs ("Talk to Reldo upstairs", "Search the crate next to the ladder").
local CLIMB_FIRST = { climb = true, go = true, walk = true, head = true, run = true, ["return"] = true, travel = true,
    descend = true, ascend = true, enter = true, exit = true, leave = true, take = true, use = true, follow = true,
    jump = true, squeeze = true, crawl = true, continue = true, proceed = true, make = true, bring = true, move = true,
    open = true, ["then"] = true }
local OTHER_ACTION = { "talk", "speak", "search", "kill", "defeat", "give", "ask", "pick", "buy", "fight", "attack",
    "chat", "investigate", "inspect", "read", "examine", "mine", "chop", "fish", "cook", "pray", "operate", "pull" }

local function hasWord(text, word)
    return (" " .. text:lower():gsub("[^%w']", " ") .. " "):find(" " .. word .. "s? ") ~= nil
end
local function otherAction(text)
    for _, word in ipairs(OTHER_ACTION) do
        if hasWord(text, word) then return word end
    end
    return nil
end

local MARKUP = { "%[%[", "%]%]", "{{", "}}", "<ref", "''", "&nbsp;", "&amp;", "<br", "File:", "%s|%s", "__" }
local PICTURE = { "pictur", "image", "shown below", "shown above", "see map", "on the map", "screenshot",
    "highlighted in", "marked on", "%(see ", "below%)", "above%)" }

-- Common scenery, each with the menu option it would have, for "what gets
-- outlined" on every step.
local SCENERY = {
    { "Door", "Open" }, { "Gate", "Open" }, { "Ladder", "Climb-up" }, { "Staircase", "Climb-up" },
    { "Trapdoor", "Climb-down" }, { "Crate", "Search" }, { "Chest", "Open" }, { "Bookcase", "Search" },
    { "Cupboard", "Open" }, { "Table", "Search" }, { "Tree", "Chop down" }, { "Rocks", "Mine" },
    { "Bush", "Pick" }, { "Altar", "Pray-at" }, { "Bank booth", "Bank" }, { "Furnace", "Smelt" },
    { "Anvil", "Smith" }, { "Range", "Cook-at" }, { "Fountain", "Look" }, { "Statue", "Look" },
    { "Well", "Look" }, { "Boat", "Board" }, { "Cave entrance", "Enter" }, { "Barrel", "Search" },
    { "Lever", "Pull" }, { "Fire", "Use" }, { "Coffin", "Open" }, { "Fence", "Look" }, { "Wall", "Look" },
    { "Bed", "Search" }, { "Sign", "Read" }, { "Stall", "Steal-from" }, { "Rowboat", "Board" }, { "Rope", "Climb" },
}

local function sceneryLoc(name, op, x, z)
    return { displayName = name, config = { opNames = { op } }, position = { x = x * 512 + 256, y = 0, z = z * 512 + 256 } }
end

local function blocksText(blocks)
    local parts = {}
    for _, b in ipairs(blocks) do parts[#parts + 1] = (b.text or ""):gsub("<[^>]*>", "") end
    return parts
end

-- A click on `subject` (verb `verb`) with the guide on step `current`:
-- which step would the plugin move to (nil: none)?
local function jumpFor(list, current, verb, subject)
    for i = current, math.min(#list, current + Advance.LOOKAHEAD) do P.stepTargets(list.quest, i) end
    local index = Advance.MatchInteraction(list, current, verb, subject)
    if index ~= nil and index > current then return index end
    return nil
end

P.setPref("ironman", false)
for _, quest in ipairs(Quests) do
    stats.quests = stats.quests + 1
    RS3QH_REPLAY.openQuest(quest.key)
    local list = P.flatSteps[quest.key]
    list.quest = quest
    local previousNav = nil
    local manualOnly = 0
    for index, entry in ipairs(list) do
        stats.steps = stats.steps + 1
        RS3QH_REPLAY.setStep(index, "check")
        local step = entry.step
        local full = Advance.FullText(step)
        local targets = P.stepTargets(quest, index)
        local first = step.text:lower():match("^%s*(%a+)") or ""

        -- ---------- text ----------
        for _, pattern in ipairs(MARKUP) do
            if full:find(pattern) then note(quest, index, "markup", pattern:gsub("%%", ""), full) break end
        end
        local shown = Advance.WithoutPictureRefs(step.text)
        for _, sub in ipairs(step.subs or {}) do shown = shown .. " " .. Advance.WithoutPictureRefs(sub.text) end
        for _, pattern in ipairs(PICTURE) do
            if shown:lower():find(pattern) then note(quest, index, "picture", pattern:gsub("%%", ""), shown) break end
        end
        if step.text:gsub("%s", "") == "" then note(quest, index, "empty-step", "", full) end

        -- ---------- what the card would show ----------
        P.setBackpack({})
        local blocks = P.stepBlocks(quest, entry, true)
        if #blocks > 40 then note(quest, index, "card-overflow", #blocks .. " lines (max 40)", step.text) end
        local cardText = table.concat(blocksText(blocks), "\n")
        if #cardText > 900 then note(quest, index, "card-long", #cardText .. " chars", step.text) end

        -- ---------- chat ----------
        if step.chat then
            local candidates = Probe.ChatCandidates(step.chat)
            if #candidates == 0 then note(quest, index, "chat-empty", step.chat, step.text) end
            for _, c in ipairs(candidates) do
                if c:find("[%[%]{}|]") or #c > 90 then note(quest, index, "chat-odd", c, step.chat) break end
            end
        end

        -- ---------- climbs ----------
        local climb = Advance.ClimbDirection(step)
        if climb ~= nil then
            count("climbSteps")
            local action = otherAction(step.text)
            if Advance.ClimbFinishes(step) and #P.acquireWants(quest, entry) == 0 then
                count("climbFinishes")
                if not CLIMB_FIRST[first] or action then
                    -- Climbing finishes it, though it names something else to do.
                    note(quest, index, "climb-early", first .. (action and (" / " .. action) or ""), step.text)
                end
            else
                note(quest, index, "climb-waits", Advance.MainAction(step) or "", step.text)
            end
            local goals = Advance.ClimbGoals(step)
            if #goals > 1 then note(quest, index, "climb-multi", #goals .. " climbs", step.text) end
        end

        -- ---------- travel ----------
        if Advance.IsTravelStep(step) then
            count("travelSteps")
            local action = otherAction(step.text)
            if Advance.TravelFinishes(step) and action and #P.acquireWants(quest, entry) == 0 then
                note(quest, index, step.chat and "travel-early-chat" or "travel-early", action, step.text)
            elseif not Advance.TravelFinishes(step) then
                note(quest, index, "travel-waits", Advance.MainAction(step) or "", step.text)
            end
            if targets.nav == nil then note(quest, index, "travel-no-place", "", step.text) end
        end

        -- ---------- where to go ----------
        if targets.nav ~= nil then
            count("withNav")
            if previousNav ~= nil then
                local hint = Travel.Suggest(previousNav.x, previousNav.y, targets.nav.x, targets.nav.y)
                if hint then count("teleportHints") end
            end
            previousNav = targets.nav
        elseif #targets.npcs > 0 then
            note(quest, index, "no-nav", table.concat(targets.npcs, "|"), step.text)
        end
        for _, page in ipairs(step.npcs or {}) do
            local info = pages[page:lower()]
            if info == nil or info.kind == nil then
                count("unknownLinks")
                note(quest, index, "link-unknown", page, step.text)
            end
        end

        -- ---------- items ----------
        local items = P.stepItems(quest, entry)
        for _, item in ipairs(items) do
            if not item.recommended then
                local name = item.need.name
                local help = item.hint ~= nil or P.isTradeable(name) or P.recipeFor(name) ~= nil
                local parts = 0
                for _, part in ipairs(item.need.parts) do
                    if not part:find("quest") and not part:find("obtain") then parts = parts + 1 end
                end
                note(quest, index, "item", name .. "\t" .. (P.isTradeable(name) and "ge" or "")
                    .. "\t" .. (P.recipeFor(name) and "recipe" or "") .. "\t" .. (item.hint and "hint" or "")
                    .. "\t" .. parts, item.label)
                if not help and parts == 0 then count("itemsNoHelp") end
            end
        end
        local wants = P.acquireWants(quest, entry)
        for _, need in ipairs(wants) do note(quest, index, "get", need.name, step.text) end

        -- ---------- what gets outlined ----------
        local matcher = P.sceneryMatcher(entry)
        if matcher ~= nil then
            local outlined = {}
            for _, s in ipairs(SCENERY) do
                -- Placed east of the player, at the step's own spot so "enter"
                -- doors count.
                local nav = targets.nav or { x = 3200, y = 3200, plane = 0 }
                require("world").playerTile = { x = nav.x, z = nav.y, level = 0 }
                local ok, hit = pcall(matcher, sceneryLoc(s[1], s[2], nav.x + 2, nav.y))
                if ok and hit then outlined[#outlined + 1] = s[1] end
            end
            if #outlined > 0 then note(quest, index, "outlines", table.concat(outlined, "|"), step.text) end
        end

        -- ---------- how it finishes by itself ----------
        local how = {}
        if #targets.npcs > 0 then how[#how + 1] = "npc" end
        if climb then how[#how + 1] = "climb" end
        if Advance.TravelFinishes(step) and targets.nav then how[#how + 1] = "arrive" end
        -- Getting an item the next step mentions (searching the cupboard gives
        -- the portrait "Give Thurgo the portrait" wants).
        local nextEntry = list[index + 1]
        if #targets.npcs == 0 and not Advance.IsTravelStep(step) and nextEntry
            and #Advance.ItemsMentioned(nextEntry.step, P.neededParsed(quest)) > 0 then
            how[#how + 1] = "next-item"
        end
        if #wants > 0 then how[#how + 1] = "items" end
        if Advance.IsMakeStep(step) and #P.producedItems(quest, index) > 0 then how[#how + 1] = "make" end
        if Advance.IsEnterStep(step) then how[#how + 1] = "door" end
        if Advance.IsUntilStep(step) then how[#how + 1] = "found" end
        if #how == 0 then
            -- Only the quest's progress var (if it moves) or "Done, next".
            manualOnly = manualOnly + 1
            note(quest, index, "no-trigger", "", step.text)
        end

        -- ---------- scenarios: clicks that jump ahead ----------
        -- Doing this step: talking to its own NPC, clicking what it names.
        for _, npc in ipairs(targets.npcs) do
            local to = jumpFor(list, index, "Talk-to", npc)
            if to then note(quest, index, "jump-own", npc .. " -> step " .. to, step.text) end
        end
        -- Just after it: talking to the same NPC again (a second chat, or
        -- clicking them by accident) while the guide is on the next step.
        -- Skipping only walking/climbing steps is fine (you're clearly there).
        if index < #list then
            for _, npc in ipairs(targets.npcs) do
                local to = jumpFor(list, index + 1, "Talk-to", npc)
                if to then
                    local real = {}
                    for skipped = index + 1, to - 1 do
                        local s = list[skipped].step
                        if not Advance.IsTravelStep(s) and Advance.ClimbDirection(s) == nil and not Advance.IsEnterStep(s) then
                            real[#real + 1] = skipped .. ": " .. s.text
                        end
                    end
                    if #real > 0 then
                        note(quest, index + 1, "jump-retalk", npc .. " -> step " .. to, table.concat(real, " || "))
                    else
                        count("jumpRetalkHarmless")
                    end
                end
            end
        end
    end
    stats["manualOnly"] = (stats["manualOnly"] or 0) + manualOnly
end

return { findings = findings, stats = stats }
