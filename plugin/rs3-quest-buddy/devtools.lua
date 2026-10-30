-- Debug tools for the test build on the plugin beta world: the panel's
-- Debug section (quest data, progress var log, dialogue scan, wiki fetch).
-- Not part of the release build: tools/package.py leaves this file out.
--
-- app.lua hands over what the tools need as `app` (see DevTools.Rows).

local Probe = require("probe")
local View = require("view")
local Diag = require("diag")

local DevTools = {}

local CONSOLE_DUMP_MAX = 400
local lastScan = {} -- "interfaceID:text" seen by the previous manual scan

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then return result end
    return nil
end

-- Every visible text in the game's interfaces, dumped to the console, and
-- whether the step's dialogue options are among them.
local function scanDialogue(app)
    local texts, loaded = Probe.ScanAll(app.ownInterfaces())
    local seenNow, newTexts = {}, {}
    for i, entry in ipairs(texts) do
        local key = entry.interfaceID .. ":" .. entry.text
        seenNow[key] = true
        if not lastScan[key] and #entry.text <= 80 then newTexts[#newTexts + 1] = entry end
        if i <= CONSOLE_DUMP_MAX then
            local where = safe(function()
                return string.format("%s static %d dyn %d", Probe.InterfaceName(entry.interfaceID),
                    entry.component.staticID, entry.component.dynamicID)
            end) or Probe.InterfaceName(entry.interfaceID)
            log("[rs3qb] " .. where .. ": " .. entry.text)
        end
    end
    local hadBaseline = next(lastScan) ~= nil
    lastScan = seenNow

    local candidates = app.stepCandidates(app.currentEntry())
    local matches = Probe.Matches(texts, candidates)
    local found = {}
    for _, match in ipairs(matches) do
        app.learnDialogInterface(match.interfaceID)
        found[#found + 1] = "\"" .. View.Escape(match.text) .. "\" in " .. Probe.InterfaceName(match.interfaceID)
    end
    local lines = { string.format("Scanned %d interfaces, %d texts (console has the full list).", #loaded, #texts) }
    if #candidates == 0 then
        lines[#lines + 1] = "This step has no dialogue options to look for."
    elseif #matches > 0 then
        lines[#lines + 1] = "Matched: " .. table.concat(found, "; ")
    else
        lines[#lines + 1] = "No match for: " .. table.concat(candidates, ", ")
    end
    if hadBaseline and #newTexts > 0 then
        local sample = {}
        for i = 1, math.min(#newTexts, 8) do
            sample[#sample + 1] = Probe.InterfaceName(newTexts[i].interfaceID) .. ": " .. View.Escape(newTexts[i].text)
        end
        lines[#lines + 1] = "New since last scan: " .. table.concat(sample, " | ")
    elseif not hadBaseline then
        lines[#lines + 1] = "Tip: scan once with no conversation, then again with one open, to see what it adds."
    end
    app.reports.probe = table.concat(lines, "<br>")
    Diag.Note(app.reports.probe)
    app.updateOptionMarks()
    app.refreshPanel()
end

-- "The Knight's Sword/Quick guide" -> "w/The_Knight%27s_Sword/Quick_guide?action=raw"
local function rawWikiPath(title)
    local path = title:gsub(" ", "_"):gsub("[^%w_/%-%.]", function(c)
        return string.format("%%%02X", c:byte())
    end)
    return "w/" .. path .. "?action=raw"
end

local pendingRequest = nil -- held so the request isn't collected mid-flight

-- Can the plugin reach the wiki? Downloads the quest's quick guide.
local function testWikiFetch(app)
    if not Plugin.HasPermission(PluginPermissions.httpAccess) then
        app.reports.fetch = "Wiki fetch: httpAccess not granted. In the console: ppe rs3-quest-buddy httpAccess"
        app.refreshPanel()
        return
    end
    local quest = app.currentQuest()
    if quest == nil then return end
    app.reports.fetch = "Wiki fetch: requesting " .. quest.wiki .. "..."
    pendingRequest = HTTPRequest.new(Plugin.urls.wiki, rawWikiPath(quest.wiki))
    pendingRequest:Get(function(request)
        if request.successful then
            local _, checklists = request.data:gsub("{{Checklist", "")
            app.reports.fetch = string.format("Wiki fetch OK: HTTP %s, %d bytes, %d checklist blocks.",
                tostring(request.responseCode), #request.data, checklists)
        else
            app.reports.fetch = string.format("Wiki fetch FAILED: HTTP %s, error %s %s, timed out %s. URL %s",
                tostring(request.responseCode), tostring(request.errorCode), tostring(request.errorInfo),
                tostring(request.timedOut), tostring(request.url))
        end
        Diag.Note(app.reports.fetch)
        pendingRequest = nil
        app.refreshPanel()
    end)
    app.refreshPanel()
end

-- What the API offers on this client, for the things the plugin would like
-- to use (IMPROVEMENTS E1-E3): the plugin layer's size, the font's own text
-- measuring, skill levels, the quest's requirement lists, a text input.
local function probeAPI(app)
    local lines = {}
    local function try(label, fn)
        local ok, result = pcall(fn)
        lines[#lines + 1] = label .. ": " .. (ok and View.Escape(tostring(result)) or ("error " .. View.Escape(tostring(result))))
    end
    try("plugin layer size", function()
        local layer = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
        return tostring(layer.width) .. "x" .. tostring(layer.height)
    end)
    try("font measure (300 wide)", function()
        local font = config.Font.MUSEO_SANS_15PT_REGULAR
        local sample = "The quick brown fox jumps over the lazy dog and keeps on running."
        local h, n = font:GetStringHeightAndLineCount(sample, 300, 18)
        return "height " .. tostring(h) .. ", lines " .. tostring(n) .. ", GetStringLineCount "
            .. tostring(font:GetStringLineCount(sample, 300)) .. ", width of 'Search the crate' "
            .. tostring(font:GetStringWidth("Search the crate")) .. " (estimate "
            .. string.format("%.0f", View.TextWidth("Search the crate")) .. "), baseline "
            .. tostring(font.baseline) .. ", ascent " .. tostring(font.maxAscent) .. ", descent "
            .. tostring(font.maxDescent)
    end)
    try("fonts", function()
        local names = {}
        for name in pairs(id.Font) do names[#names + 1] = tostring(name) end
        table.sort(names)
        return #names .. ": " .. table.concat(names, ", ")
    end)
    try("Player.GetLevelCapped(Attack)", function() return Player.GetLevelCapped(0) end)
    try("quest prerequisites", function()
        local quest = app.currentQuest()
        local questType = app.questTypeFor(quest)
        local skills, quests = 0, 0
        for _ in pairs(questType.preReqSkills) do skills = skills + 1 end
        for _ in pairs(questType.preReqQuests) do quests = quests + 1 end
        return skills .. " skills, " .. quests .. " quests, " .. tostring(questType.preReqQuestPoints) .. " points"
    end)
    try("ui.InputField", function() return ui.InputField ~= nil end)
    try("window size events seen", function() return app.windowSizeEvents end)
    app.reports.probe = "API probe:<br>" .. table.concat(lines, "<br>")
    Diag.Note(app.reports.probe)
    app.refreshPanel()
end

-- The panel's Debug section for `quest`. `app` gives: reports, varLog,
-- questInfo, currentQuest, currentEntry, stepCandidates, ownInterfaces,
-- learnDialogInterface, updateOptionMarks, refreshPanel.
function DevTools.Rows(app, quest)
    local rows = { { kind = "heading", text = "Debug" }, { kind = "text", text = app.questInfo(quest), colour = "muted" } }
    local entries = app.varLog[quest.key] or {}
    local recent = {}
    for i = math.max(1, #entries - 4), #entries do recent[#recent + 1] = entries[i] end
    rows[#rows + 1] = { kind = "text", colour = "muted",
        text = #recent > 0 and ("Var changes: " .. table.concat(recent, " | ")) or "Var changes: none yet" }
    if app.reports.action ~= "" then rows[#rows + 1] = { kind = "text", text = app.reports.action, colour = "muted" } end
    rows[#rows + 1] = { kind = "buttons", buttons = {
        { label = "Scan dialogue", press = function() scanDialogue(app) end },
        { label = "Wiki fetch", press = function() testWikiFetch(app) end },
        { label = "Probe API", press = function() probeAPI(app) end },
    } }
    for _, name in ipairs({ "dialogue", "probe", "fetch", "chat" }) do
        if app.reports[name] ~= "" then rows[#rows + 1] = { kind = "text", text = app.reports[name], colour = "muted" } end
    end
    return rows
end

return DevTools
