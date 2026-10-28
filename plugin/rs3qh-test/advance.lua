-- Auto-advance and item matching: which guide step an in-game interaction
-- belongs to, what a step asks for, and whether the backpack has it. Pure
-- string logic (no game calls) so it can be tested offline.
--
-- The idea: players don't press "Done", they just play. When they click
-- something the current step (or one of the next few) names, that step is
-- the one being done; any steps before it are finished.

local Advance = {}

-- How far ahead an interaction may jump. Small, so a common name ("Door")
-- further down the guide can't skip half the quest.
Advance.LOOKAHEAD = 3

-- Verbs that never mean progress.
local IGNORED_VERBS = { ["walk here"] = true, ["examine"] = true, ["cancel"] = true, ["face here"] = true }

-- First words that classify a step.
local TRAVEL_VERBS = { teleport = true, go = true, run = true, head = true, travel = true, walk = true, ["return"] = true }
local USE_VERBS = { use = true, dye = true, give = true, put = true, add = true, combine = true, mix = true }
local MAKE_VERBS = { dye = true, combine = true, make = true, craft = true, smith = true, cook = true, bake = true,
    mix = true, fill = true }
local ACQUIRE_WORDS = { obtain = true, get = true, buy = true, collect = true, mine = true, pick = true,
    take = true, grab = true, kill = true, loot = true }

local NUMBER_WORDS = { one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9, ten = 10 }

-- "<col=ffff00>Squire Asrol</col>" -> "squire asrol"
function Advance.Clean(text)
    text = (text or ""):gsub("<[^>]*>", ""):lower()
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- "Cook (Lumbridge)" -> "cook": wiki disambiguators never appear in game.
function Advance.BaseName(page)
    return Advance.Clean((page:gsub("%s*%b()", "")))
end

local function firstWord(step)
    return step.text:lower():match("^%s*(%a+)")
end

-- "Walk down the stairs" starts like travel but is a climb (see ClimbDirection).
function Advance.IsTravelStep(step)
    return TRAVEL_VERBS[firstWord(step) or ""] == true and Advance.ClimbDirection(step) == nil
end
function Advance.IsUseStep(step) return USE_VERBS[firstWord(step) or ""] == true end
function Advance.IsMakeStep(step) return MAKE_VERBS[firstWord(step) or ""] == true end

