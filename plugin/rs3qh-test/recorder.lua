-- Session recorder: a timeline of what the plugin saw and did while someone
-- plays, saved in PersistentDB so the developer can read it back
-- (tests/read_rec.py) and replay it offline (tests/replay.py) instead of
-- relying on a written description of what went wrong.
--
-- Each event is one line: "tick<TAB>kind<TAB>field<TAB>field...", where
-- tick counts server ticks (~0.6s) since the plugin loaded. Lines are kept
-- in chunks of CHUNK_SIZE under "rec.<session>.<n>"; "rec.sessions" lists
-- the sessions kept, oldest first.

local Recorder = {}

local CHUNK_SIZE = 100
local MAX_CHUNKS = 100        -- 10,000 events per session; later ones are dropped
local MAX_SESSIONS = 5
local FLUSH_EVERY = 10        -- ticks between saves (~6 seconds)

Recorder.enabled = true
Recorder.count = 0            -- events this session
Recorder.flags = 0            -- problems flagged this session
Recorder.session = nil

local chunk, lines = 1, {}
local tick, lastFlush = 0, 0
local dirty, full = false, false
local lastByKind = {}         -- kind -> last fields, for AddIfChanged

local function clean(value)
    if value == nil then return "" end
    return (tostring(value):gsub("[\t\r\n]", " "))
end

local function key(session, suffix) return "rec." .. session .. "." .. suffix end

local function save()
    if Recorder.session == nil or not dirty then return end
    dirty = false
    pcall(function()
        PersistentDB:SetStructuredData(key(Recorder.session, chunk), lines)
        PersistentDB:SetInt(key(Recorder.session, "chunks"), chunk)
    end)
end

local function forget(session)
    pcall(function()
        for n = 1, math.tointeger(PersistentDB:GetInt(key(session, "chunks")) or 0) or 0 do
            PersistentDB:Delete(key(session, n))
        end
        PersistentDB:Delete(key(session, "chunks"))
    end)
end

-- Begin a new session named `name`; the oldest past MAX_SESSIONS are deleted.
function Recorder.Start(name)
    Recorder.session = tostring(name)
    chunk, lines, tick, lastFlush, dirty, full = 1, {}, 0, 0, false, false
    Recorder.count, Recorder.flags, lastByKind = 0, 0, {}
    local sessions = {}
    pcall(function()
        for _, s in ipairs(PersistentDB:GetStructuredData("rec.sessions") or {}) do
            if tostring(s) ~= Recorder.session then sessions[#sessions + 1] = tostring(s) end
        end
    end)
    sessions[#sessions + 1] = Recorder.session
    while #sessions > MAX_SESSIONS do forget(table.remove(sessions, 1)) end
    pcall(function() PersistentDB:SetStructuredData("rec.sessions", sessions) end)
end

function Recorder.Add(kind, ...)
    if not Recorder.enabled or Recorder.session == nil or full then return end
    if #lines >= CHUNK_SIZE then
        save()
        if chunk >= MAX_CHUNKS then
            full = true
            return
        end
        chunk, lines = chunk + 1, {}
    end
    local parts = { tostring(tick), kind }
    for i = 1, select("#", ...) do parts[#parts + 1] = clean((select(i, ...))) end
    lines[#lines + 1] = table.concat(parts, "\t")
    Recorder.count = Recorder.count + 1
    dirty = true
end

-- Like Add, but skipped when the fields are the same as this kind's last event.
function Recorder.AddIfChanged(kind, ...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = clean((select(i, ...))) end
    local joined = table.concat(parts, "\t")
    if lastByKind[kind] == joined then return end
    lastByKind[kind] = joined
    Recorder.Add(kind, ...)
end

function Recorder.SetEnabled(on)
    if on == Recorder.enabled then return end
    if not on then Recorder.Add("rec", "off") end
    Recorder.enabled = on
    if on then
        lastByKind = {}
        Recorder.Add("rec", "on")
    end
    save()
end

-- Once per server tick: counts time and saves now and then.
function Recorder.Tick()
    tick = tick + 1
    if tick - lastFlush >= FLUSH_EVERY then
        lastFlush = tick
        save()
    end
end

function Recorder.Flush() save() end

return Recorder
