-- Checks a release copy of the plugin (staged by tools/package.py) against
-- mock.lua before it's zipped for mod.io: no debug tools, recording off,
-- only the chat permission, the wiki credited, and walking guidance there
-- or gone as asked.
--
-- Globals in: PLUGIN_DIR (the staged copy), GUIDANCE (whether it should
-- have the path, tile marker and teleport hints). Returns a report ending
-- in "RELEASE CHECKS PASSED".

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
local function cardText(pattern)
    return textComponent(pattern, function(c) return c.parent and c.parent.kind == "GroupBox" end)
end
local function readFile(name)
    local f = io.open(PLUGIN_DIR .. "/" .. name, "r")
    if f == nil then return nil end
    local text = f:read("a")
    f:close()
    return text
end

-- ---------- the files ----------
check("no debug tools in the release", readFile("devtools.lua") == nil)
local manifest = readFile("plugin.json") or ""
check("manifest: main.lua and plugin.json side by side", readFile("main.lua") ~= nil and manifest ~= "")
check("manifest: only the chat permission", manifest:find('"optionalPermissions": %[%s*"chatAccess"%s*%]') ~= nil
    and manifest:find("httpAccess") == nil and manifest:find('"requiredPermissions": %[%]') ~= nil)
check("manifest: version is digits and dots", manifest:find('"version": "%d+[%.%d]*"') ~= nil)
check("manifest: no placeholder email", manifest:find("change%-me") == nil)
local everything = ""
for _, name in ipairs({ "app.lua", "world.lua", "card.lua", "view.lua", "probe.lua", "advance.lua", "path.lua",
    "travel.lua", "recorder.lua", "diag.lua", "main.lua", "edition.lua" }) do
    everything = everything .. (readFile(name) or "")
end
check("no web requests in the code", everything:find("HTTPRequest") == nil)

-- ---------- loading ----------
assert(loadfile(PLUGIN_DIR .. "/main.lua"))()
check("loads without errors", M.db["diag.loadError"] == nil)
local Edition = require("edition")
check("release edition", Edition.release == true and Edition.devTools == false)
check("manifest and panel use the same name", manifest:find('"name": "' .. Edition.name .. '"', 1, true) ~= nil)
M.fire("ContentLayerReady", { component = M.panelRoot })
M.fire("Logic")
check("quest list credits the wiki", anyText("RuneScape Wiki %(runescape%.wiki%), CC BY%-NC%-SA 3%.0") ~= nil)

-- Open a quest: no debug section, no flag button while not recording.
for i = #M.created, 1, -1 do
    local c = M.created[i]
    if c.kind == "Text" and live(c) and c.content == "The Knight's Sword" then
        for _, sibling in ipairs(c.parent.children) do
            if sibling.kind == "Button" then sibling:Press() end
        end
        break
    end
end
M.fire("Logic")
check("quest opens", findButton("Done, next") ~= nil)
check("no debug button", findButton("Show debug") == nil and findButton("Hide debug") == nil)
check("no flag button while not recording", findButton("Flag a problem") == nil)

-- Recording is off until switched on, so nothing is kept.
for _ = 1, 30 do M.fire("ServerLogic") end
M.fire("Logic")
local kept = 0
for key, value in pairs(M.db) do
    if tostring(key):find("^rec%..+%.%d+$") and type(value) == "table" then kept = kept + #value end
end
check("nothing recorded by default", kept == 0)

-- Settings: recording off, guidance there or not.
findButton("Settings"):Press()
M.fire("Logic")
check("settings: recording off", findButton("Recording: off") ~= nil)
check("settings: say what recording keeps", anyText("Nothing is sent anywhere") ~= nil)
local farHint = cardText("^Teleport:") ~= nil
local marker = M.entities["rs3qb-tile"] ~= nil and M.entities["rs3qb-tile"].visible
-- Near Squire Asrol: dots towards him, if the build has them.
M.player.position = { x = 2975 * 512 + 256, y = 0, z = 3315 * 512 + 256 }
M.fire("ServerLogic")
local before = #M.drawn
M.fire("Draw")
local dots = false
for i = before + 1, #M.drawn do dots = dots or #(M.drawn[i].shapePositions or {}) >= 16 end
if GUIDANCE then
    check("settings: path, marker and teleport switches", findButton("Path: on") ~= nil
        and findButton("Marker: on") ~= nil and findButton("Teleport hints: on") ~= nil)
    check("teleport hint shown far from the step", farHint)
    check("tile marker shown", marker)
    check("dotted path drawn near the step", dots)
else
    check("settings: no path, marker or teleport switches", findButton("Path:") == nil
        and findButton("Marker:") == nil and findButton("Teleport hints:") == nil)
    check("no teleport hint", not farHint)
    check("no tile marker", not marker)
    check("no dotted path", not dots)
end

results[#results + 1] = failures == 0 and "RELEASE CHECKS PASSED" or (failures .. " FAILED")
return table.concat(results, "\n")