-- True when the step asks you to obtain something ("Mine...", "...grab three
-- suits of goblin mail from the crates").
function Advance.IsAcquireStep(step)
    for word in step.text:lower():gmatch("%a+") do
        if ACQUIRE_WORDS[word] then return true end
    end
    return false
end

-- The step's text plus its sub-bullets, which often name what to click
-- ("- Up a ladder in the middle of the gate entrance").
function Advance.FullText(step)
    local parts = { step.text }
    for _, sub in ipairs(step.subs or {}) do parts[#parts + 1] = sub.text end
    return table.concat(parts, " ")
end

-- "Enter the manor and go to the east side."
function Advance.IsEnterStep(step) return firstWord(step) == "enter" end

-- The guides point at pictures the plugin can't show: "(pictured right,
-- north of fairy ring AIQ)" -> "(north of fairy ring AIQ)"; "(see the
-- map)" and a bare "(pictured)" go entirely.
function Advance.WithoutPictureRefs(text)
    text = text:gsub("%(%s*pictured%s+%a+%s*[,;]%s*", "(")
    text = text:gsub("%s*%(%s*pictured[^%)]*%)", "")
    text = text:gsub("[,;]%s*pictured%s+%a+", "")
    text = text:gsub("%s*%(%s*see the %a+%s*%)", "")
    return text
end

-- "Talk to Thurgo with the materials": the step uses its section's items.
function Advance.UsesMaterials(step)
    local text = step.text:lower()
    return text:find("materials", 1, true) ~= nil or text:find("ingredients", 1, true) ~= nil
        or text:find("the items", 1, true) ~= nil
end

-- "Mine a blurite ore." -> "blurite"
function Advance.MinedOre(step)
    return step.text:lower():match("mine%s+%w*%s*(%a+)%s+ores?")
end

-- "Follow the dungeon until blurite rocks are seen": done once they're near.
function Advance.IsUntilStep(step)
    local text = step.text:lower()
    return text:find(" until ", 1, true) ~= nil
        and (text:find("seen", 1, true) or text:find("found", 1, true) or text:find("reach", 1, true)) ~= nil
end

-- "Walk down the stairs", "Climb the ladder", "Go down the trapdoor":
-- returns "down", "up" or "any", or nil for other steps.
function Advance.ClimbDirection(step)
    local text = " " .. step.text:lower() .. " "
    if not (text:find("stair") or text:find("ladder") or text:find("trapdoor") or text:find(" climb")) then
        return nil
    end
    if text:find(" down") then return "down" end
    if text:find(" up[%s%.,]") or text:find("upstairs") then return "up" end
    return "any"
end

-- The climbs a step asks for, in order: "Climb the ladder to the east, then
-- the first staircase to the west" -> { ladder east, stair west }. Each is
-- { kind = "ladder"|"stair"|"trapdoor", side = compass word or nil }.
local CLIMB_KINDS = { "ladder", "stair", "trapdoor" }
function Advance.ClimbGoals(step)
    local goals = {}
    local text = step.text:lower():gsub(",?%s+and then%s+", " then "):gsub(",%s*then%s+", " then ")
    for clause in (text .. " then "):gmatch("(.-) then ") do
        local first, kind = nil, nil
        for _, k in ipairs(CLIMB_KINDS) do
            local at = clause:find(k, 1, true)
            if at and (first == nil or at < first) then first, kind = at, k end
        end
        if kind then
            goals[#goals + 1] = { kind = kind, side = clause:match("to the (%a+)") or clause:match("(%a+)ern%s") }
        end
    end
    return goals
end

-- Things a step can ask you to do besides getting somewhere: "Go upstairs
-- and talk to Doris" isn't done at the top of the stairs.
local ACTION_WORDS = { talk = true, speak = true, search = true, kill = true, defeat = true, give = true, ask = true,
    buy = true, fight = true, attack = true, chat = true, investigate = true, inspect = true, read = true,
    examine = true, mine = true, chop = true, fish = true, cook = true, pray = true, operate = true, pull = true,
    push = true, pickpocket = true, steal = true, dig = true, light = true, fill = true, use = true }

local function words(step)
    local out = {}
    for word in step.text:lower():gmatch("%a+") do out[#out + 1] = word end
    return out
end

local function isClimbable(word)
    return word ~= nil and (word:find("stair") or word:find("ladder") or word:find("trapdoor")) ~= nil
end

-- Is word `i` an action? "Use the ladder" is a climb, not an action.
local function isAction(list, i)
    return ACTION_WORDS[list[i]] == true
        and not (list[i] == "use" and (isClimbable(list[i + 1]) or isClimbable(list[i + 2])))
end

-- The first action word a step names ("talk"), or nil for steps that are
-- only about getting somewhere.
function Advance.MainAction(step)
    local list = words(step)
    for i, word in ipairs(list) do
        if isAction(list, i) then return word end
    end
    return nil
end

-- Does climbing finish this step? Yes for "Climb down the trapdoor" and
-- "Investigate the poster, then climb the stairs"; no for "Talk to Reldo
-- upstairs" or "Climb the ladder and talk to Bill", where the stairs are
-- only the way there.
function Advance.ClimbFinishes(step)
    if Advance.ClimbDirection(step) == nil then return false end
    local list = words(step)
    local action = nil
    for i = 1, #list do
        if isAction(list, i) then action = i end
    end
    if action == nil then return true end
    for i = action + 1, #list do
        local word, after = list[i], list[i + 1]
        if word == "climb" or word == "descend" or word == "ascend"
            or ((word == "go" or word == "head" or word == "walk" or word == "run")
                and (after == "up" or after == "down" or after == "upstairs" or after == "downstairs")) then
            return true
        end
    end
    return false
end

-- Does arriving finish this travel step? Not "Go to the inn and talk to Robin".
function Advance.TravelFinishes(step)
    return Advance.IsTravelStep(step) and Advance.MainAction(step) == nil
end

-- A step that's only getting somewhere (walking, climbing, going in), which
-- a later click can safely skip past.
function Advance.IsPassiveStep(step)
    return (Advance.IsTravelStep(step) or Advance.ClimbDirection(step) ~= nil or Advance.IsEnterStep(step))
        and Advance.MainAction(step) == nil
end

-- ---------- what a step names: the thing to click, or a landmark ----------

-- Words before a name that make it a landmark ("north of the well", "near
-- the wall", "by the mine cart sign") rather than the thing to click.
local LANDMARK_WORDS = { near = true, by = true, beside = true, behind = true, outside = true,
    inside = true, opposite = true, past = true, around = true, between = true, above = true, below = true,
    under = true, beneath = true, across = true, along = true, beyond = true, toward = true,
    towards = true, guarding = true, overlooking = true, facing = true }
-- These only with the word after: "north of the well", "next to the sign",
-- "in front of the gate" (not "the west statue", "the next 3 statues").
local LANDMARK_BEFORE = { north = "of", south = "of", east = "of", west = "of", northeast = "of", northwest = "of",
    southeast = "of", southwest = "of", ["north-east"] = "of", ["north-west"] = "of", ["south-east"] = "of",
    ["south-west"] = "of", next = "to", front = "of" }
-- Something to click comes with an article or a count: "the well", "a
-- fire", "15 rocks". Not "prepare well", "Fire the cannon".
local DETERMINERS = { the = true, a = true, an = true, this = true, that = true, these = true, those = true,
    each = true, every = true, any = true, some = true, both = true, its = true, his = true, her = true,
    their = true, your = true, all = true, another = true, other = true, one = true, two = true, three = true,
    four = true, five = true, six = true, seven = true, eight = true, nine = true, ten = true }
-- Words that make it the thing acted on: "search the crate", "fill a bucket
-- from the well". ("on" counts only on steps that use something on it:
-- "Use the feed on the fence", but "the bookcase on the western wall".)
local OBJECT_WORDS = { at = true, from = true, into = true, onto = true, with = true }
local USE_FIRST = { use = true, put = true, place = true, cast = true, add = true, give = true, pour = true }

local function tokens(text)
    local out = {}
    for word, gap in (text:lower() .. " "):gmatch("([%w'%-]*)([^%w'%-]*)") do
        if word ~= "" then out[#out + 1] = word end
        if gap:find("[,%.;:!%?%(%)]") then out[#out + 1] = "," end
    end
    return out
end

-- How often `text` names `name` as the thing to act on and as a landmark.
-- With `prefix`, words starting with the name's last word count ("stair"
-- -> "staircase"); otherwise whole words, plural allowed.
function Advance.MentionRoles(text, name, prefix)
    local list, wanted = tokens(text), {}
    for word in name:lower():gmatch("[%w'%-]+") do wanted[#wanted + 1] = word end
    if #wanted == 0 then return 0, 0 end
    local onIsObject = USE_FIRST[list[1] or ""] == true
    local object, landmark = 0, 0
    for i = 1, #list - #wanted + 1 do
        local match = true
        for j, want in ipairs(wanted) do
            local word = list[i + j - 1]
            if j < #wanted then
                match = match and word == want
            elseif prefix then
                match = match and word:sub(1, #want) == want
            else
                match = match and (word == want or word == want .. "s" or word == want .. "es")
            end
        end
        if match then
            local role, determined = "object", false
            for back = i - 1, math.max(1, i - 4), -1 do
                local word = list[back]
                if word == "," or OBJECT_WORDS[word] or (word == "on" and onIsObject) then break end
                if LANDMARK_WORDS[word] or word == "on" or (LANDMARK_BEFORE[word] and list[back + 1] == LANDMARK_BEFORE[word]) then
                    role = "landmark"
                    break
                end
                if back >= i - 3 and (DETERMINERS[word] or word:match("^%d+$")) then determined = true end
            end
            if role == "landmark" then
                landmark = landmark + 1
            elseif determined then
                object = object + 1
            end
        end
    end
    return object, landmark
end

-- Objects so common that clicking one says nothing about which step you're
-- on: a ladder at the Lumbridge mill isn't the castle ladder three steps on.
local GENERIC_SCENERY = { "ladder", "stair", "door", "gate", "trapdoor" }
function Advance.IsGenericScenery(name)
    name = Advance.Clean(name)
    for _, word in ipairs(GENERIC_SCENERY) do
        if name:find(word, 1, true) then return true end
    end
    return false
end

local FIGHT_WORDS = { fight = true, kill = true, defeat = true, slay = true, attack = true }
function Advance.IsFightStep(step)
    for word in step.text:lower():gmatch("%a+") do
        if FIGHT_WORDS[word] then return true end
    end
    return false
end

-- Whole-word (optionally plural) search for `phrase` in `text`.
local function mentions(text, phrase)
    if #phrase < 4 then return false end
    local hay = " " .. text:lower():gsub("[^%w']", " ") .. " "
    local needle = " " .. phrase:lower():gsub("[^%w']", " "):gsub("%s+", " "):gsub("%p", "%%%0") .. "s? "
    return hay:find(needle) ~= nil
end
Advance.Mentions = mentions

-- Does interacting with `subject` belong to this step? True when it's one of
-- the step's linked names, or (for scenery like "trapdoor", which guides
-- rarely link) the name appears as a whole word in the step text.
function Advance.StepMentions(step, subject)
    subject = Advance.Clean(subject)
    if #subject < 3 then return false end
    for _, page in ipairs(step.npcs or {}) do
        if Advance.BaseName(page) == subject then return true end
    end
    for _, name in ipairs(step.inheritedNpcs or {}) do
        if Advance.BaseName(name) == subject then return true end
    end
    return mentions(step.text, subject)
end

-- "Orange goblin mail -> General Wartface" -> { "orange goblin mail", "general wartface" }
function Advance.SubjectParts(subject)
    local parts = {}
    for part in (Advance.Clean(subject) .. "->"):gmatch("(.-)%s*%->%s*") do
        if part ~= "" then parts[#parts + 1] = part end
    end
    return parts
end

-- Steps back where a name counts as "just dealt with" (see MatchInteraction).
Advance.LOOKBACK = 3

-- Index of the step (current .. current+LOOKAHEAD) that an interaction
-- belongs to, or nil. `entries` is the flat step list ({ step = ... }).
-- Clicking someone the last few steps were about (a second chat after
-- starting the quest, a misclick) says little about progress, so then it
-- only skips steps that are just walking or climbing there.
function Advance.MatchInteraction(entries, current, verb, subject)
    if IGNORED_VERBS[Advance.Clean(verb)] then return nil end
    local parts = Advance.SubjectParts(subject)
    local recent = false
    for i = math.max(1, current - Advance.LOOKBACK), current - 1 do
        for _, part in ipairs(parts) do recent = recent or Advance.StepMentions(entries[i].step, part) end
    end
    for i = current, math.min(#entries, current + Advance.LOOKAHEAD) do
        if i > current and recent and not Advance.IsPassiveStep(entries[i - 1].step) then return nil end
        for _, part in ipairs(parts) do
            -- Ladders, doors and the like only count for the step you're on.
            if (i == current or not Advance.IsGenericScenery(part)) and Advance.StepMentions(entries[i].step, part) then
                return i
            end
        end
    end
    return nil
end

-- ---------- required items ----------

-- Guides list several items in one entry: "Orange dye (Combine Red dye and
-- Yellow dye), Blue dye and a bucket". Commas and "and" split the list, but
-- not inside brackets, where they describe how to make the item.
function Advance.SplitNeeded(text)
    local items, depth, current, i = {}, 0, {}, 1
    local function flush()
        local item = table.concat(current):gsub("^%s+", ""):gsub("%s+$", "")
        if item ~= "" then items[#items + 1] = item end
        current = {}
    end
    while i <= #text do
        local ch = text:sub(i, i)
        if ch == "(" then depth = depth + 1 elseif ch == ")" then depth = math.max(0, depth - 1) end
        if depth == 0 and ch == "," then
            flush()
        elseif depth == 0 and text:sub(i, i + 4):lower() == " and " then
            flush()
            i = i + 4
        else
            current[#current + 1] = ch
        end
        i = i + 1
    end
    flush()
    return items
end

-- "3 suits of goblin mail" -> { name = "goblin mail", qty = 3 }
-- "Orange dye (Combine Red dye and Yellow dye)" -> name "orange dye", parts { "red dye", "yellow dye" }
function Advance.ParseNeeded(text)
    -- "×" is two bytes; swap it before lower(), which is locale-dependent and
    -- can mangle non-ASCII bytes.
    local clean = Advance.Clean((text:gsub("\195\151", "x")))
    local inner = clean:match("%((.-)%)") or ""
    clean = clean:gsub("%s*%b()", "")
    local qty, rest = clean:match("^(%d+)%s*x?%s+(.+)$")
    if qty == nil then
        rest, qty = clean:match("^(.-)%s*x%s*(%d+)$") -- "Iron bar x2"
    end
    if qty == nil then
        local word, tail = clean:match("^(%a+)%s+(.+)$")
        if word and NUMBER_WORDS[word] then qty, rest = NUMBER_WORDS[word], tail end
    end
    local name = (rest or clean):gsub("^(%a+)%s+of%s+", function(unit)
        if unit:match("^suits?$") or unit:match("^sets?$") or unit:match("^pieces?$") or unit:match("^pairs?$") then
            return ""
        end
    end)
    local parts = {}
    inner = inner:gsub("^%a+%s+", function(verb)
        if verb:match("^combine") or verb:match("^use") or verb:match("^mix") then return "" end
    end)
    for part in (inner:gsub("%s+and%s+", ","):gsub("%s+or%s+", ",") .. ","):gmatch("%s*(.-)%s*,") do
        if part ~= "" then parts[#parts + 1] = part end
    end
    return { name = name, qty = tonumber(qty) or 1, label = text, parts = parts }
end

local function singular(name)
    return (name:gsub("^an?%s+", ""):gsub("^any%s+", ""):gsub("ies$", "y"):gsub("([^s])s$", "%1"))
end
Advance.Singular = singular

-- How many of an item the backpack has. `counts` maps lower-case item names
-- to totals. Plurals and "any X" match, and so do variants that contain the
-- name ("orange goblin mail" counts toward "3 goblin mail": you still have it).
function Advance.HaveCount(counts, need)
    -- "An anti-dragon shield or super antifire potion": either will do.
    if need.name:find(" or ", 1, true) then
        local best = 0
        for option in (need.name .. " or "):gmatch("(.-) or ") do
            best = math.max(best, Advance.HaveCount(counts, { name = (option:gsub("^an?%s+", "")) }))
        end
        return best
    end
    local want = singular(need.name)
    local total = 0
    for name, count in pairs(counts) do
        local have = singular(name)
        if have == want or (#want >= 4 and have:find(want, 1, true) ~= nil) then
            total = total + count
        end
    end
    return total
end

-- What an acquire step asks for, read from its own words: "buy a beer from
-- the bartender" -> beer; "get a stake and stake hammer" -> stake, stake
-- hammer; "grab three suits of goblin mail from the crates" -> 3 goblin mail.
local ACQUIRE_PHRASE_VERBS = { "obtain", "get", "buy", "collect", "mine", "take", "grab", "pick up", "pick" }
-- Words that end the thing being got: "grab the cheese off of the table".
local PHRASE_ENDS = { "from", "in", "at", "to", "for", "via", "off", "on", "by", "with", "near", "into", "inside",
    "outside", "then", "until", "so", "if", "when", "before", "after", "which", "that", "while", "using", "out" }
-- "get to the top", "get caught", "pick up the pace": not items.
local NOT_OBJECTS = { to = true, back = true, out = true, into = true, past = true, caught = true, there = true,
    through = true, up = true, down = true, off = true, on = true, close = true, near = true, rid = true,
    inside = true, outside = true, over = true, around = true, away = true, ready = true, it = true, them = true,
    one = true, ["in"] = true, him = true, her = true, this = true, that = true, these = true, those = true,
    all = true, both = true, care = true, part = true, place = true, damage = true, note = true, turns = true,
    used = true, hit = true, attacked = true, killed = true, spotted = true, noticed = true, lost = true }
function Advance.AcquireTargets(step)
    -- Brackets are asides ("in the Dwarven Mine (he is standing in ...)").
    local original = " " .. step.text:gsub("%s*%b()", ""):gsub("[,;:]", " .") .. " "
    local text = original:lower()
    local found = {}
    for _, verb in ipairs(ACQUIRE_PHRASE_VERBS) do
        local from = 1
        while true do
            local s, e = text:find(" " .. verb .. " ", from, true)
            if s == nil then break end
            from = e
            local rest = text:sub(e + 1)
            local nextWord = rest:match("^(%a+)")
            -- "the Dwarven Mine", "the mine": a place, not "mine ...".
            local before = text:sub(1, s):match("(%a+)%s*$")
            local previous = original:sub(1, s):match("(%S)%s*$")
            local named = original:sub(s + 1, s + 1):match("%u") ~= nil and previous ~= nil and previous ~= "."
                and previous ~= "!" and previous ~= "?"
            if not (NOT_OBJECTS[nextWord or ""] or (verb == "pick" and nextWord == "up") or before == "the"
                or before == "a" or named) then
                local phrase = rest:match("^(.-)%s*%.") or rest
                for _, word in ipairs(PHRASE_ENDS) do
                    phrase = phrase:match("^(.-)%s+" .. word .. "%s") or phrase
                end
                phrase = phrase:gsub("^%s*the%s+", ""):gsub("^%s*some%s+", ""):gsub("^%s*your%s+", "")
                for part in (phrase:gsub("%s+and%s+", ",") .. ","):gmatch("%s*(.-)%s*,") do
                    local need = Advance.ParseNeeded((part:gsub("^an?%s+", "")))
                    if #need.name >= 3 and #need.name <= 30 and not NOT_OBJECTS[need.name] then
                        found[#found + 1] = need
                    end
                end
            end
        end
    end
    return found
end

-- Quest items (parsed) whose names a step's text mentions.
function Advance.ItemsMentioned(step, needed)
    local found = {}
    for _, need in ipairs(needed) do
        if mentions(step.text, need.name) or mentions(step.text, singular(need.name)) then found[#found + 1] = need end
    end
    return found
end

return Advance
