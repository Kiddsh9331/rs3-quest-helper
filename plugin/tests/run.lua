-- Drives the plugin through its features against mock.lua.
local results, failures = {}, 0
local function check(name, cond)
    results[#results + 1] = (cond and "PASS " or "FAIL ") .. name
    if not cond then failures = failures + 1 end
end
local function live(c)
    while c ~= nil do
        if c.destroyed then return false end
        c = c.parent
    end
    return true
end
local function findButton(label)
    for i = #M.created, 1, -1 do
        local c = M.created[i]
        if c.kind == "Button" and live(c) and c.label and c.label:find(label, 1, true) then return c end
    end
end
local function textComponent(pattern, where)
    for i = #M.created, 1, -1 do
        local c = M.created[i]
        if c.kind == "Text" and live(c) and c.hidden ~= true and type(c.content) == "string" and c.content:find(pattern)
            and (where == nil or where(c)) then return c end
    end
end
local function anyText(pattern)
    local c = textComponent(pattern)
    return c and c.content
end
-- Shown text on the step card (inside its GroupBox).
local function cardText(pattern)
    return textComponent(pattern, function(c) return c.parent and c.parent.kind == "GroupBox" end)
end
-- Palette name of a text component's colour ("red", "green", ...).
local PALETTE = { red = "c0564a", green = "7fbf4d", gold = "e7c15a", chat = "6fa8dc", muted = "a89f88", text = "e8e2d0" }
local function colourOf(c)
    if c == nil or type(c.colour) ~= "table" then return nil end
    for name, hex in pairs(PALETTE) do
        if math.abs(c.colour[1] - tonumber(hex:sub(1, 2), 16) / 255) < 0.002
            and math.abs(c.colour[2] - tonumber(hex:sub(3, 4), 16) / 255) < 0.002 then return name end
    end
end
-- Quest rows are a background, two texts and an invisible button.
local function pressQuest(name)
    for i = #M.created, 1, -1 do
        local c = M.created[i]
        if c.kind == "Text" and live(c) and c.content == name then
            for _, sibling in ipairs(c.parent.children) do
                if sibling.kind == "Button" then return sibling:Press() end
            end
        end
    end
    error("no quest row " .. name)
end
-- Settings have their own screen: open it, press `label`, come back.
-- Returns whether the button was there.
local function inSettings(label)
    M.fire("Logic")
    findButton("Settings"):Press()
    M.fire("Logic")
    local button = findButton(label)
    if button then button:Press() end
    M.fire("Logic")
    findButton("Back"):Press()
    M.fire("Logic")
    return button ~= nil
end
local function errorsLogged()
    for _, l in ipairs(M.logs) do if l:find("ERROR") or l:find("failed") then return l end end
end
local function step() return M.db.steps and M.db.steps.the_knight_s_sword end
-- Draw calls since `first` with `vertices` positions (6 = a bobbing arrow).
local function drawsWith(first, vertices)
    local n = 0
    for i = first, #M.drawn do
        if #M.drawn[i].shapePositions == vertices then n = n + 1 end
    end
    return n
end
local function shownOnLayer(kind)
    local n = 0
    for _, c in ipairs(M.layer.children) do
        if c.kind == kind and not c.destroyed and c.hidden == false then n = n + 1 end
    end
    return n
end

-- ---------- pure logic ----------
local Probe = require("probe")
check("normalise strips tags and numbering", Probe.Normalise("<col=ff0000>1. Chat</col>") == "chat")
local cands = Probe.ChatCandidates("1 Chat / 1 And how is life as a squire? / Accept")
check("chat candidates", #cands == 3 and cands[1] == "chat" and cands[2] == "andhowislifeasasquire" and cands[3] == "accept")
check("short text needs exact match", not Probe.TextMatches("chatty", "chat"))
check("long text containment", Probe.TextMatches("andhowislifeasasquire", "howislifeasasquire"))
check("a paragraph quoting an option is not a match",
    not Probe.TextMatches(Probe.Normalise("Talk to Thurgo. Chat: 2 Something else. / 2 Would you like some redberry pie?"), "somethingelse"))

local Advance = require("advance")
local stepA = { text = "Climb down the trapdoor on the hill east of Thurgo's house.", npcs = { "Thurgo" } }
check("linked name matches", Advance.StepMentions(stepA, "<col=ffff00>Thurgo</col>"))
check("scenery named in text matches", Advance.StepMentions(stepA, "Trapdoor"))
check("partial words don't match", not Advance.StepMentions(stepA, "Trap"))
check("disambiguator stripped", Advance.StepMentions({ text = "Talk to the Cook.", npcs = { "Cook (Lumbridge)" } }, "Cook"))
local need = Advance.ParseNeeded("2 Iron bars")
check("parse quantity", need.qty == 2 and need.name == "iron bars")
check("parse x quantity", Advance.ParseNeeded("Iron bar \195\1513").qty == 3)
local split = Advance.SplitNeeded("Blurite ore, 2 iron bars and a bucket")
check("split item lists", #split == 3 and split[1] == "Blurite ore" and split[2] == "2 iron bars" and split[3] == "a bucket")
check("have count handles plurals", Advance.HaveCount({ ["iron bar"] = 2 }, need) == 2)
check("acquire step", Advance.IsAcquireStep({ text = "Mine 2 blurite ore." }) and not Advance.IsAcquireStep({ text = "Talk to Thurgo." }))
local entries = { { step = { text = "Talk to Squire Asrol.", npcs = { "Squire Asrol" } } },
    { step = { text = "Talk to Reldo.", npcs = { "Reldo" } } }, { step = { text = "Talk to Thurgo.", npcs = { "Thurgo" } } } }
check("look-ahead finds a later step", Advance.MatchInteraction(entries, 1, "Talk-to", "Thurgo") == 3)
check("walk/examine ignored", Advance.MatchInteraction(entries, 1, "Examine", "Thurgo") == nil)

-- Cases from running every quest's guide through the plugin (tests/check_quests.py).
-- Talking to the squire again while on the Reldo step isn't "Return to the squire".
local again = { { step = { text = "Talk to Squire Asrol.", npcs = { "Squire Asrol" } } },
    { step = { text = "Talk to Reldo.", npcs = { "Reldo" } } }, { step = { text = "Talk to Thurgo.", npcs = { "Thurgo" } } },
    { step = { text = "Return to Squire Asrol.", npcs = { "Squire Asrol" } } } }
check("re-talking someone just met doesn't jump ahead", Advance.MatchInteraction(again, 2, "Talk-to", "Squire Asrol") == nil)
local walkBack = { { step = { text = "Talk to Doric.", npcs = { "Doric" } } }, { step = { text = "Go to Falador." } },
    { step = { text = "Talk to Doric again.", npcs = { "Doric" } } } }
check("...but can skip walking back to them", Advance.MatchInteraction(walkBack, 2, "Talk-to", "Doric") == 3)
local function finishes(text) return Advance.ClimbFinishes({ text = text }) end
check("climbing finishes climb steps", finishes("Climb down the trapdoor on the hill.")
    and finishes("Investigate the poster next to the stairs, then climb the stairs.")
    and finishes("Use the ladder to go down."))
check("climbing doesn't finish what's upstairs", not finishes("Talk to Duke Horacio upstairs in the castle.")
    and not finishes("Go upstairs and talk to Doris.") and not finishes("Search the crate next to the ladder."))
check("arriving doesn't finish 'go and talk'", Advance.TravelFinishes({ text = "Go to the Blue Moon Inn in Varrock." })
    and not Advance.TravelFinishes({ text = "Go to the inn and talk to Robin." }))
local function roles(text, name, prefix) return table.concat({ Advance.MentionRoles(text, name, prefix) }, ",") end
check("the thing to click vs a landmark", roles("Search the crate next to the chest.", "crate") == "1,0"
    and roles("Search the crate next to the chest.", "chest") == "0,1"
    and roles("Talk to Adam in Wendlewick, north of the well.", "well") == "0,1"
    and roles("Use the bird feed on the watchtower fence.", "fence") == "1,0"
    and roles("Push the west statue.", "statue") == "1,0"
    and roles("Speak to Ozan and prepare well for battle.", "well") == "0,0"
    and roles("Climb the first staircase to the west.", "stair", true) == "1,0"
    and roles("Talk to Straven near the stairs.", "stair", true) == "0,1")
-- All quests on paper (2026-10-30): what each step outlines, checked against
-- what its text acts on.
check("use ... on: the first 'on' after the verb, wherever the verb is",
    roles("Head upstairs, and use the key on the door on the south-west side.", "door") == "1,0"
    and roles("Right-click use the vacuum pump on the perch rock.", "perch rock") == "1,0"
    and roles("Use the ink bottle on the sharp rock outside on the east-most wall.", "wall") == "0,1"
    and roles("Use the old rug (you got from the bank earlier) on the barrel.", "barrel") == "1,0"
    and roles("Knock on the door.", "door") == "1,0" and roles("Stand on the white portal.", "portal") == "1,0"
    and roles("Choose the push option on the smashed globe-holder.", "smashed globe-holder") == "1,0")
check("getting past something is doing it", roles("Crawl under the wall to the north.", "wall") == "1,0"
    and roles("Jump across the pit.", "pit") == "1,0" and roles("Look under the northern potted plant.", "potted plant") == "1,0"
    and roles("Talk to Bob under the tree.", "tree") == "0,1"
    and roles("Prepare a ritual by using the pedestal.", "pedestal") == "1,0")
check("part of a longer name, or 'not', isn't the thing", roles("Return to the throne room downstairs.", "throne") == "0,0"
    and roles("Use 3 bones on the tomb doors.", "tomb") == "0,0" and roles("Use 3 bones on the tomb doors.", "door") == "1,0"
    and roles("Exit using the ladder in the south-east (not the portal).", "portal") == "0,1"
    and roles("Open the small chest against the north wall.", "wall") == "0,1"
    and roles("Smash the table to the right of the door.", "door") == "0,1")
-- Watchtower: in the cave, clicking the cave entrance isn't "Go to a gate
-- south of the 4 cave entrance" three steps on.
local caves = { { step = { text = "Enter the northeast cave, marked 3." } }, { step = { text = "Kill the ogre." } },
    { step = { text = "Enter the east cave, marked 5." } }, { step = { text = "Go to a gate south of the 4 cave entrance." } } }
check("a later step's landmark isn't clicking ahead", (Advance.MatchInteraction(caves, 1, "Enter", "Cave entrance") or 1) == 1)
local owen = { { step = { text = "Talk to Sir Vyvin, found next to Sir Owen.", npcs = { "Sir Vyvin", "Sir Owen" } } },
    { step = { text = "Talk to Sir Owen.", npcs = { "Sir Owen" } } } }
check("...but this step's own landmark still keeps you here", Advance.MatchInteraction(owen, 1, "Talk-to", "Sir Owen") == 1)
local function gets(text)
    local names = {}
    for _, item in ipairs(Advance.AcquireTargets({ text = text })) do names[#names + 1] = item.name end
    return table.concat(names, "|")
end
check("what to get: items, not places or phrases", gets("Talk to the dwarf in the Dwarven Mine (he is standing in the hallway).") == ""
    and gets("Pick up the watering can.") == "watering can" and gets("Grab the cheese off of the table.") == "cheese"
    and gets("Get to the top of the tower.") == "" and gets("Buy a beer from the bartender.") == "beer")
-- GitHub issue #3 (Cold War): stealing the cowbell didn't move the guide on.
local cowbell = { text = "Go to the west section of the Lumbridge cow field by the gate and steal a cowbell from a "
    .. "dairy cow by using the steal-cowbell option for later on in the quest." }
check("stealing something is getting it", Advance.IsAcquireStep(cowbell) and gets(cowbell.text) == "cowbell"
    and not Advance.TravelFinishes(cowbell))
-- Elemental Workshop I (session of 2026-10-29): which one of several the
-- step means, and steps that start with a place or end with something to do.
local function placement(text, name)
    local p = Advance.Placement(text, name)
    if p == nil then return "-" end
    return (p.dir and (p.dir[1] .. "," .. p.dir[2]) or "") .. (p.anchor and (" of " .. p.anchor) or "")
        .. (p.extreme and " furthest" or "") .. (p.centre and " centre" or "") .. (p.rank and (" #" .. p.rank) or "")
end
check("which one: north of you", placement("Use the weights on the statue just north of you.", "statue") == "0,1")
-- IMPROVEMENTS A2: adjectives between the direction and the name, the
-- middle one, the second from a side.
check("which one: through adjectives, the middle, second from the north",
    placement("Open the eastern strange wall.", "wall") == "1,0 furthest"
    and placement("Place Tunks on the north-eastern small tile.", "tile") == "1,1 furthest"
    and placement("Open the door in the middle of the prison.", "door") == " centre"
    and placement("Go through the door second from the north on the eastern wall.", "door") == "0,1 furthest #2")
-- IMPROVEMENTS A6: climbs read more carefully.
local function dirOf(text) return Advance.ClimbDirection({ text = text }) end
check("down means a climb down only next to the climb", dirOf("Go down the path to the ladder.") == "any"
    and dirOf("Climb down the trapdoor.") == "down" and dirOf("Go downstairs and talk to Bob.") == "down"
    and dirOf("Head down the ladder.") == "down" and dirOf("Climb up the ice.") == "up"
    and dirOf("Use the ladder in the north room.") == "any")
check("twice means two climbs", #Advance.ClimbGoals({ text = "Climb up the north-west staircase twice." }) == 2
    and #Advance.ClimbGoals({ text = "Climb up two sets of stairs." }) == 2)
check("mines isn't a verb; complete is", Advance.MainAction({ text = "Go down the ladder to enter the Dwarven mines." }) == nil
    and Advance.MainAction({ text = "Mine 2 blurite ore." }) == "mine"
    and Advance.MainAction({ text = "Mine the rocks in the cavern." }) == "mine"
    and not Advance.ClimbFinishes({ text = "Complete 1 lap of the agility course by climbing the rope ladder." }))
-- IMPROVEMENTS A7: chat written as option numbers.
check("numeric chat chains read out", Probe.ChatLabel("1 / 1") == "option 1, then option 1"
    and Probe.ChatLabel("~") == "any option" and Probe.ChatLabel("4 X") == "option 4, then any option"
    and Probe.ChatLabel("What terrible threat?") == "What terrible threat?"
    and Probe.ChatNumbers("2 What terrible threat? / Accept") == nil)
-- IMPROVEMENTS A10 and A8: the step's own teleport, picture references.
check("the teleport a step names", Advance.NamedTeleport("Teleport to the Meiyerditch Laboratories via Drakan's medallion.") == "drakan's medallion"
    and Advance.NamedTeleport("Use the Ectophial to teleport to Port Phasmatys.") == "ectophial"
    and Advance.NamedTeleport("Go to the lake (just north of fairy ring code CKR).") == "fairy ring CKR"
    and Advance.NamedTeleport("Talk to Bob near the balloon.") == nil
    and Advance.NamedTeleport("Teleport to Varrock.") == nil)
check("a step that leans on a picture", Advance.HasPictureRef("Walk to the tile as same as the picture shown below.")
    and not Advance.HasPictureRef("Search the landscape painting near the bed."))
-- IMPROVEMENTS A3: the side a travel step gives.
local function compassIn(text) local d = Advance.CompassIn(text) return d and (d[1] .. "," .. d[2]) or "-" end
check("the side a step gives", compassIn("Head inside the room to the north.") == "0,1"
    and compassIn("Run south-east to the farming patches.") == "1,-1" and compassIn("Return to Ug.") == "-")
-- IMPROVEMENTS A12 and A4: part of a name, and pages written as names.
check("part of an NPC's name", Advance.MentionsPart("Return to Veldaban.", "Commander Veldaban")
    and Advance.MentionsPart("Talk to the Duke again.", "Duke Horacio")
    and not Advance.MentionsPart("Talk to the guard.", "Guard captain")
    and not Advance.MentionsPart("Talk to Bob.", "Bob"))
check("a page written as a name", Advance.LooksLikeName("Talk to Point of interest.", "Point of interest")
    and not Advance.LooksLikeName("Search your backpack.", "backpack"))
local Card = require("card")
check("long names on the card header leave room for the counter",
    #Card.Title(string.rep("Once Upon a Time ", 5), "3 / 22") <= 59
    and Card.Title(string.rep("Once Upon a Time ", 5), "3 / 22"):find("%.%.%.  3 / 22$") ~= nil
    and Card.Title("Cook's Assistant", "1 / 5") == "Cook's Assistant  1 / 5")
check("which one: east/west of something", placement("(Red Indicator) Turn the water controls east of the water "
    .. "wheel to turn it green.", "water controls") == "1,0 of water wheel"
    and placement("Search the singular crate north-west of the hatch in the middle room.", "crate") == "-1,1 of hatch")
check("which one: next to something", placement("Pull the lever by the water wheel.", "lever") == " of water wheel"
    and placement("Search the crates next to the bed.", "crate") == " of bed")
check("which one: furthest that way", placement("Search the bookcase on the eastern wall.", "bookcase") == "1,0 furthest"
    and placement("Climb the northern ladder.", "ladder") == "0,1 furthest"
    and placement("Open the chest on the east side of the room.", "chest") == "1,0 furthest"
    and placement("Search the crate in the north-west corner of the room.", "crate") == "-1,1 furthest")
check("which one: that side of you", placement("Use the stone bowl on the lava trough to the south.", "lava trough") == "0,-1")
check("which one: rooms, distances, two-word directions",
    placement("Use the rod on the well in the room west of Drezel.", "well") == "-1,0 of drezel"
    and placement("Search the crate in the room to the west.", "crate") == "-1,0"
    and placement("After the cutscene, pass the door into the north room.", "door") == "0,1"
    and placement("Search the stacked crates two tiles east of the trapdoor.", "crate") == "1,0 of trapdoor"
    and placement("Safespot them using the rocks south west of the waypost.", "rocks") == "-1,-1 of waypost"
    and placement("Search the crates in the north-east corner of that room.", "crate") == "1,1 furthest")
check("which one: the first mention that says", placement("Optional temporal chest: Open and search the temporal "
    .. "chest in the north-east, requires level 80.", "chest") == "1,1 furthest"
    and placement("Search the northern most bookcase on the western wall.", "bookcase") == "-2,1 furthest")
check("which one: not said", placement("Search the crate.", "crate") == "-" and placement("Pull the lever.", "lever") == "-")
check("a place before the verb is still travel", Advance.TravelFinishes({ text = "In Seers' Village, go to the house "
    .. "immediately south of the anvil." }) and Advance.IsTravelStep({ text = "With the slashed book, go to the middle room." }))
check("travel with something to do doesn't finish on arrival", not Advance.TravelFinishes({ text = "Go to the building "
    .. "with the anvil and click on the northern wall to open the odd-looking wall." })
    and not Advance.TravelFinishes({ text = "Go to the western room and mine an elemental rock." })
    and Advance.TravelFinishes({ text = "Go to the open area north of the bank." }))
check("a name isn't a verb", Advance.TravelFinishes({ text = "Return to Asgarnia Smith with the book." })
    and Advance.TravelFinishes({ text = "Go to the Fight Arena." })
    and Advance.MainAction({ text = "After the cutscene, Talk to Bob." }) == "talk")
check("opening or clicking the way down is part of the climb", Advance.ClimbFinishes({ text = "Open the trapdoor." })
    and Advance.ClimbFinishes({ text = "Go upstairs (click the metallic stairs on the bottom-left)." })
    and not Advance.ClimbFinishes({ text = "Go up the ladder and crack open the safe." }))
check("made on something is the object", roles("With the slashed book, go to the middle room and smith an elemental "
    .. "shield on an anvil workbench.", "workbench") == "1,0"
    and roles("Search the bookcase on the eastern wall.", "wall") == "0,1")
check("either of two items counts", Advance.HaveCount({ ["super antifire potion"] = 1 },
    Advance.ParseNeeded("An anti-dragon shield or super antifire potion")) == 1)

-- Word wrap: "aaaa / bbbbbbbb / cccc" needs 3 lines at 10 characters,
-- though 18 characters would fit in 2 (why long steps were cut off).
local View = require("view")
check("line count wraps at word boundaries", View.LineCount("aaaa bbbbbbbb cccc", 10) == 3)
-- Proportional widths (IMPROVEMENTS B3): the four item lines that wrapped in
-- game on 2026-10-30 in a 402-unit row, wide letters and narrow ones alike.
check("wide letters wrap sooner", View.LineCount("- Armour, weapons and food. Make sure you have enough food to "
    .. "survive in battle against the monsters below.", 56, 402) == 3)
check("narrow letters fit more", View.LineCount("- 3 free inventory slots during the first stage of the quest", 56, 402) == 2
    and View.LineCount("- Any Ardougne cloak, for the Kandarin monastery Teleport.", 56, 402) == 2
    and View.LineCount("- 5 coins (0/5)", 56, 402) == 1)
check("a UTF-8 character is one glyph", View.TextWidth("caf\xc3\xa9") < View.TextWidth("cafe") + 1)
-- The game's own measuring call when the client offers it, with the
-- FontType signatures from the docs; the estimate when it doesn't.
local measured = {}
config.Font = { MUSEO_SANS_15PT_REGULAR = {
    GetStringLineCount = function(_, part, wrapWidth) measured[#measured + 1] = wrapWidth; return 4 end } }
check("GetStringLineCount is used per paragraph", View.TextHeight("one<br>two", 56, 300) == 8 * 18 + 4
    and measured[1] == 300 and measured[2] == 300)
config.Font = { MUSEO_SANS_15PT_REGULAR = {
    GetStringHeightAndLineCount = function(_, _, wrapWidth, lineSpacing)
        assert(type(wrapWidth) == "number" and type(lineSpacing) == "number")
        return 123, 5
    end } }
check("GetStringHeightAndLineCount's second value when that's all there is", View.TextHeight("x", 56, 300) == 5 * 18 + 4)
config.Font = { MUSEO_SANS_15PT_REGULAR = { GetStringLineCount = function() error("no") end,
    GetStringHeightAndLineCount = function() error("no") end } }
check("a failing font call falls back to the estimate", View.TextHeight("- 5 coins (0/5)", 56, 402) == 18 + 4)
config.Font = nil
check("picture references dropped", Advance.WithoutPictureRefs("Talk to Thurgo (pictured right, north of AIQ) now.")
    == "Talk to Thurgo (north of AIQ) now." and Advance.WithoutPictureRefs("Follow it (see the map).") == "Follow it.")

-- Path: around solid objects, around walls, through doors.
local Path = require("path")
local fence = Path.NewMap()
for x = 0, 14 do Path.AddLoc(fence, { x = x, z = 10, shape = 10, blocks = true }) end
local route = Path.Find(fence, 5, 5, 5, 15, 32)
local crossedFence = false
for _, t in ipairs(route) do crossedFence = crossedFence or (t.z == 10 and t.x >= 0 and t.x <= 14) end
check("path walks around solid objects", route[#route].x == 5 and route[#route].z == 15 and not crossedFence)
local walled, doored = Path.NewMap(), Path.NewMap()
for x = -10, 10 do
    Path.AddLoc(walled, { x = x, z = 3, shape = 0, rotation = 3, blocks = true, name = "Wall" })
    Path.AddLoc(doored, { x = x, z = 3, shape = 0, rotation = 3, blocks = true, name = x == 0 and "Door" or "Wall" })
end
local aroundWall = Path.Find(walled, 0, 0, 0, 6, 32)
check("path doesn't cross a wall", #aroundWall > 15 and aroundWall[#aroundWall].z == 6)
check("path goes through doors", #Path.Find(doored, 0, 0, 0, 6, 32) == 6)
check("path stops at the edge when the target is far", #Path.Find(Path.NewMap(), 0, 0, 0, 500, 32) == 32)

-- Teleports: far from the next place, the nearest lodestone to it.
local Travel = require("travel")
check("teleport suggested when far", (Travel.Suggest(2971, 3342, 3209, 3495) or {}).name == "Varrock")
check("no teleport when close", Travel.Suggest(3200, 3480, 3209, 3495) == nil)
check("no teleport from underground", Travel.Suggest(3040, 9580, 3001, 3144) == nil)
check("no teleport to an instance far from every lodestone", Travel.Suggest(3200, 3200, 1756, 1107) == nil)
check("a named lodestone is a place to go", (Travel.Named("Teleport to Varrock.") or {}).name == "Varrock"
    and (Travel.Named("Use the Draynor Village lodestone and run north.") or {}).x == 3105
    and Travel.Named("Talk to Reldo in Varrock.") == nil)

-- ---------- load ----------
local Quests = require("quests")
check("five quests", #Quests == 5)
-- The replay hook (tests/replay.lua) exposes the step logic; a few checks
-- below reach the quest tables through it.
RS3QB_REPLAY = {}
assert(loadfile(PLUGIN_DIR .. "/main.lua"))()
check("loaded through main.lua", M.db["diag.loadError"] == nil)
check("loaded note saved", M.db["diag.log"] and M.db["diag.log"][#M.db["diag.log"]]:find("loaded: 5 quests") ~= nil)
check("PluginShutdown is global", type(PluginShutdown) == "function")

M.fire("ContentLayerReady", { component = M.panelRoot })
check("list title", anyText("^RS3 Quest Buddy %(test%)$") ~= nil)
check("list statuses coloured like the app", anyText("^Done$") ~= nil and anyText("^Not started$") ~= nil)

-- Nothing changed: a tick doesn't redraw.
M.fire("ServerLogic") -- the first tick may build the card
local count = #M.created
M.fire("ServerLogic")
check("unchanged panel is not redrawn", #M.created == count)

-- ---------- guide ----------
pressQuest("The Knight's Sword")
check("no button label starts with <", (function()
    for _, c in ipairs(M.created) do if c.kind == "Button" and live(c) and (c.label or ""):find("^%s*<") then return false end end
    return true
end)())
check("guide title and progress", anyText("^The Knight's Sword$") ~= nil and anyText("^0 / 15$") ~= nil)
check("status shown", anyText("^Not started$") ~= nil)
check("current step in a card", anyText("^Talk to Squire Asrol") ~= nil)
check("chat in blue", colourOf(textComponent("^Chat: 1 Chat")) == "chat")
check("map coords in green", colourOf(textComponent("^Map 3001,3144$")) == "green")
check("upcoming steps listed", anyText("^Talk to Reldo") ~= nil)
check("section heading", anyText("^GETTING STARTED$") ~= nil)
check("items in red when missing", colourOf(textComponent("^%- Redberry pie")) == "red")
check("not an ironman: tradeable items say Grand Exchange", anyText("^%- Redberry pie<col=a89f88>  %(Grand Exchange%)</col>$") ~= nil
    and anyText("^from <col=c0564a>Uncooked berry pie</col>") == nil)
check("items split with quantities", colourOf(textComponent("^%- 2 iron bars %(0/2%)$")) == "red")
check("card title", findButton("The Knight's Sword  1 / 15") ~= nil)

findButton("Show debug"):Press()
check("live config chosen over deprecated copy", anyText("Quest config Q5 #5, deprecated false") ~= nil)
check("progress var readable", anyText("Progress var QUEST_KNIGHTS_SWORD = 0") ~= nil)

-- World: tile marker + head arrow + beacon. 240 tiles from the squire,
-- a teleport is suggested instead of a path of dots.
M.fire("ServerLogic")
check("npc marker placed", M.entities["rs3qb-marker-1"] and M.entities["rs3qb-marker-1"].visible)
check("tile beacon at Map coords", M.entities["rs3qb-tile"] and M.entities["rs3qb-tile"].coordGrid[2] == 2975 // 64)
check("far away: teleport suggested on the card", cardText("^Teleport: Falador lodestone, then about %d+ tiles on foot%.$") ~= nil)
M.fire("Logic")
check("far away: teleport text under the player", textComponent("^Teleport to Falador lodestone$",
    function(c) return c.dynamicID == 90 and c.parent == M.layer end) ~= nil)
M.fire("Draw")
check("far away: only the head arrow, no dots", M.draws == 1 and drawsWith(1, 6) == 1)

-- Closer: the dotted path, one dot per tile, up to 24 ahead.
M.player.position = { x = 2975 * 512 + 256, y = 0, z = 3315 * 512 + 256 }
M.fire("ServerLogic")
M.fire("Logic")
check("close: teleport hint gone", cardText("^Teleport:") == nil
    and textComponent("^Teleport to", function(c) return c.dynamicID == 90 end) == nil)
local firstDraw = #M.drawn + 1
M.fire("Draw")
local path = M.drawn[#M.drawn]
check("close: head arrow + dotted path drawn", drawsWith(firstDraw, 6) == 1 and #path.shapePositions == 24 * 4
    and #path.shapeTris == 24 * 6)
check("path dots rest on the ground", path.shapePositions[1].y == 324)
check("path heads for the destination", path.shapePositions[#path.shapePositions].z > 3335 * 512)
check("path dots stay bright ahead", path.shapeRGBA[#path.shapeRGBA] & 0xFF >= 0xB0)
check("path dots medium by default", path.shapePositions[3].x - path.shapePositions[1].x == 180)
inSettings("Dots: medium")
firstDraw = #M.drawn + 1
M.fire("Draw")
path = M.drawn[#M.drawn]
check("dots button cycles to large", M.db.prefs.dots == "large" and path.shapePositions[3].x - path.shapePositions[1].x == 260)
inSettings("Dots: large")
inSettings("Dots: small")
check("dots button cycles round", M.db.prefs.dots == "medium")
-- The marker and teleport hints can be switched off on their own.
inSettings("Marker: on")
M.fire("ServerLogic")
check("marker setting hides the tile marker", M.db.prefs.beacon == false and M.entities["rs3qb-tile"].visible == false)
inSettings("Marker: off")
M.player.position = { x = 3001 * 512, y = 0, z = 3100 * 512 }
inSettings("Teleport hints: on")
M.fire("ServerLogic")
check("teleport hints can be switched off", M.db.prefs.teleport == false and cardText("^Teleport:") == nil)
inSettings("Teleport hints: off")
M.fire("Logic")
findButton("Settings"):Press()
M.fire("Logic")
check("settings credit the wiki", anyText("RuneScape Wiki %(runescape%.wiki%), CC BY%-NC%-SA 3%.0") ~= nil)
check("settings say what recording keeps", anyText("Nothing is sent anywhere") ~= nil)
findButton("Back"):Press()
M.fire("Logic")
check("back from settings to the guide", findButton("Quest list") ~= nil)
M.player.position = { x = 2975 * 512 + 256, y = 0, z = 3341 * 512 + 256 }
M.fire("ServerLogic")
check("beacon hidden once close", M.entities["rs3qb-tile"].visible == false)
M.player.position = { x = 3001 * 512, y = 0, z = 3100 * 512 }
M.fire("ServerLogic")

-- Talking to the squire then accepting the quest moves to step 2.
M.select("Talk-to", "<col=ffff00>Squire Asrol</col>")
M.knightsSword.started = true
M.questVar.value = 1
M.fire("VarTransmit")
check("progress after engaged step advances", step() == 2 and anyText("quest progress moved") ~= nil)
check("var change logged", M.db.varLog.the_knight_s_sword[1] == "step 1: 0 -> 1")
M.fire("ServerLogic")
check("status reads started", anyText("^Started$") ~= nil and anyText("^1 / 15$") ~= nil)

-- Talk-to opened a new interface: it's learned as the dialogue. As in game,
-- the numbers are labels of their own; a tooltip that opened at the same
-- time (seen in a recording) isn't learned.
M.interfaces[1188] = { [3] = M.label("1.", 380), [4] = M.label("Chat", 400), [5] = M.label("2.", 380),
    [6] = M.label("About the Task System...", 400) }
M.interfaces[1486] = { [1] = M.label("Tooltip text", 10) }
M.fire("ServerLogic")
check("conversation interface learned", M.db.dialogInterfaces3 and M.db.dialogInterfaces3[1] == 1188)
check("tooltip not learned as dialogue", #M.db.dialogInterfaces3 == 1)
check("conversation reported", anyText("Conversation opened DIALOGUE_OPTIONS: 1%. | Chat") ~= nil)
M.interfaces[1188], M.interfaces[1486] = nil, nil

-- A UI reload (end of a cutscene) opening many interfaces isn't learned.
M.select("Talk-to", "Guard") -- someone the guide doesn't mention, so no step change
for i = 2500, 2510 do M.interfaces[i] = { [1] = M.label("Basic Ability", 10) } end
M.fire("ServerLogic")
check("mass interface reload not learned as dialogue", #M.db.dialogInterfaces3 == 1)
for i = 2500, 2510 do M.interfaces[i] = nil end
-- The numbered options come up a "Continue" or two after the chat head
-- (beta: option 2 never turned blue): the watch restarts on Continue.
M.select("Continue", "", 1)
M.interfaces[1190] = { [1] = M.label("1.", 380), [2] = M.label("Yes please", 400) }
M.fire("ServerLogic")
check("options opened after Continue are learned", #M.db.dialogInterfaces3 == 2 and M.db.dialogInterfaces3[2] == 1190)
M.interfaces[1190] = nil

-- Skipping ahead: talking to Thurgo (step 3) jumps there.
M.select("Talk-to", "Thurgo")
check("look-ahead jump to step 3", step() == 3 and anyText("you used thurgo") ~= nil)

-- Options in the learned interface turn blue (no arrow, no box); the
-- panel's own text is never touched.
local holder = M.label("", 0)
holder.type = nil
local option = M.label("2 Something else.", 300)
option.staticID, option.interfaceID, option.colour = 7, 1188, "original"
-- The option's button carries the same text; recolouring it tints the
-- whole button (the blue box seen in game), so it must be left alone.
local optionButton = M.label("", 300)
optionButton.type, optionButton.label, optionButton.colour = ui.ComponentType.BUTTON, "2 Something else.", "button"
optionButton.staticID, optionButton.interfaceID, optionButton.dynamicID = 7, 1188, 2
holder.dynamic = { optionButton, option }
M.interfaces[1188] = { [7] = holder }
M.interfaces[1604] = { [1] = M.label("Chat: 2 Something else. / 2 Would you like some redberry pie?") }
M.fire("ServerLogic")
check("dialogue option turned blue", type(option.colour) == "table" and option.colour[3] == 1.0)
check("the option's button isn't tinted", optionButton.colour == "button")
check("no arrow or box drawn round the option", shownOnLayer("Line") == 0 and shownOnLayer("Rectangle") == 0)
findButton("Scan dialogue"):Press()
check("scan ignores the plugin's own panel", anyText("in interface 1604") == nil and anyText("Matched: \"2 Something else.\"") ~= nil)
M.interfaces[1188] = nil
M.fire("ServerLogic")
check("option colour restored when the conversation closes", option.colour == "original")

-- Ticking the current step's checkbox (the first unticked one) moves the guide.
for i = 1, #M.created do
    local c = M.created[i]
    if c.kind == "Check" and live(c) and not c.value then
        c.value = true
        c:Press()
        break
    end
end
check("checkbox ticks the step", step() == 4)

-- Backpack: item checks turn green.
M.backpack = { { "Redberry pie", 1 } }
M.fire("InventoryUpdated")
M.fire("ServerLogic")
check("used-up item hidden after its last step (pie handed over at step 3)", anyText("%- Redberry pie") == nil)

-- Quest completion jumps to the end.
M.knightsSword.finished = true
M.fire("ServerLogic")
check("quest complete finishes the guide", step() == 16 and anyText("All steps done") ~= nil)

-- Card moves: click title, move mouse, click again; position saved.
local header = findButton("The Knight's Sword  15 / 15")
header:Press()
check("card picked up", header.label:find("click to drop") ~= nil)
M.mouse.x, M.mouse.y = 700, 450
M.fire("Logic")
M.fire("Logic") -- presses are debounced per logic tick
header:Press()
check("card dropped and saved", M.db.cardPosition and M.db.cardPosition.x == 200 and M.db.cardPosition.y == 150)

-- Wiki fetch.
findButton("Wiki fetch"):Press()
check("wiki path encoded", M.lastUrl == "https://runescape.wiki/w/The_Knight%27s_Sword/Quick_guide?action=raw")
check("wiki report", anyText("Wiki fetch OK: HTTP 200") ~= nil)

-- Regression: hundreds of redraws never run past the 4096 dynamic IDs.
for _ = 1, 300 do
    M.fire("Logic")
    findButton("Hide debug"):Press()
    M.fire("Logic")
    findButton("Show debug"):Press()
end
check("panel IDs stay in range after 600 redraws", M.maxDynamicID < 4096)

-- Toggles and navigation.
check("auto toggled", inSettings("Auto: on") and M.db.prefs.auto == false)
inSettings("Card: on")
check("card toggled off", M.db.prefs.card == false)
M.fire("Logic")
findButton("Back"):Press()
check("back works", step() == 15)
M.fire("Logic")
findButton("Quest list"):Press()
check("back to list", anyText("^Priest in Peril$") ~= nil)

-- ---------- Goblin Diplomacy, replaying the in-game test ----------
pressQuest("Goblin Diplomacy")
inSettings("Auto: off") -- switched off earlier in the test
inSettings("Card: off") -- likewise
local function gd() return M.db.steps.goblin_diplomacy end
check("GD item explanations hidden until asked", anyText("Red dye is a dye made from 3 redberries") == nil)
findButton("Ironman: off"):Press()
check("ironman setting saved", M.db.prefs.ironman == true and findButton("Ironman: on") ~= nil)
check("GD recipes shown for ironmen", anyText("^from <col=c0564a>Red dye</col> %+ <col=c0564a>Yellow dye</col>$") ~= nil)
check("GD recipe follows missing materials down", anyText("^Red dye: from <col=c0564a>3 Redberries</col> %+ <col=c0564a>5 Coins</col> %(Aggie%)$") ~= nil)
findButton("Item descriptions"):Press()
check("GD item explanation shown when missing", anyText("Red dye is a dye made from 3 redberries") ~= nil)
check("GD step 1 navigates to the Goblin Village", M.db["diag.stepTargets"]:find("nav=2956,3502") ~= nil)

-- Arriving at the village completes the travel step.
M.player.position = { x = 2956 * 512, y = 0, z = 3502 * 512 }
M.fire("ServerLogic")
check("arrival completes the travel step", gd() == 2)

-- Talking to a general: progress rises and the step completes. Beta
-- (Fight Arena): the var moved for cutscenes and arena stages, ticking
-- "Talk to Hengrad" before anyone talked to him. So a move on a talk step
-- waits for a Talk-to on that NPC.
M.questVar.value = 13 -- one rise, like the real 0 -> 3
M.fire("VarTransmit")
check("progress on a talk step waits for the talk", gd() == 2)
M.select("Talk-to", "<col=ffff00>General Wartface</col>")
check("...and the talk then completes it", gd() == 3 and anyText("then you talked to general wartface") ~= nil)

-- Step 3's sub-bullets name the ladder; crates are in the main text.
M.locs = { M.loc("Ladder", "ladder-tile", { "Climb-up" }), M.loc("Crate", "crate-tile", { "Search" }),
    M.loc("Bench", "bench-tile", {}) }
M.fire("ServerLogic")
check("ladder from a sub-bullet and crates outlined", M.db["diag.marked"] == "loc Ladder, loc Crate")
local firstDraw = #M.drawn + 1
M.fire("Draw")
check("objects get a bobbing arrow like NPCs", drawsWith(firstDraw, 6) == 2)
check("Bring: doesn't repeat what the step gets", findButton("Goblin Diplomacy  3 / 8") ~= nil
    and (function()
        for i = #M.created, 1, -1 do
            local c = M.created[i]
            if c.kind == "Text" and c.parent and c.parent.kind == "GroupBox" and not c.destroyed then
                return not c.content:find("Bring:")
            end
        end
    end)())
-- IMPROVEMENTS A9: a list step ("...from the following crates:") ticks its
-- sub-bullets one Alt+D at a time; the last one moves the step on.
check("list step: the first place is next", cardText("^> Behind the generals' hut%.$") ~= nil)
M.fire("KeyDown", { gameKey = GameKey.D, modifiers = ModifierKey.ALT, isRepeat = false })
check("Alt+D ticks a place, not the step", gd() == 3 and cardText("^%[done%] Behind the generals' hut%.$") ~= nil
    and cardText("^> Behind the western hut%.$") ~= nil and anyText("1 of 3 done") ~= nil)
M.fire("KeyDown", { gameKey = GameKey.D, modifiers = ModifierKey.ALT, isRepeat = false })
check("second place ticked", gd() == 3 and cardText("^> Up a ladder") ~= nil)
M.locs = {}

-- Grabbing three goblin mail completes the crates step.
M.backpack = { { "Goblin mail", 1, 501 }, { "Goblin mail", 1, 501 }, { "Goblin mail", 1, 501 },
    { "Red dye", 1, 502 }, { "Yellow dye", 1, 503 }, { "Blue dye", 1, 504 } }
M.fire("InventoryUpdated")
check("three goblin mail completes the acquire step", gd() == 4)
check("goblin mail and dyes now green", colourOf(textComponent("^%- 3 suits of goblin mail %(3/3%)$")) == "green"
    and colourOf(textComponent("^%- Blue dye$")) == "green")

-- Step 4 dyes: the backpack icons of goblin mail and dyes get outlined.
M.interfaces[1473] = { [1] = M.sprite(501, 600), [2] = M.sprite(504, 640), [3] = M.sprite(999, 680) }
for _ = 1, 12 do M.fire("ServerLogic") end -- the full backpack scan is throttled
check("items to use outlined in the backpack", shownOnLayer("Rectangle") == 2)

-- Dyeing both: the make step completes once the next steps' items exist.
M.backpack = { { "Orange goblin mail", 1, 505 }, { "Blue goblin mail", 1, 506 }, { "Goblin mail", 1, 501 } }
M.fire("InventoryUpdated")
check("dyeing completes the make step", gd() == 5)
check("dyes hidden once turned into mail", anyText("Blue dye") == nil and anyText("Orange dye") == nil
    and anyText("red dye") == nil)

-- Step 5 "use ... on one of the generals": the generals are borrowed from step 2.
check("generals inherited for 'one of the generals'", M.db["diag.stepTargets"]:find("General Bentnoze") ~= nil)
M.npcs["General Wartface"] = { { config = { gridSize = 1 }, coordGrid = "tile-g", isValid = true,
    aabb = { minimum = { x = 0, y = 0, z = 0 }, maximum = { x = 1, y = 1, z = 1 }, centre = { x = 0, y = 0, z = 0 } },
    position = { x = 2957 * 512, y = 0, z = 3513 * 512 } } }
M.fire("ServerLogic")
check("generals highlighted on the use step", M.entities["rs3qb-marker-1"].visible and M.entities["rs3qb-marker-1"].coordGrid == "tile-g")

-- The cutscene steps complete as progress rises (a while after the dyeing:
-- the var moving right after an item step is that same event).
local function later() for _ = 1, 5 do M.fire("ServerLogic") end end
later()
for value = 14, 16 do
    M.questVar.value = value
    M.fire("VarTransmit")
end
check("steps 5-7 complete with progress", gd() == 8)

-- After the orange mail is handed over, 2 goblin mail are enough.
findButton("Back"):Press()
findButton("Back"):Press() -- step 6: the orange suit has been given away
M.backpack = { { "Blue goblin mail", 1, 506 }, { "Goblin mail", 1, 501 } }
M.fire("InventoryUpdated")
M.fire("ServerLogic")
check("goblin mail count drops as suits are handed over",
    colourOf(textComponent("^%- 3 suits of goblin mail %(2/2%)$")) == "green")

-- Cutscenes: the interface collapses, our overlays hide, then come back.
local function cardHeader()
    for i = #M.created, 1, -1 do
        local c = M.created[i]
        if c.kind == "Button" and c.parent and c.parent.kind == "GroupBox" and live(c) then return c end
    end
end
for i = 2000, 2040 do M.interfaces[i] = {} end
for _ = 1, 30 do M.fire("ServerLogic") end
check("card shown before the cutscene", cardHeader() ~= nil and not cardHeader().parent.hidden)
check("card on step 6", cardHeader().label:find("6 / 8", 1, true) ~= nil)
for i = 2000, 2040 do M.interfaces[i] = nil end
M.fire("ServerLogic")
local cardBox = cardHeader().parent
check("cutscene hides the card", cardBox.hidden == true)
M.fire("Draw")
local drawsDuring = M.draws
M.fire("Draw")
check("cutscene stops world drawing", M.draws == drawsDuring)
check("cutscene noted in diagnostics", (function()
    for _, line in ipairs(M.db["diag.log"]) do if line:find("cutscene started") then return true end end
end)())
for i = 2000, 2040 do M.interfaces[i] = {} end
M.fire("ServerLogic")
check("card back after the cutscene", cardBox.hidden == false)

-- ---------- Vampyre Slayer, replaying the in-game test ----------
findButton("Quest list"):Press()
pressQuest("Vampyre Slayer")
local function vs() return M.db.steps.vampyre_slayer end
local function targets() return M.db["diag.stepTargets"] end
check("VS recommended items listed", anyText("^RECOMMENDED$") ~= nil and anyText("Holy symbol") ~= nil)
check("VS required items listed", anyText("Beer or 2 coins to purchase a pint") ~= nil)
-- Coins live in the money pouch (beta: "5 coins (0/5)" stayed red with 788
-- in the pouch); "3 free inventory slots" is checked against the backpack.
check("free slot lines are a slot count", Advance.ParseNeeded("3 free inventory slots during the first stage").slots == 3
    and Advance.ParseNeeded("Free inventory space").slots == 1 and Advance.ParseNeeded("5 coins").slots == nil)
check("coins line red without coins", colourOf(textComponent("^%- Beer or 2 coins")) == "red")
M.pouch = 788
M.fire("InventoryUpdated")
M.fire("ServerLogic")
check("money pouch coins count", colourOf(textComponent("^%- Beer or 2 coins")) == "green"
    and M.db["diag.moneyPouch"] == "MONEY_POUCH")
M.pouch = 0
M.fire("InventoryUpdated")
M.fire("ServerLogic")
check("coins line red again when the pouch empties", colourOf(textComponent("^%- Beer or 2 coins")) == "red")
-- IMPROVEMENTS C2: the game's own requirements at the top of the guide.
check("requirements from the game's quest data", anyText("^REQUIREMENTS$") ~= nil
    and colourOf(textComponent("^%- 10 Strength %(you: 5%)$")) == "red"
    and colourOf(textComponent("^%- Goblin Diplomacy$")) == "green" and anyText("^%- 3 quest points$") ~= nil)

M.questVar.value = 20 -- talking to Morgan starts the quest
M.fire("VarTransmit")
check("VS step 1 held without a talk", vs() == 1)
for _ = 1, 200 do M.fire("ServerLogic") end
check("...a held move counts after a while", vs() == 2 and anyText("no talk on Morgan seen") ~= nil)
-- "Talk to Angor in the bar": the bar is where, not what to click.
local barObject, barLandmark = Advance.MentionRoles("Talk to Angor in the bar to the west, and buy a brew.", "bar")
check("'in the bar' is a landmark", barObject == 0 and barLandmark == 1)
-- "The cell door north of Lazy Khazard Guard": the guard isn't highlighted
-- but anchors the placement; any door near the spot is outlined.
local inside = RS3QB_REPLAY.inside
local vsQuest = inside.currentQuest()
local vsList = inside.flatSteps.vampyre_slayer
vsList[#vsList + 1] = { step = { text = "Use the keys on Sammy's cell door north of Morgan.", npcs = { "Morgan" } },
    index = #vsList + 1, section = vsList[1].section }
local doorTargets = inside.stepTargets(vsQuest, #vsList)
check("a landmark NPC isn't a target", #doorTargets.npcs == 0 and doorTargets.landmarks[1] == "Morgan"
    and doorTargets.nav ~= nil)
local doorMatch = inside.fallbackMatcher(vsQuest, #vsList)
local savedPos = M.player.position
M.player.position = { x = doorTargets.nav.x * 512, y = 0, z = doorTargets.nav.y * 512 }
M.fire("ServerLogic") -- World notes where the player stands
check("a use-on-door step outlines doors there", doorMatch ~= nil and doorMatch({ displayName = "Prison door" })
    and not doorMatch({ displayName = "Trapdoor" }))
M.player.position = savedPos
vsList[#vsList] = nil
-- "Buy a bottle of Khali brew for five coins": the coins are the price.
local wants = inside.acquireWants(vsQuest, { step = { text = "Talk to the barman and buy a beer for 2 coins.", npcs = { "beer" } }, index = 4 })
local wantNames = {}
for _, w in ipairs(wants) do wantNames[#wantNames + 1] = w.name end
local joined = "," .. table.concat(wantNames, ",") .. ","
check("coins paid aren't a wanted item", joined:find(",beer,", 1, true) ~= nil and joined:find("coin", 1, true) == nil)

-- "Go upstairs ... to get a garlic": arriving isn't enough, the garlic is.
M.player.position = { x = 3096 * 512, y = 0, z = 3270 * 512 }
M.player.coordGrid.level = 0
M.fire("ServerLogic")
check("garlic step waits for the garlic", vs() == 2)
-- All quests on paper (2026-10-30): a step that climbs outlined only the
-- stairs, so upstairs nothing at all. Downstairs the stairs up (the drawers
-- are upstairs); upstairs only the drawers, not the stairs back down.
M.locs = { M.loc("Staircase", "stairs-1", { "Climb-up" }), M.loc("Drawers", "drawers-1", { "Search" }) }
M.fire("ServerLogic")
check("climb step: the stairs up first", M.db["diag.marked"] == "loc Staircase")
M.player.position = { x = 3096 * 512, y = 0, z = 3271 * 512 }
M.player.coordGrid.level = 1
M.locs = { M.loc("Staircase", "stairs-1", { "Climb-down" }), M.loc("Drawers", "drawers-1", { "Search" }) }
M.fire("ServerLogic")
M.fire("ServerLogic")
check("...upstairs, only the drawers", vs() == 2 and M.db["diag.marked"] == "loc Drawers")
M.locs = {}
M.player.coordGrid.level = 0
M.backpack = { { "Garlic", 1, 601 } }
M.fire("InventoryUpdated")
check("garlic completes the step", vs() == 3)

-- "Go to the Blue Moon Inn located in Varrock": the inn, not Varrock's centre.
check("inn beats town as destination", targets():find("nav=3225,3398") ~= nil)
M.player.position = { x = 3225 * 512, y = 0, z = 3398 * 512 }
M.fire("ServerLogic")
check("standing in the inn completes the travel step", vs() == 4)

-- "buy a beer": the beer completes it.
M.backpack = { { "Garlic", 1, 601 }, { "Beer", 1, 602 } }
M.fire("InventoryUpdated")
check("beer completes the buy step", vs() == 5)

later()
M.questVar.value = 21 -- Dr Harlow
M.fire("VarTransmit")
check("Harlow's progress waits for the talk", vs() == 5)
M.questVar.value = 22
M.fire("VarTransmit")
check("a second move while waiting counts, one step only", vs() == 6 and anyText("quest progress moved twice") ~= nil)
M.backpack = { { "Garlic", 1, 601 }, { "Stake", 1, 603 }, { "Stake hammer", 1, 604 } }
M.fire("InventoryUpdated")
check("stake and stake hammer complete the step", vs() == 7)

-- Draynor Manor: travel, then doors are outlined and going through completes.
check("manor is the destination", targets():find("nav=3113,3356") ~= nil)
M.player.position = { x = 3113 * 512, y = 0, z = 3356 * 512 }
M.locs = { M.loc("Large door", "door-tile", { "Open" }), M.loc("Draynor Village sign", "sign-tile", { "Read" }) }
M.fire("ServerLogic")
check("arrival at the manor", vs() == 8)
M.fire("ServerLogic")
check("doors outlined on the enter step", M.db["diag.marked"] == "loc Large door")
M.select("Open", "Large door", 3)
check("going through the door completes it", vs() == 9)

-- "Walk down the stairs": only the staircase that goes down is outlined.
M.locs = { M.loc("Staircase", "up-tile", { "Climb-up" }), M.loc("Staircase", "down-tile", { "Walk-down" }) }
M.fire("ServerLogic")
local second = M.entities["rs3qb-marker-2"]
check("only the down staircase outlined", M.entities["rs3qb-marker-1"].coordGrid == "down-tile"
    and not (second and second.visible))
M.player.position = { x = 3113 * 512, y = 0, z = 9756 * 512 } -- the basement is far away on the map
M.fire("ServerLogic")
check("going down the stairs completes it", vs() == 10)

-- "Open the coffin": clicking the step's own object finishes it a few ticks
-- later (IMPROVEMENTS A1), unless the game says nothing happened.
M.locs = { M.loc("Coffin", "coffin-tile", { "Open" }) }
M.fire("ServerLogic")
check("coffin outlined", M.db["diag.marked"] == "loc Coffin")
-- Without chat access the "You need..." line can't cancel it, so no guess.
M.perms.chatAccess = false
M.select("Open", "Coffin", 3)
for _ = 1, 4 do M.fire("ServerLogic") end
check("no chat access, no own-click finish", vs() == 10)
M.perms.chatAccess = true
-- "With thread and leather, fix the bellows" (EW1, beta session 5): a step
-- that names items is finished by the game, not the click.
local coffinEntry = RS3QB_REPLAY.inside.flatSteps.vampyre_slayer[10]
local savedNpcs = coffinEntry.step.npcs
coffinEntry.step.npcs = { "garlic" }
coffinEntry.targets = nil
M.select("Open", "Coffin", 3)
for _ = 1, 4 do M.fire("ServerLogic") end
check("a step that names an item isn't finished by the click", vs() == 10)
coffinEntry.step.npcs = savedNpcs
coffinEntry.targets = nil
M.select("Open", "Coffin", 3)
M.fire("ChatMessage", { chatMessage = "The coffin is locked.", chatType = 0 })
for _ = 1, 4 do M.fire("ServerLogic") end
check("'locked' cancels the click", vs() == 10)
M.select("Open", "Coffin", 3)
M.fire("ServerLogic")
check("the click settles first", vs() == 10)
for _ = 1, 3 do M.fire("ServerLogic") end
check("opening the coffin finishes the step", vs() == 11 and anyText("you clicked the coffin") ~= nil)
M.questVar.value = 25
M.fire("VarTransmit")
check("the var moving right after is the same event", vs() == 11)
M.locs = {}

-- The fight step tells you what to bring, and ends on the kill message.
check("fight step lists combat kit", anyText("^Bring:$") ~= nil and anyText("^%- Holy symbol.*%(recommended%)$") ~= nil
    and anyText("some food may be required") ~= nil)
M.fire("ChatMessage", { chatMessage = "You have slain the vampyre.", chatType = 0 })
check("kill message completes the fight step", vs() == 12)

-- "Return to Morgan." isn't linked, but Morgan is known from step 1.
check("Morgan found for the return step", targets():find("npcs=Morgan") ~= nil and targets():find("nav=3098,3268") ~= nil)

-- Alt+D completes a step from in game.
M.fire("KeyDown", { gameKey = GameKey.D, modifiers = ModifierKey.ALT, isRepeat = false })
check("Alt+D completes the step", vs() == 13)
M.fire("KeyDown", { gameKey = GameKey.D, modifiers = 0, isRepeat = false })
check("plain D does nothing", vs() == 13)

-- ---------- scrolling and restart ----------
local function panelBody()
    for i = #M.panelRoot.children, 1, -1 do
        local c = M.panelRoot.children[i]
        if c.kind == "Panel" and not c.destroyed then return c end
    end
end
M.panelRoot.height = 200 -- a short panel, so the guide overflows
;(findButton("Show debug") or findButton("Hide debug")):Press() -- redraw at the new height
local body = panelBody()
for _ = 1, 100 do M.panelRoot.hooks["wheel"](M.panelRoot, -1) end -- start at the top
M.panelRoot.hooks["wheel"](M.panelRoot, 1)
local wheelStep = math.max(40, math.floor((200 - 16) / 4))
check("wheel scrolls the panel content up", body.y == 8 - wheelStep)
for _ = 1, 100 do M.panelRoot.hooks["wheel"](M.panelRoot, 1) end
check("scrolling stops at the end of the content", body.y > -10000 and body.y < 8 - wheelStep)
local bottom = body.y
for _ = 1, 100 do M.panelRoot.hooks["wheel"](M.panelRoot, -1) end
check("scrolling back stops at the top", body.y == 8 and bottom < 8)
M.panelRoot.height = 900

findButton("Restart quest"):Press()
check("restart asks for a second click", vs() == 13 and findButton("Click again to restart") ~= nil)
findButton("Click again to restart"):Press()
check("restart goes back to step 1", vs() == 1 and anyText("Restarted from step 1") ~= nil
    and M.db.varLog.vampyre_slayer == nil)

-- Like the live list: every step is shown, and the panel follows the current one.
check("all steps listed", anyText("^Return to Morgan") ~= nil and anyText("^Open the coffin") ~= nil)
M.panelRoot.height = 200
findButton("Done, next"):Press()
findButton("Done, next"):Press()
findButton("Done, next"):Press()
check("panel scrolls to the current step", panelBody().y < 8)
-- IMPROVEMENTS C1: opening a quest shows the top (status, items needed),
-- not the current step; later step changes still scroll to the step.
findButton("Quest list"):Press()
pressQuest("Vampyre Slayer")
check("reopening a quest shows the top, not the current step", vs() == 4 and panelBody().y == 8)
findButton("Done, next"):Press()
check("...and the next step change scrolls to it again", vs() == 5 and panelBody().y < 8)
-- IMPROVEMENTS B5: the list comes back where it was; "Current step" jumps.
findButton("Quest list"):Press()
M.panelRoot.hooks["wheel"](M.panelRoot, 1)
M.panelRoot.hooks["wheel"](M.panelRoot, 1)
local listY = panelBody().y
check("list scrolled", listY < 8)
pressQuest("Vampyre Slayer")
check("guide opens at the top", panelBody().y == 8)
findButton("Current step"):Press()
check("Current step scrolls to the step", panelBody().y < 8)
findButton("Quest list"):Press()
check("the list comes back where it was", panelBody().y == listY)
check("a scroll bar shows how far down the view is", (function()
    for i = #M.created, 1, -1 do
        local c = M.created[i]
        if c.kind == "Rectangle" and live(c) and c.parent == M.panelRoot and c.hidden ~= true and c.w == 4 then return true end
    end
end)())
-- IMPROVEMENTS B7: status filters and letter jumps on the list.
findButton("> All"):Press()
findButton("Done"):Press()
check("Done filter: only finished quests", M.db.prefs.listFilter == "done" and anyText("^Goblin Diplomacy$") ~= nil
    and anyText("^Vampyre Slayer$") == nil)
findButton("Started"):Press()
check("Started filter", anyText("^Vampyre Slayer$") ~= nil and anyText("^Goblin Diplomacy$") == nil)
findButton("All"):Press()
findButton("U-Z"):Press()
check("letter jump scrolls the list", panelBody().y < 8)
for _ = 1, 100 do M.panelRoot.hooks["wheel"](M.panelRoot, -1) end
pressQuest("Vampyre Slayer")
-- IMPROVEMENTS B2: the panel redraws after a resize settles.
local bodyBefore = panelBody()
M.panelRoot.width = 300
M.panelRoot.hooks["resize"](M.panelRoot)
for _ = 1, 9 do M.fire("ServerLogic") end
check("not yet redrawn while resizing", panelBody() == bodyBefore)
for _ = 1, 2 do M.fire("ServerLogic") end
check("redrawn once the resize settles", panelBody() ~= bodyBefore and not bodyBefore.destroyed == false)
M.panelRoot.width = 420
M.panelRoot.hooks["resize"](M.panelRoot)
for _ = 1, 12 do M.fire("ServerLogic") end
M.panelRoot.height = 900
findButton("Mark complete"):Press()
check("mark complete finishes the guide", vs() == 14 and anyText("All steps done") ~= nil)
findButton("Hide overview"):Press()
check("overview can be hidden", anyText("^RECOMMENDED$") == nil and findButton("Show overview") ~= nil)
findButton("Show overview"):Press()
check("overview comes back", anyText("^RECOMMENDED$") ~= nil)

-- IMPROVEMENTS B1: the card sizes itself from the screen and stays on it.
local function cardBox()
    for i = #M.created, 1, -1 do
        local c = M.created[i]
        if c.kind == "GroupBox" and live(c) then return c end
    end
end
check("unknown screen: the default card width", cardBox() ~= nil and cardBox().w == 480)
M.layer.width, M.layer.height = 2000, 1000
M.db.cardPosition = { x = 1900, y = 950 }
M.fire("WindowSizeChanged", { newWidth = 2000, newHeight = 1000 })
M.fire("ServerLogic")
local wide = cardBox()
check("wide screen: the card takes a share of it", wide ~= nil and wide.w == 560)
check("a saved position off the edge is pulled back on", wide.x <= 2000 - 560 and wide.y <= 1000 - wide.h)
inSettings("Card size: medium")
M.fire("ServerLogic")
check("card size setting changes the share", M.db.prefs.cardSize == "large" and cardBox().w == 640)
inSettings("Card size: large")
inSettings("Card size: small")
M.layer.width, M.layer.height = 100, 20
M.db.cardPosition = nil
M.fire("WindowSizeChanged", { newWidth = 100, newHeight = 20 })
M.fire("ServerLogic")
check("back to the default on an unknown screen", cardBox().w == 480)

-- ---------- The Knight's Sword, from a recorded play session ----------
M.fire("Logic")
findButton("Quest list"):Press()
pressQuest("The Knight's Sword")
M.fire("Logic")
findButton("Restart quest"):Press()
M.fire("Logic")
findButton("Click again to restart"):Press()
local function ks() return M.db.steps.the_knight_s_sword end
check("KS restarted", ks() == 1)
check("no picture references in the steps", anyText("pictured") == nil and anyText("%(north of fairy ring AIQ%)") ~= nil)

-- Ingredients: redberry pie's recipe, followed down while you have nothing.
M.backpack = {}
M.fire("InventoryUpdated")
M.fire("ServerLogic")
check("pie recipe shown", anyText("^from <col=c0564a>Uncooked berry pie</col> %(Range, Cooking 10%)$") ~= nil)
check("pie recipe followed down", anyText("^Uncooked berry pie: from <col=c0564a>Pie shell</col> %+ <col=c0564a>Redberries</col>") ~= nil
    and anyText("^Pie shell: from <col=c0564a>Pie dish</col> %+ <col=c0564a>Pastry dough</col>") ~= nil)
M.backpack = { { "Pie shell", 1 }, { "Redberries", 3 } }
M.fire("InventoryUpdated")
M.fire("ServerLogic")
check("recipe stops at what you have", anyText("^Uncooked berry pie: from <col=7fbf4d>Pie shell</col> %+ <col=7fbf4d>Redberries</col>") ~= nil
    and anyText("^Pie shell: from") == nil)

-- Step 3: Thurgo takes the pie; the quest var moving a tick later is the
-- same event, not the next step (in game it was 11:38 then 11:39).
findButton("Done, next"):Press()
findButton("Done, next"):Press()
check("on the pie step", ks() == 3)
-- Climbing the Lumbridge mill's ladder to make flour (session 5, 8:00)
-- isn't the castle ladder three steps on.
M.select("Climb up", "<col=00ffff>Ladder", 3)
check("a ladder elsewhere doesn't jump ahead to the ladder step", ks() == 3)
check("card says what to bring", cardText("^Bring:$") ~= nil and colourOf(cardText("^%- Redberry pie$")) == "red")
M.backpack = { { "Redberry pie", 1 } }
M.fire("InventoryUpdated")
check("bring list turns green", colourOf(cardText("^%- Redberry pie$")) == "green")
M.backpack = {}
M.fire("InventoryUpdated")
check("handing over the pie completes the step", ks() == 4 and anyText("handed over the redberry pie") ~= nil)
M.fire("ServerLogic")
M.questVar.value = M.questVar.value + 1
M.fire("VarTransmit")
check("progress moving right after the hand-over isn't another step", ks() == 4)

-- Step 8, the cupboard on the floor above: upstairs with it out of sight,
-- the stairs are outlined, not the doors the side notes mention.
-- Step 6, "Climb the ladder to the east, then the first staircase to the
-- west": two climbs, each object on its side of the player.
local function at(x, z, level)
    M.player.position = { x = x * 512 + 256, y = 0, z = z * 512 + 256 }
    M.player.coordGrid.level = level or 0
end
local function placed(name, tile, ops, x, z)
    local loc = M.loc(name, tile, ops)
    loc.position = { x = x * 512 + 256, y = 0, z = z * 512 + 256 }
    return loc
end
local function markerOn() return M.entities["rs3qb-marker-1"].visible and M.entities["rs3qb-marker-1"].coordGrid end
at(2970, 3340)
M.fire("ServerLogic")
findButton("Done, next"):Press()
findButton("Done, next"):Press()
check("on the climbing step", ks() == 6)
M.locs = { placed("Ladder", "ladder-west", { "Climb-up" }, 2960, 3340), placed("Staircase", "stairs-west", { "Climb-up" }, 2962, 3341),
    placed("Ladder", "ladder-east", { "Climb-up" }, 2975, 3340) }
M.fire("ServerLogic")
check("first climb: only the ladder to the east", M.db["diag.marked"] == "loc Ladder" and markerOn() == "ladder-east")
at(2975, 3340, 1)
M.locs[3] = placed("Ladder", "ladder-east", { "Climb-down" }, 2975, 3340)
M.fire("ServerLogic")
check("one climb of two: still on the step", ks() == 6 and anyText("climb 1 of 2") ~= nil)
M.fire("ServerLogic") -- the climb is noticed after this tick's highlights; the next tick switches
check("second climb: the staircase to the west", M.db["diag.marked"] == "loc Staircase" and markerOn() == "stairs-west")
at(2962, 3341, 2)
M.fire("ServerLogic")
check("both climbs done", ks() == 7)

-- Step 7 "Enter Sir Vyvin's room": he's on floor 2. One floor short, the
-- stairs up are outlined (not this floor's doors) and the dots go there.
at(2975, 3340, 1)
M.locs = { placed("Door", "door-1", { "Open" }, 2978, 3338), placed("Staircase", "stairs-down", { "Climb-down" }, 2973, 3342),
    placed("Staircase", "stairs-up", { "Climb-up" }, 2980, 3345) }
M.fire("ServerLogic")
check("wrong floor: the stairs up outlined, not the doors", M.db["diag.marked"] == "loc Staircase" and markerOn() == "stairs-up")
-- A full backpack on a step that hands you an item (Fight Arena's armour
-- on the beta): say so before the click, and the recording notes the room.
local savedBag = M.backpack
M.backpack = {}
for i = 1, 28 do M.backpack[i] = { "Trout", 1 } end
M.fire("InventoryUpdated")
M.fire("ServerLogic")
check("full backpack warned on a get step", anyText("^Backpack full: free 1 slot first%.$") ~= nil)
M.backpack = savedBag
M.fire("InventoryUpdated")
M.fire("ServerLogic")
check("warning gone with room again", anyText("^Backpack full") == nil)
firstDraw = #M.drawn + 1
M.fire("Draw")
local toStairs = M.drawn[#M.drawn]
check("wrong floor: dots lead to those stairs", #toStairs.shapePositions >= 4
    and math.abs(toStairs.shapePositions[#toStairs.shapePositions].x / 512 - 2980) <= 2)
at(2975, 3340, 2)
M.fire("ServerLogic")
check("right floor: the doors near his room", M.db["diag.marked"] == "loc Door")
-- Far away (session 5: at the mill) the step's doors aren't outlined at all.
at(3166, 3300, 0)
M.locs = { placed("Gate", "gate-1", { "Open" }, 3167, 3301), placed("Door", "door-2", { "Open" }, 3165, 3299) }
M.fire("ServerLogic")
check("enter step far from the place: no doors or gates", M.db["diag.marked"] == "")
M.locs = {}
at(2975, 3340, 0)
M.fire("ServerLogic")
findButton("Done, next"):Press()
check("on the cupboard step", ks() == 8)
M.player.coordGrid.level = 1
M.locs = { M.loc("Door", "door-1", { "Open" }), M.loc("Staircase", "stairs-1", { "Climb-up" }),
    M.loc("Door", "door-2", { "Open" }) }
M.fire("ServerLogic")
check("upstairs: stairs outlined when the target isn't in sight", M.db["diag.marked"] == "loc Staircase")
M.locs = { M.loc("Cupboard", "cupboard-1", { "Open" }), M.loc("Door", "door-1", { "Open" }) }
M.fire("ServerLogic")
check("the cupboard once it's in sight, and no doors", M.db["diag.marked"] == "loc Cupboard")
M.select("Search", "Cupboard", 3)
for _ = 1, 4 do M.fire("ServerLogic") end
check("searching the cupboard waits for the portrait", ks() == 8)
-- IMPROVEMENTS B6: the compact card drops the notes.
check("full card shows the step's notes", cardText("^%- If Sir Vyvin keeps noticing") ~= nil)
inSettings("Card detail: full")
check("compact card leaves the notes to the panel", M.db.prefs.cardDetail == "compact"
    and cardText("^%- If Sir Vyvin keeps noticing") == nil and cardText("^Look for a cupboard") ~= nil)
inSettings("Card detail: compact")
check("full card again", cardText("^%- If Sir Vyvin keeps noticing") ~= nil)
M.backpack = { { "Portrait", 1 } }
M.fire("InventoryUpdated")
check("finding the portrait completes the search", ks() == 9 and anyText("got the portrait") ~= nil)
M.player.coordGrid.level = 0

-- Steps 11-12 in the Ice Dungeon: only blurite rocks, never plain ones;
-- reaching them completes "follow the dungeon until...".
findButton("Done, next"):Press()
findButton("Done, next"):Press()
check("on the follow step", ks() == 11)
local blurite = M.loc("Blurite rock", "blurite-1", { "Mine" })
blurite.position = { x = M.player.position.x + 3 * 512, y = 0, z = M.player.position.z }
local plain = M.loc("Rock", "rock-1", { "Mine" })
M.locs = { plain, M.loc("Rock", "rock-2", { "Mine" }), blurite }
M.fire("ServerLogic")
check("plain rocks not outlined, blurite rocks are", M.db["diag.marked"] == "loc Blurite rock")
check("reaching the blurite rocks completes the follow step", ks() == 12 and anyText("found it") ~= nil)
M.fire("ServerLogic")
check("mining step outlines the blurite rocks", M.db["diag.marked"] == "loc Blurite rock")
M.locs = {}
-- Mining it while still on the follow step (as in game) skips past the mine step.
findButton("Back"):Press()
M.backpack = { { "Blurite ore", 1 } }
M.fire("InventoryUpdated")
check("ore mined a step early skips past the mine step", ks() == 13)
-- Still in the dungeon with Thurgo up top: no dots pointing off the map,
-- the ladders out are outlined instead (seen in the replay of a session).
local surface = { x = 3008 * 512, y = 0, z = 3150 * 512 }
M.player.position = surface
M.fire("ServerLogic")
M.player.position = { x = 3009 * 512, y = 0, z = 9550 * 512 } -- down the trapdoor
M.fire("ServerLogic")
M.player.position = { x = 3038 * 512, y = 0, z = 9580 * 512 } -- at the blurite rocks
M.locs = { M.loc("Ladder", "ladder-1", { "Climb-up" }), M.loc("Rock", "rock-1", { "Mine" }) }
M.fire("ServerLogic")
check("underground: ladders out outlined", M.db["diag.marked"] == "loc Ladder")
firstDraw = #M.drawn + 1
M.fire("Draw")
local back = M.drawn[#M.drawn]
check("underground: dots lead back to where you came down", #back.shapePositions > 6
    and back.shapePositions[#back.shapePositions].z < 9558 * 512 and back.shapePositions[#back.shapePositions].x < 3016 * 512)
M.player.position, M.locs = surface, {}
M.player.coordGrid.level = 0
M.fire("ServerLogic")
-- The anvil the side note mentions is outlined while bars are missing, and
-- the note says how to get them instead of a furnace recipe.
M.locs = { M.loc("Anvil", "anvil-1", { "Smith" }) }
M.fire("ServerLogic")
check("anvil from the side note outlined", M.db["diag.marked"] == "loc Anvil")
check("bars hint from the guide, not a recipe", cardText("^Bars can be withdrawn at the anvil in Thurgo's hut%.$") ~= nil
    and cardText("^%- Bars can be withdrawn") == nil and cardText("^from <col=c0564a>2 Iron ore") == nil)
M.locs = {}

-- Step 13 "with the materials": the card lists the section's items; once
-- Thurgo takes them the step is done and nothing is left to bring.
check("materials listed on the card", cardText("^%- Blurite ore$") ~= nil
    and colourOf(cardText("^%- 2 iron bars %(0/2%)$")) == "red")
M.backpack = { { "Blurite ore", 1 }, { "Iron bar", 2 } }
M.fire("InventoryUpdated")
M.backpack = { { "Blurite sword", 1 } }
M.fire("InventoryUpdated")
check("handing over the materials completes the step", ks() == 14)
M.fire("ServerLogic")
check("no iron bars once the sword is made", anyText("iron bar") == nil)
local fill
for _, c in ipairs(M.created) do
    if c.kind == "Rectangle" and live(c) and c.parent.kind == "GroupBox" and c.colour[1] == 0.5 then fill = c end
end
check("card progress strip fills", fill ~= nil and fill.w == math.floor(468 * 13 / 15))

-- ---------- which one of several (Elemental Workshop I, 2026-10-29) ----------
-- In game three bookcases (one 18 tiles off) and both water controls were
-- outlined, and the dots led to the lever in the wrong room: the game's
-- scenery list isn't nearest first. Scenes laid out like the workshop.
local World = require("world")
local suppressedBefore = World.pathSuppressed
local function sceneStep(text, locs, x, z)
    at(x, z)
    World.pathSuppressed = false -- the guide's own step may be hinting a teleport
    M.locs = locs
    World.SetTargets({}, function(loc)
        local name = Advance.Clean(loc.displayName)
        -- "stairs" in a guide can be a "Staircase" (as in the app's matcher).
        return Advance.MentionRoles(text, name) > 0 or Advance.MentionRoles(text, Advance.Singular(name)) > 0
            or (name:find("stair") ~= nil and text:find("stair") ~= nil)
    end, nil, nil, function(name)
        return Advance.Placement(text, name) or Advance.Placement(text, Advance.Singular(name))
    end)
    World.Update()
    return World.lastMarked
end
local function onlyMarked(tile)
    return M.entities["rs3qb-marker-1"].visible and M.entities["rs3qb-marker-1"].coordGrid == tile
        and not (M.entities["rs3qb-marker-2"] and M.entities["rs3qb-marker-2"].visible)
end
-- IMPROVEMENTS A2: three doors in a row down a prison corridor.
local prison = { placed("Door", "door-north", { "Open" }, 2100, 3310), placed("Door", "door-middle", { "Open" }, 2100, 3305),
    placed("Door", "door-south", { "Open" }, 2100, 3300) }
check("the door in the middle of the prison", sceneStep("Open the door in the middle of the prison.", prison, 2095, 3300)
    == "loc Door" and onlyMarked("door-middle"))
check("the door second from the north", sceneStep("Go through the door second from the north.", prison, 2095, 3300)
    == "loc Door" and onlyMarked("door-middle"))
check("the northern door", sceneStep("Go through the northern door.", prison, 2095, 3300) == "loc Door"
    and onlyMarked("door-north"))
local house = { placed("Bookcase", "bookcase-far", { "Search" }, 2703, 3466),
    placed("Bookcase", "bookcase-west", { "Search" }, 2711, 3486), placed("Bookcase", "bookcase-north", { "Search" }, 2714, 3488),
    placed("Bookcase", "bookcase-east", { "Search" }, 2717, 3485) }
check("bookcase on the eastern wall: just that one",
    sceneStep("Search the bookcase on the eastern wall to find a battered book.", house, 2714, 3484) == "loc Bookcase"
    and onlyMarked("bookcase-east"))
local wheelRoom = { placed("Lever", "lever-bellows", { "Pull" }, 2734, 9888), placed("Lever", "lever-west", { "Pull" }, 2700, 9890),
    placed("Water wheel", "wheel", {}, 2720, 9906), placed("Water controls", "controls-west", { "Turn" }, 2716, 9905),
    placed("Water controls", "controls-east", { "Turn" }, 2724, 9905), placed("Lever", "lever-wheel", { "Pull" }, 2721, 9903) }
check("water controls east of the wheel: just those", sceneStep("(Red Indicator) Turn the water controls east of the "
    .. "water wheel to turn it green.", wheelRoom, 2716, 9900) == "loc Water controls" and onlyMarked("controls-east"))
check("water controls west of the wheel: just those", sceneStep("(Red Indicator) Turn the water controls west of the "
    .. "water wheel to turn it green", wheelRoom, 2726, 9907) == "loc Water controls" and onlyMarked("controls-west"))
check("lever by the water wheel, not the bellows' lever", sceneStep("Pull the lever by the water wheel.", wheelRoom,
    2730, 9895) == "loc Lever" and onlyMarked("lever-wheel"))
local drawnBefore = #M.drawn
M.fire("Draw")
local toLever = { shapePositions = {} }
for i = drawnBefore + 1, #M.drawn do
    -- The path's dots are 4 corners each; arrows are 6 points.
    if #M.drawn[i].shapePositions % 4 == 0 then toLever = M.drawn[i] end
end
check("dots lead to that lever", #toLever.shapePositions >= 4
    and math.abs(toLever.shapePositions[#toLever.shapePositions].x / 512 - 2721) <= 2
    and math.abs(toLever.shapePositions[#toLever.shapePositions].z / 512 - 9903) <= 2)
local middleRoom = { placed("Crate", "crate-sw", { "Search" }, 2716, 9890), placed("Crate", "crate-ne", { "Search" }, 2724, 9897),
    placed("Hatch", "hatch", { "Open" }, 2720, 9894), placed("Crate", "crate-nw", { "Search" }, 2717, 9896),
    placed("Crates", "crates-sw", { "Search" }, 2716, 9891),
    placed("Boxes", "boxes", { "Search" }, 2723, 9896) }
check("crate north-west of the hatch: just that one", sceneStep("(Optional) To obtain leather, search the singular "
    .. "crate north-west of the hatch in the middle room.", middleRoom, 2720, 9890) == "loc Crate" and onlyMarked("crate-nw"))
check("no placement said: the nearest few", sceneStep("Search the crate.", middleRoom, 2720, 9890)
    == "loc Crate, loc Crates, loc Crate, loc Crate" and M.entities["rs3qb-marker-1"].coordGrid == "crate-sw")
check("stairs: only the nearest way down", sceneStep("Go down the stairs.", { placed("Stairs", "stairs-house", { "Climb-down" }, 2715, 3482),
    placed("Staircase", "stairs-wall", { "Climb-down" }, 2710, 3496) }, 2709, 3494) == "loc Staircase")
M.locs = {}
World.SetTargets({}, nil, nil, nil, nil)
World.pathSuppressed = suppressedBefore

-- ---------- session recorder ----------
M.fire("ChatMessage", { chatMessage = "hello from another player", chatType = 2 })
M.fire("ChatMessage", { chatMessage = "You need a hammer for that.", chatType = 0 })
findButton("Flag a problem (Alt+F)"):Press()
check("flag button confirms", anyText("Flagged problem #1 at step 14") ~= nil)
M.fire("KeyDown", { gameKey = GameKey.F, modifiers = ModifierKey.ALT, isRepeat = false })
check("Alt+F flags too", anyText("Flagged problem #2") ~= nil)
inSettings("Recording: on")
M.fire("ChatMessage", { chatMessage = "Said while not recording.", chatType = 0 })
inSettings("Recording: off")
check("recording toggle saved", M.db.prefs.record == true)

PluginShutdown()
local session = tostring(M.db["diag.loads"])
local recorded = {}
for n = 1, M.db["rec." .. session .. ".chunks"] or 0 do
    for _, line in ipairs(M.db["rec." .. session .. "." .. n]) do recorded[#recorded + 1] = line end
end
local function recordedLine(pattern)
    for _, line in ipairs(recorded) do if line:find(pattern) then return line end end
end
check("session listed", M.db["rec.sessions"][#M.db["rec.sessions"]] == session)
check("recording spans several chunks", (M.db["rec." .. session .. ".chunks"] or 0) > 1)
check("recording starts with a header", recorded[1]:find("^%d+\tstart\t0%.3%.0") ~= nil)
check("recorded clicks", recordedLine("\tclick\tTalk%-to\t<col=ffff00>Squire Asrol</col>\t4") ~= nil)
-- Only the open quest is recorded, from the first tick it has a value.
check("recorded quest progress", recordedLine("\tvar\tthe_knight_s_sword\t0?\t1$") ~= nil)
check("recorded auto step changes with the reason", recordedLine("\tstep\tgoblin_diplomacy\t1\t2\tarrived\tauto$") ~= nil)
check("recorded manual step changes", recordedLine("\tstep\tvampyre_slayer\t%d+\t%d+\t\tdone button$") ~= nil)
check("recorded backpack", recordedLine("\tbag\t.*goblin mail=3") ~= nil)
check("recorded position", recordedLine("\tpos\t2956%.0\t3502%.0\t0$") ~= nil)
check("recorded dialogue on screen", recordedLine("\tdialog\t1%. | Chat | 2%. | About the Task System") ~= nil)
check("recorded option highlight", recordedLine("\toptionmarks\t2 Something else%.\tnot recoloured: 2 Something else%. %(button%)$") ~= nil)
check("recorded game chat", recordedLine("\tchat\t0\tYou need a hammer for that%.$") ~= nil)
check("players' chat never recorded", recordedLine("another player") == nil)
check("nothing recorded while off", recordedLine("while not recording") == nil
    and recordedLine("\trec\toff$") ~= nil and recordedLine("\trec\ton$") ~= nil)
check("flags recorded", recordedLine("\tflag\t1\tbutton\tthe_knight_s_sword\t14$") ~= nil
    and recordedLine("\tflag\t2\tAlt%+F") ~= nil)
check("recording ends on shutdown", recorded[#recorded]:find("\tend$") ~= nil)

RUN_RECORDING = recorded -- kept for replay tests; the pruning below deletes it

-- Only the newest 5 sessions are kept; older ones are deleted.
package.loaded.recorder = nil
local Fresh = require("recorder")
for n = 1, 6 do
    Fresh.Start("t" .. n)
    Fresh.Add("note", "session " .. n)
    Fresh.Flush()
end
check("old sessions pruned", #M.db["rec.sessions"] == 5 and M.db["rec.sessions"][5] == "t6"
    and M.db["rec.t1.1"] == nil and M.db["rec.t6.1"][1] == "0\tnote\tsession 6")

check("markers destroyed", not M.entities["rs3qb-marker-1"].isValid)
check("no errors logged", errorsLogged() == nil)
if errorsLogged() then results[#results + 1] = "  logged: " .. errorsLogged() end

results[#results + 1] = failures == 0 and "ALL PLUGIN TESTS PASSED" or (failures .. " FAILED")
return table.concat(results, "\n")
