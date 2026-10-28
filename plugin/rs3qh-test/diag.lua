-- Diagnostics that survive the session: errors and status snapshots are kept
-- in the plugin's PersistentDB, which the developer can read back from the
-- beta client's PluginData.db, so testers don't have to copy console text.

local Diag = {}

local LOG_KEY = "diag.log"
local LOG_MAX = 40

local entries = {}
pcall(function()
    for _, entry in ipairs(PersistentDB:GetStructuredData(LOG_KEY) or {}) do entries[#entries + 1] = entry end
end)
local seen = {}       -- message -> true, so a repeating error is stored once per load
local loadNumber = (PersistentDB:GetInt("diag.loads") or 0) + 1
PersistentDB:SetInt("diag.loads", loadNumber)
Diag.loadNumber = loadNumber
Diag.onNote = nil -- optional function(message), e.g. the session recorder

function Diag.Note(message)
    message = tostring(message)
    log("[rs3qh] " .. message)
    if seen[message] then return end
    seen[message] = true
    if Diag.onNote then pcall(Diag.onNote, message) end
    entries[#entries + 1] = "load " .. loadNumber .. ": " .. message
    while #entries > LOG_MAX do table.remove(entries, 1) end
    pcall(function() PersistentDB:SetStructuredData(LOG_KEY, entries) end)
end

function Diag.Error(where, err)
    Diag.Note("ERROR in " .. where .. ": " .. tostring(err))
end

-- A named value that's overwritten each time (latest state, not history).
function Diag.Snapshot(name, value)
    pcall(function() PersistentDB:SetString("diag." .. name, tostring(value)) end)
end

local traceback = (debug and debug.traceback) or tostring

-- Run fn(...) and record any error with a traceback; returns ok, result.
function Diag.Guard(where, fn, ...)
    local ok, result = xpcall(fn, traceback, ...)
    if not ok then Diag.Error(where, result) end
    return ok, result
end

return Diag
