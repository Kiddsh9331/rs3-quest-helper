-- Replays a session recording (rs3-quest-buddy/recorder.lua) against mock.lua.
-- The recorded inputs (position, backpack, quest vars and statuses, clicks,
-- chat, dialogue text, cutscenes, the tester's own step changes) are fed
-- back tick by tick while the plugin records again; replay.py compares the
-- plugin's decisions in the two recordings.
--
-- Globals in: REC (the recording's lines), PLUGIN_DIR. Returns the replay's lines.
-- Not replayed: NPCs and scenery around the player (not recorded), so what
-- gets outlined in the world can differ.

local function split(line)
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
    return fields
end

local events = {}
for i = 1, #REC do
    local f = split(REC[i])
    events[#events + 1] = { tick = tonumber(f[1]), kind = f[2], args = { table.unpack(f, 3) } }
end

-- ---------- game state the plugin reads ----------

local Quests = require("quests")
local vars, statuses = {}, {}
for i, quest in ipairs(Quests) do vars[quest.key] = { configName = "VAR_" .. i, value = nil } end

config.Quest.FromID = function(i)
    local quest = Quests[i]
    if quest == nil then return nil end
    local fixed = { id = i, configName = "Q" .. i, name = quest.name, deprecated = false,
        masterQuestVars = { { varPlayer = vars[quest.key], startState = 0, endState = 0 } } }
    return setmetatable(fixed, { __index = function(_, k)
        local status = statuses[quest.key]
        if k == "hasFinishedQuest" then return status == "complete" end
        if k == "hasStartedQuest" then return status == "started" or status == "complete" end
        if k == "canStartQuest" then return status ~= "requirements not met" end
    end })
end

local function setBag(text)
    M.backpack = {}
    if text == "unreadable" then return end
    for name, count in (text or ""):gmatch("([^;=]+)=(%d+)") do M.backpack[#M.backpack + 1] = { name, tonumber(count) } end
end

local function setPos(x, z, level)
    M.player.position = { x = tonumber(x) * 512, y = 0, z = tonumber(z) * 512 }
    M.player.coordGrid = { level = tonumber(level) or 0 }
end

-- Stand-ins for the game's own interfaces, so the cutscene check has a
-- normal count to compare with; a cutscene unloads most of them.
local FILLER_FIRST, FILLER_COUNT, FILLER_KEPT = 2000, 200, 20
local function setFiller(count)
    for i = 0, FILLER_COUNT - 1 do M.interfaces[FILLER_FIRST + i] = (i < count) and {} or nil end
end

-- Dialogue text goes into the interface the game showed it in.
local dialogueInterface = 1188
local learnedInRecording = false
local function setDialogue(text)
    if text == "" or text == nil then
        M.interfaces[dialogueInterface] = nil
        return
    end
    local iface, n = {}, 0
    for part in (text .. " | "):gmatch("(.-) | ") do
        n = n + 1
        local label = M.label(part, 300)
        label.staticID, label.interfaceID = n, dialogueInterface
        iface[n] = label
    end
    M.interfaces[dialogueInterface] = iface
end

-- ---------- starting state, from the recording's header ----------

M.db = {}
M.npcs, M.locs = {}, {}
local prefs = { card = true, record = true, auto = true }
for _, e in ipairs(events) do
    if e.tick > 0 then break end
    if e.kind == "start" then
        M.db.quest = e.args[2] ~= "" and e.args[2] or nil
        prefs.auto = e.args[4] ~= "auto off"
        M.perms.chatAccess = e.args[5] == "chat on"
    elseif e.kind == "steps" then
        M.db.steps = {}
        for key, index in (e.args[1] or ""):gmatch("([^;=]+)=(%d+)") do M.db.steps[key] = tonumber(index) end
    elseif e.kind == "ifaces" then
        M.db.dialogInterfaces3 = {}
        for interfaceID in (e.args[1] or ""):gmatch("%d+") do
            M.db.dialogInterfaces3[#M.db.dialogInterfaces3 + 1] = tonumber(interfaceID)
            dialogueInterface = tonumber(interfaceID)
        end
    elseif e.kind == "var" then
        vars[e.args[1]].value = tonumber(e.args[3])
    elseif e.kind == "bag" then
        setBag(e.args[1])
    end
end
M.db.prefs = prefs
-- The first status and position samples come on tick 1; start there.
for _, e in ipairs(events) do
    if e.kind == "status" and statuses[e.args[1]] == nil then statuses[e.args[1]] = e.args[2] end
    if e.kind == "pos" and M.player.replayed == nil then
        setPos(e.args[1], e.args[2], e.args[3])
        M.player.replayed = true
    end
end
setFiller(FILLER_COUNT)

RS3QB_REPLAY = {}
assert(loadfile(PLUGIN_DIR .. "/main.lua"))()
assert(RS3QB_REPLAY.setStep, "plugin didn't load: " .. tostring(M.db["diag.loadError"]))
M.fire("ContentLayerReady", { component = M.panelRoot })

-- ---------- feed the session back ----------

-- Sampled at the start of a server tick (dialogue at its end, but it shows
-- what was on screen during the tick): applied before the tick runs.
local BEFORE_TICK = { pos = true, status = true, dialog = true, cutscene = true }
-- The tester's own step changes that move forward ("done, next").
local FORWARD_SOURCES = { ["done button"] = true, checkbox = true, ["Alt+D"] = true, manual = true }
-- Automatic steps decided by scenery near the player, which recordings
-- don't hold: the replay can't judge them, so it takes the game's word.
local WORLD_REASONS = { ["found it"] = true }

local function apply(e)
    local a = e.args
    if e.kind == "pos" then
        setPos(a[1], a[2], a[3])
    elseif e.kind == "status" then
        statuses[a[1]] = a[2]
    elseif e.kind == "dialog" then
        setDialogue(a[1])
    elseif e.kind == "cutscene" then
        setFiller(a[1] == "on" and FILLER_KEPT or FILLER_COUNT)
    elseif e.kind == "learn" then
        -- The game showed a conversation here; later dialogue text goes in it.
        -- The first one learned: older builds also learned tooltips that
        -- opened mid-conversation, which never hold the options.
        if not learnedInRecording then
            dialogueInterface = tonumber(a[1]) or dialogueInterface
            learnedInRecording = true
        end
    elseif e.kind == "var" and e.tick > 0 then
        vars[a[1]].value = tonumber(a[3])
        M.fire("VarTransmit")
    elseif e.kind == "bag" and e.tick > 0 then
        setBag(a[1])
        M.fire("InventoryUpdated")
    elseif e.kind == "click" then
        local entry = { verbText = a[1], subjectText = a[2], actionEntryType = tonumber(a[3]) }
        if a[4] and a[4] ~= "" then entry.ComponentData = { interfaceID = tonumber(a[4]) } end
        M.fire("MiniMenuEntrySelected", { entry = entry })
    elseif e.kind == "chat" and M.handlers.ChatMessage then
        M.handlers.ChatMessage({ chatType = tonumber(a[1]), chatMessage = a[2] })
    elseif e.kind == "open" then
        -- The plugin only records the open quest's status and progress, so
        -- take a newly opened quest's from the line itself.
        if vars[a[1]] and tonumber(a[4]) then vars[a[1]].value = tonumber(a[4]) end
        if a[3] and a[3] ~= "" then statuses[a[1]] = a[3] end
        RS3QB_REPLAY.openQuest(a[1])
    elseif e.kind == "step" and a[5] == "auto" and WORLD_REASONS[a[4]] then
        local now = M.db.steps and tonumber(M.db.steps[a[1]]) or 1
        if now < tonumber(a[3]) then RS3QB_REPLAY.setStep(tonumber(a[3]), "auto") end
    elseif e.kind == "step" and a[5] ~= "auto" then
        -- The tester moved the step themselves: do the same, unless they were
        -- catching up with something the replay already did by itself.
        local forward = FORWARD_SOURCES[a[5]] and tonumber(a[3]) > tonumber(a[2])
        local now = M.db.steps and tonumber(M.db.steps[a[1]]) or 1
        -- (A click that left the step where it was, like ticking and
        -- unticking a box, changed nothing in game either.)
        local noop = a[2] == a[3] and a[5] ~= "restart"
        if not noop and not (forward and now >= tonumber(a[3])) then RS3QB_REPLAY.setStep(tonumber(a[3]), a[5]) end
    end
end

local tick, i = 0, 1
while i <= #events do
    local e = events[i]
    while tick < e.tick do
        tick = tick + 1
        -- Everything sampled at the start of this tick, then the tick itself.
        local j = i
        while j <= #events and events[j].tick == tick do
            if BEFORE_TICK[events[j].kind] then apply(events[j]) end
            j = j + 1
        end
        M.fire("ServerLogic")
        M.fire("Logic")
    end
    if not (BEFORE_TICK[e.kind] and e.tick > 0) then apply(e) end
    i = i + 1
end

PluginShutdown()
local session = tostring(M.db["diag.loads"])
local out = {}
for n = 1, M.db["rec." .. session .. ".chunks"] or 0 do
    for _, line in ipairs(M.db["rec." .. session .. "." .. n]) do out[#out + 1] = line end
end
return out
