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
    take = true, grab = true, kill = true, loot = true, steal = true }

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

-- The verb a step starts with, past a short opening clause: "In Seers'
-- Village, go to the house..." and "With the slashed book, go to..." start
-- with "go".
local OPENERS = { ["in"] = true, at = true, from = true, with = true, once = true, after = true, upon = true,
    inside = true, outside = true, back = true, now = true, next = true, finally = true, still = true }
local function firstWord(step)
    local text = step.text:lower()
    local word = text:match("^%s*(%a+)")
    if OPENERS[word or ""] then
        local clause, after = text:match("^%s*([^,%.]+),%s*(%a+)")
        local _, length = (clause or ""):gsub("%S+", "")
        if after and length <= 8 then return after end
    end
    return word
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
-- Does the step lean on a picture the card can't show?
local PICTURE_WORDS = { "pictured", "picture", "image", "shown below", "shown above", "see map", "on the map",
    "screenshot", "highlighted in", "marked on", "see the map", "as shown" }
function Advance.HasPictureRef(text)
    local lower = text:lower()
    for _, word in ipairs(PICTURE_WORDS) do
        if lower:find(word, 1, true) then return true end
    end
    return false
end

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
    -- "Go down the path to the ladder" isn't a climb down: the word has to
    -- sit with the climb ("climb down", "down the ladder", "downstairs").
    local CLIMB_THINGS = { "stair", "ladder", "trapdoor", "rope", "hole", "well", "steps", "hatch", "rug", "tunnel",
        "pit", "hill", "cliff", "wall", "vine", "tree", "rubble", "rocks" }
    local function near(dir)
        if text:find(dir .. "stairs", 1, true) then return true end
        if text:find("climb%-?%s*" .. dir) or text:find("climb%-?%s*back%s*" .. dir) then return true end
        -- "down the ladder", "down a rope": the thing climbed within a few words.
        for after in text:gmatch(" " .. dir .. " %a+%s*%a*%s*%a*") do
            for _, thing in ipairs(CLIMB_THINGS) do
                if after:find(thing, 1, true) then return true end
            end
        end
        return false
    end
    if near("down") then return "down" end
    if near("up") then return "up" end
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
            local goal = { kind = kind, side = clause:match("to the (%a+)") or clause:match("(%a+)ern%s") }
            -- "Climb the staircase twice", "two sets of stairs", "three flights".
            local times = 1
            if clause:find("twice", 1, true) then times = 2 end
            local count = clause:match("(%w+) times") or clause:match("(%w+) sets? of") or clause:match("(%w+) flights?")
            if count and NUMBER_WORDS[count] then times = NUMBER_WORDS[count] end
            if count and tonumber(count) then times = math.min(tonumber(count), 5) end
            for _ = 1, times do goals[#goals + 1] = goal end
        end
    end
    return goals
end

-- Things a step can ask you to do besides getting somewhere: "Go upstairs
-- and talk to Doris" isn't done at the top of the stairs.
local ACTION_WORDS = { talk = true, speak = true, search = true, kill = true, defeat = true, give = true, ask = true,
    buy = true, fight = true, attack = true, chat = true, investigate = true, inspect = true, read = true,
    examine = true, mine = true, chop = true, fish = true, cook = true, pray = true, operate = true, pull = true,
    push = true, pickpocket = true, steal = true, dig = true, light = true, fill = true, use = true, click = true,
    smith = true, smelt = true, craft = true, fix = true, repair = true, unlock = true, activate = true,
    complete = true, finish = true }
-- "Mine 2 blurite ore", "mine the rocks": "mine" is a verb before a count, an
-- article or an ore; "the Dwarven mines" and "the mine" aren't.
local MINE_NEXT = { the = true, a = true, an = true, some = true, any = true, all = true, coal = true, clay = true,
    ore = true, ores = true, iron = true, copper = true, tin = true, gold = true, silver = true, mithril = true,
    adamantite = true, runite = true, granite = true, sandstone = true, essence = true, rune = true, limestone = true,
    gem = true, gems = true, rock = true, rocks = true, stalagmite = true, rubble = true, blurite = true, lunar = true,
    elemental = true, shadow = true, salt = true, crystal = true, crystals = true, one = true, two = true, three = true,
    four = true, five = true, six = true, seven = true, eight = true, nine = true, ten = true, it = true, them = true }
-- Verbs that are only actions with a thing after them: "open the wall",
-- "turn the controls" (not "the open area", "turn left").
local OBJECT_ACTIONS = { open = true, turn = true, board = true, plant = true, place = true }

-- The step's words, lower-case. `out.names[i]` is true for a word that's
-- part of a name ("Return to Asgarnia Smith", "the Fight Arena"): capitalised
-- mid-sentence next to another capitalised word. Not "After the cutscene,
-- Talk to Bob".
local function words(step)
    local out, capital, midSentence = {}, {}, {}
    local text = step.text
    for start, word in text:gmatch("()(%a+)") do
        out[#out + 1] = word:lower()
        local before = text:sub(1, start - 1):match("(%S)%s*$")
        capital[#out] = word:match("^%u") ~= nil
        midSentence[#out] = before ~= nil and not before:match("[%.!%?:;%(\"']")
    end
    out.names = {}
    for i = 1, #out do
        out.names[i] = capital[i] and midSentence[i] and (capital[i - 1] or capital[i + 1]) or false
    end
    return out
end

local function isClimbable(word)
    return word ~= nil and (word:find("stair") or word:find("ladder") or word:find("trapdoor")) ~= nil
end

-- Is word `i` an action? "Use the ladder" is a climb, not an action.
local function isAction(list, i)
    if list.names and list.names[i] then return false end
    -- "Open the trapdoor", "click the metallic stairs": part of the climb.
    if (OBJECT_ACTIONS[list[i]] or list[i] == "click") and (isClimbable(list[i + 2]) or isClimbable(list[i + 3])) then
        return false
    end
    if OBJECT_ACTIONS[list[i]] then
        return list[i - 1] ~= "the" and list[i - 1] ~= "an" and (list[i + 1] == "the" or list[i + 1] == "a"
            or list[i + 1] == "an" or list[i + 1] == "it")
    end
    if list[i] == "mine" then
        return MINE_NEXT[list[i + 1] or ""] == true or (list[i + 1] or ""):match("^%d+$") ~= nil
    end
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
    towards = true, guarding = true, overlooking = true, facing = true, against = true,
    ["not"] = true }   -- "Exit using the ladder (not the portal)"
-- These only with the word after: "north of the well", "next to the sign",
-- "in front of the gate" (not "the west statue", "the next 3 statues").
local LANDMARK_BEFORE = { north = "of", south = "of", east = "of", west = "of", northeast = "of", northwest = "of",
    southeast = "of", southwest = "of", ["north-east"] = "of", ["north-west"] = "of", ["south-east"] = "of",
    ["south-west"] = "of", next = "to", front = "of", left = "of", right = "of" }
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
-- Words whose "on" is the target: "Head upstairs and use the key on the
-- door", "click on the panel", "Spin the root on the spinning wheel", "Pick
-- the lock on the trapdoor", "Choose the push option on the globe-holder".
-- Only the first "on" after them: in "Use the bottle on the sharp rock on
-- the east wall" the wall is where the rock is.
local USE_FIRST = { use = true, using = true, put = true, place = true, cast = true, add = true, give = true,
    pour = true, click = true, clicking = true, press = true, knock = true, stand = true, step = true, spin = true,
    dry = true, eavesdrop = true, check = true, process = true, shrink = true, lock = true, option = true }
-- Getting past something is doing it: "Crawl under the wall", "Jump across
-- the pit", "Squeeze past the stalagmite" (not "Talk to Bob under the tree").
local MOVE_PAST = { crawl = true, squeeze = true, jump = true, climb = true, vault = true, swing = true,
    slide = true, balance = true, leap = true, hop = true, cross = true, look = true, search = true, check = true }
-- Places described by what's in them: "the building with the anvil".
local PLACES_WITH = { building = true, house = true, room = true, hut = true, shop = true, tent = true, area = true,
    chamber = true, hall = true, cave = true, island = true, ship = true, one = true }
-- A name that's only part of a longer one: "the throne room", "the tomb
-- doors", "the gate ladder", "the boat chute" aren't a throne, tomb, gate or boat.
local COMPOUND_AFTER = { room = true, rooms = true, house = true, hut = true, building = true, chute = true,
    area = true, chamber = true, hall = true, shop = true, tent = true, floor = true, door = true, doors = true,
    doorway = true, gate = true, key = true, ladder = true, storage = true, path = true }
-- "Smith an elemental shield on an anvil workbench": made on it.
local MADE_ON = { smith = true, smelt = true, craft = true, cook = true, forge = true, fletch = true, make = true }

-- Words, with "," for any break; `out.stops[i]` marks the breaks that end a
-- sentence (not a comma or bracket).
local function tokens(text)
    local out = { stops = {} }
    for word, gap in (text:lower() .. " "):gmatch("([%w'%-]*)([^%w'%-]*)") do
        if word ~= "" then out[#out + 1] = word end
        if gap:find("[,%.;:!%?%(%)]") then
            out[#out + 1] = ","
            out.stops[#out] = gap:find("[%.;:!%?]") ~= nil
        end
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
    local madeOn = false
    for _, word in ipairs(list) do madeOn = madeOn or MADE_ON[word] == true end
    -- Positions of the "on"s that are the target of a use ("Use the rug
    -- (from the bank) on the barrel").
    local targetOn, using = {}, false
    for i, word in ipairs(list) do
        if USE_FIRST[word] then
            using = true
        elseif list.stops[i] then
            using = false
        elseif using and word == "on" then
            targetOn[i], using = true, false
        end
    end
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
        if match and COMPOUND_AFTER[list[i + #wanted] or ""] then match = false end
        if match then
            local role, determined = "object", false
            for back = i - 1, math.max(1, i - 4), -1 do
                local word = list[back]
                -- "the building with the anvil": where to go, not what to click.
                if word == "with" and PLACES_WITH[list[back - 1] or ""] then
                    role = "landmark"
                    break
                end
                if word == "," or OBJECT_WORDS[word] or (word == "on" and (madeOn or targetOn[back])) then break end
                -- "Look under the plant"; "by using the pedestal".
                if LANDMARK_WORDS[word] and (MOVE_PAST[list[back - 1] or ""] or (list[back + 1] or ""):find("ing$")) then
                    break
                end
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

-- ---------- which one of several: "the lever by the water wheel" ----------

-- Compass words as a unit direction (x east, z north).
local COMPASS = { north = { 0, 1 }, south = { 0, -1 }, east = { 1, 0 }, west = { -1, 0 },
    northeast = { 1, 1 }, northwest = { -1, 1 }, southeast = { 1, -1 }, southwest = { -1, -1 } }
-- "north-eastern", "northernmost", "eastwards" -> { 1, 1 } etc.
local function compass(word)
    if word == nil then return nil end
    word = word:gsub("%-", ""):gsub("most$", ""):gsub("wards?$", ""):gsub("ern$", "")
    return COMPASS[word]
end
Advance.Compass = compass

-- The first direction a step gives ("Run south to the farming patches",
-- "the room to the north"), as a unit direction, or nil.
function Advance.CompassIn(text)
    for word in text:lower():gmatch("[%a%-]+") do
        local dir = compass(word)
        if dir then return dir end
    end
    return nil
end
-- Places that aren't objects in the scene: "on the east side of the room"
-- means the easternmost one, not one east of some "room" object.
local AREA_WORDS = { room = true, house = true, building = true, area = true, wall = true, walls = true,
    floor = true, level = true, corner = true, side = true, part = true, ["end"] = true, cave = true,
    dungeon = true, island = true, map = true, chamber = true, hall = true, corridor = true, tower = true,
    yard = true, garden = true, camp = true, town = true, village = true, city = true, castle = true }
-- Words that end an anchor's name: "east of the water wheel to turn it green".
local ANCHOR_ENDS = { [","] = true, ["and"] = true, ["then"] = true, ["to"] = true, ["in"] = true, ["on"] = true,
    ["so"] = true, ["until"] = true, ["for"] = true, ["with"] = true, ["while"] = true, ["which"] = true,
    ["that"] = true, ["before"] = true, ["after"] = true, ["if"] = true, ["when"] = true, ["where"] = true,
    ["inside"] = true, ["of"] = true, ["at"] = true, ["from"] = true, ["into"] = true, ["you"] = true,
    ["is"] = true, ["are"] = true, ["was"] = true, ["as"] = true, ["or"] = true, ["by"] = true, ["near"] = true }
local FILLER = { just = true, directly = true, immediately = true, slightly = true, located = true, far = true,
    little = true, bit = true, a = true, the = true, found = true, situated = true, which = true, that = true,
    is = true, are = true, right = true, furthest = true, farthest = true, into = true, towards = true,
    toward = true, few = true, couple = true, tiles = true, tile = true, steps = true, squares = true }
local NEAR_WORDS = { by = true, near = true, beside = true, alongside = true, nearest = true, closest = true }
local ORDINALS = { first = 1, second = 2, third = 3, fourth = 4, fifth = 5 }
-- Words a compass word can sit before on its way to the name: "the
-- eastern strange wall", "the north-eastern small tile".
local ADJECTIVES = { strange = true, small = true, large = true, big = true, little = true, old = true, wooden = true,
    stone = true, locked = true, broken = true, metal = true, iron = true, ancient = true, odd = true, tall = true,
    short = true, long = true, dark = true, red = true, blue = true, green = true, yellow = true, white = true,
    black = true, lit = true, unlit = true, open = true, closed = true, hidden = true, secret = true, most = true,
    low = true, high = true, upper = true, lower = true, inner = true, outer = true, main = true, side = true }
-- Rooms and buildings an object is in: "the well in the room west of
-- Drezel" is west of Drezel; "the door into the north room" is north.
local ROOM_WORDS = { room = true, building = true, house = true, area = true, part = true, chamber = true }

-- Words of an anchor name starting at token i: "the water wheel" -> "water wheel".
local function anchorAt(list, i)
    while list[i] == "the" or list[i] == "a" or list[i] == "an" or list[i] == "that" or list[i] == "this"
        or list[i] == "your" do
        i = i + 1
    end
    local parts = {}
    while list[i] ~= nil and #parts < 3 and not ANCHOR_ENDS[list[i]] and not list[i]:match("^%d+$") do
        parts[#parts + 1] = list[i]
        i = i + 1
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

-- A compass direction at token k: "north-west", "south west" (two words).
-- Returns the direction and the token after it.
local function compassAt(list, k)
    local dir = compass(list[k])
    if dir == nil then return nil, k end
    local second = compass(list[k + 1])
    if dir[1] == 0 and second and second[2] == 0 and not (list[k + 1] or ""):find("ern") then
        return { second[1], dir[2] }, k + 2
    end
    return dir, k + 1
end

local function skipFiller(list, k)
    local skipped = 0
    while list[k] ~= nil and (FILLER[list[k]] or list[k] == "to" or NUMBER_WORDS[list[k]] or list[k]:match("^%d+$"))
        and skipped < 5 do
        k, skipped = k + 1, skipped + 1
    end
    return k
end

-- What follows one mention of the name (tokens from k on), or nil.
local function placementAfter(list, k)
    local onOrIn = list[k] == "on" or list[k] == "in" or list[k] == "at" or list[k] == "against"
    if onOrIn then k = k + 1 end
    k = skipFiller(list, k)
    -- "in the room west of Drezel", "in the building to the north" (that
    -- side of you).
    local inRoom = onOrIn and ROOM_WORDS[list[k]]
    if inRoom then
        k = skipFiller(list, k + 1)
        onOrIn = false
    end
    local word = list[k]
    -- "in the middle of the prison", "in the centre of the room": the one
    -- nearest the middle of them all.
    if (word == "middle" or word == "centre" or word == "center") and list[k + 1] == "of" then
        return { centre = true }
    end
    -- "second from the north": that many along from that side.
    local rank = ORDINALS[word]
    if rank and list[k + 1] == "from" then
        local dir = compassAt(list, skipFiller(list, k + 2))
        if dir then return { dir = dir, extreme = true, rank = rank } end
    end
    if word == "next" and list[k + 1] == "to" then
        local anchor = anchorAt(list, k + 2)
        if anchor and not AREA_WORDS[anchor:match("(%S+)$")] then return { anchor = anchor } end
        return nil
    elseif NEAR_WORDS[word] and not onOrIn then
        local anchor = anchorAt(list, k + 1)
        if anchor and not AREA_WORDS[anchor:match("(%S+)$")] then return { anchor = anchor } end
        return nil
    end
    local dir, after = compassAt(list, k)
    if dir == nil then return nil end
    -- "east side of the room", "south-east corner of Varrock", "the north
    -- room": the furthest that way (or that side of you, for a room).
    if AREA_WORDS[list[after]] then
        return ROOM_WORDS[list[after]] and not onOrIn and list[after + 1] ~= "of" and { dir = dir }
            or { dir = dir, extreme = true }
    end
    -- "north-west of the hatch"; "just north of you" (that side of you).
    if list[after] == "of" then
        if list[after + 1] == "you" or list[after + 1] == "yourself" then return { dir = dir } end
        local anchor = anchorAt(list, after + 1)
        if anchor == nil then return nil end
        if AREA_WORDS[anchor:match("(%S+)$")] then return { dir = dir, extreme = true } end
        return { dir = dir, anchor = anchor }
    end
    if onOrIn then return { dir = dir, extreme = true } end
    return { dir = dir }
end

-- Where in the scene `name` is meant to be, when the text says which one:
--   "the water controls east of the water wheel" -> { dir = {1,0}, anchor = "water wheel" }
--   "the lever by the water wheel"               -> { anchor = "water wheel" } (the one nearest it)
--   "the bookcase on the eastern wall", "the northern ladder", "in the
--   north-west corner"                           -> { dir = ..., extreme = true } (the furthest that way)
--   "the trough to the south"                    -> { dir = {0,-1} } (that side of the player)
-- nil when it doesn't say. The name is matched like MentionRoles (whole
-- words, plural allowed); the first mention that says which one counts.
function Advance.Placement(text, name)
    local list, wanted = tokens(text), {}
    for word in name:lower():gmatch("[%w'%-]+") do wanted[#wanted + 1] = word end
    if #wanted == 0 then return nil end
    for i = 1, #list - #wanted + 1 do
        local match = true
        for j, want in ipairs(wanted) do
            local word = list[i + j - 1]
            match = match and (word == want or (j == #wanted and (word == want .. "s" or word == want .. "es")))
        end
        if match then
            -- Before the name: "the eastern ladder", "the northern most crate",
            -- "the eastern strange wall".
            local back = i - 1
            while back >= 2 and ADJECTIVES[list[back]] and compass(list[back]) == nil and i - back <= 2 do
                back = back - 1
            end
            local before = compass(list[back])
            if list[back] == "most" then before = compass(list[back - 1]) end
            local after = placementAfter(list, i + #wanted)
            if before and after and after.extreme then
                -- "the northern most bookcase on the western wall": the wall
                -- first, then the furthest north along it.
                return { dir = { after.dir[1] * 2 + before[1], after.dir[2] * 2 + before[2] }, extreme = true }
            elseif before and (after == nil or after.anchor == nil) then
                return { dir = before, extreme = true }
            elseif after then
                return after
            end
        end
    end
    return nil
end

-- The teleport a step names itself ("via Drakan's medallion", "use the
-- Ectophial", "fairy ring code CKR"): then the plugin shouldn't argue with
-- a lodestone of its own. Returns a short phrase or nil.
local TELEPORT_ITEMS = { "drakan's medallion", "ectophial", "ring of kinship", "games necklace", "amulet of glory",
    "ring of duelling", "ring of wealth", "skull of remembrance", "ring of charos", "tokkul-zo", "tokkul zo",
    "sixth-age circuit", "wicked hood", "enchanted lyre", "pharaoh's sceptre", "slayer ring", "digsite pendant",
    "archaeology journal", "master quest cape", "quest cape", "max cape", "grace of the elves", "crystal teleport",
    "teleport seed", "spirit tree", "gnome glider", "balloon", "canoe", "magic carpet", "charter ship", "fairy ring",
    "ancient teleport", "lunar teleport", "home teleport", "teleport tablet", "teleport tab" }
function Advance.NamedTeleport(text)
    local lower = " " .. text:lower():gsub("[^%w' %-]", " "):gsub("%s+", " ") .. " "
    local code = text:match("[Ff]airy [Rr]ing.-%f[%u](%u%u%u)%f[^%u]")
    if code then return "fairy ring " .. code end
    for _, item in ipairs(TELEPORT_ITEMS) do
        local at = lower:find(" " .. item .. " ", 1, true)
        if at then
            local before = lower:sub(1, at)
            if before:find("teleport", 1, true) or before:find(" via ", 1, true) or before:find(" use ", 1, true)
                or before:find(" using ", 1, true) or before:find(" rub ", 1, true) or before:find(" with ", 1, true)
                or before:find(" take ", 1, true) or before:find(" board ", 1, true) then
                return item
            end
        end
    end
    return nil
end

-- Verbs whose click on the named object is the step: "Search the crate",
-- "Pull the lever" (app.lua finishes the step a few ticks after the click).
Advance.CLICK_VERBS = { open = true, search = true, pull = true, push = true, read = true, investigate = true,
    inspect = true, operate = true, light = true, dig = true, interact = true, touch = true, activate = true,
    turn = true, rotate = true, check = true, ring = true, knock = true, pray = true, unlock = true, repair = true,
    fix = true, click = true }
-- Game lines after such a click that mean nothing happened yet.
Advance.NOTHING_MESSAGES = { "nothing interesting", "find nothing", "found nothing", "is locked", "you need",
    "you don't have", "you do not have", "you can't", "you cannot", "nothing happens", "doesn't seem",
    "too far away", "you'll need", "you will need", "not the right", "wrong" }
-- The game's skill IDs (SkillType) by name, for requirement lists.
Advance.SKILL_NAMES = { [0] = "Attack", "Defence", "Strength", "Constitution", "Ranged", "Prayer", "Magic", "Cooking",
    "Woodcutting", "Fletching", "Fishing", "Firemaking", "Crafting", "Smithing", "Mining", "Herblore", "Agility",
    "Thieving", "Slayer", "Farming", "Runecrafting", "Hunter", "Construction", "Summoning", "Dungeoneering",
    "Divination", "Invention", "Archaeology", "Necromancy" }

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

-- Words that name a kind of person, not one person: "the guard" in a step
-- isn't the quest's "Guard captain".
local GENERIC_PEOPLE = { guard = true, guards = true, man = true, woman = true, child = true, boy = true,
    girl = true, cook = true, farmer = true, monk = true, priest = true, wizard = true, king = true, queen = true,
    soldier = true, knight = true, villager = true, elder = true, master = true, chief = true, captain = true,
    assistant = true, apprentice = true, brother = true, sister = true, father = true, mother = true }

-- Does `text` mention `name` by its first or last word alone ("Veldaban"
-- for "Commander Veldaban", "Duke" for "Duke Horacio")? Only words of four
-- letters or more that aren't a generic kind of person.
function Advance.MentionsPart(text, name)
    local first, last = name:match("^(%a+)"), name:match("(%a+)$")
    for _, word in ipairs({ first, last }) do
        if word and #word >= 4 and not GENERIC_PEOPLE[word:lower()] and word ~= name and mentions(text, word) then
            return word
        end
    end
    return nil
end

-- Is `page` written as a name in `text` (capitalised where it appears)?
-- "Talk to Point of interest" yes; "search your backpack" no.
function Advance.LooksLikeName(text, page)
    local base = Advance.BaseName(page)
    local at = text:lower():find(base, 1, true)
    if at == nil then return false end
    return text:sub(at, at):match("%u") ~= nil
end

-- Does interacting with `subject` belong to this step? True when it's one of
-- the step's linked names, or (for scenery like "trapdoor", which guides
-- rarely link) the name appears as a whole word in the step text. With
-- `strict`, not when the text only says where it is.
function Advance.StepMentions(step, subject, strict)
    subject = Advance.Clean(subject)
    if #subject < 3 then return false end
    for _, page in ipairs(step.npcs or {}) do
        if Advance.BaseName(page) == subject then return true end
    end
    for _, name in ipairs(step.inheritedNpcs or {}) do
        if Advance.BaseName(name) == subject then return true end
    end
    -- "Go to a gate south of the cave entrance": only where it is, so going
    -- into the cave isn't that step.
    local function onlyLandmark(name)
        local object, landmark = Advance.MentionRoles(step.text, name)
        return landmark > 0 and object == 0
    end
    if mentions(step.text, subject) then return not (strict and onlyLandmark(subject)) end
    -- "Talk to Veldaban" is about Commander Veldaban.
    local part = Advance.MentionsPart(step.text, subject)
    if part then return not (strict and onlyLandmark(part)) end
    return false
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
            -- Ladders, doors and the like only count for the step you're on;
            -- later steps only for what they're about, not where they are.
            if (i == current or not Advance.IsGenericScenery(part))
                and Advance.StepMentions(entries[i].step, part, i > current) then
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
    local need = { name = name, qty = tonumber(qty) or 1, label = text, parts = parts }
    need.slots = Advance.FreeSlotsWanted(need)
    return need
end

-- "3 free inventory slots during the first stage of the quest", "Free
-- inventory space": how many empty backpack slots the line asks for, nil
-- when it isn't about slots at all.
function Advance.FreeSlotsWanted(need)
    local name = need.name:lower()
    if name:match("^free%s+inventory%s+s[lp]") or name:match("^free%s+backpack%s+s[lp]")
        or name:match("^free%s+s[lp]") or name:match("^empty%s+inventory%s+s[lp]") then
        return need.qty
    end
    return nil
end

local function singular(name)
    return (name:gsub("^an?%s+", ""):gsub("^any%s+", ""):gsub("ies$", "y"):gsub("([^s])s$", "%1"))
end
Advance.Singular = singular

-- How many of an item the backpack has. `counts` maps lower-case item names
-- to totals. Plurals and "any X" match, and so do variants that contain the
-- name ("orange goblin mail" counts toward "3 goblin mail": you still have it).
-- One option of an "X or Y" line: "2 coins to purchase a pint" is 2 coins,
-- the purpose clause dropped.
function Advance.OptionNeed(option)
    local parsed = Advance.ParseNeeded((option:gsub("^an?%s+", "")))
    parsed.name = parsed.name:gsub("%s+to%s+%a+%s.*$", ""):gsub("%s+for%s+.*$", "")
    return parsed
end

function Advance.HaveCount(counts, need)
    -- "An anti-dragon shield or super antifire potion": either will do.
    -- "Beer or 2 coins to purchase a pint": each option with its own count
    -- (788 coins are 394 lots of 2).
    if need.name:find(" or ", 1, true) then
        local best = 0
        for option in (need.name .. " or "):gmatch("(.-) or ") do
            local parsed = Advance.OptionNeed(option)
            best = math.max(best, Advance.HaveCount(counts, { name = parsed.name }) // math.max(1, parsed.qty))
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
local ACQUIRE_PHRASE_VERBS = { "obtain", "get", "buy", "collect", "mine", "take", "grab", "pick up", "pick", "steal" }
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
