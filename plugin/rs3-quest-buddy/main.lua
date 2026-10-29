-- Entry point. Loads the plugin inside a guard so a startup error shows up in
-- the panel (and is saved for debugging) instead of leaving it blank.

local traceback = (debug and debug.traceback) or tostring
local ok, err = xpcall(require, traceback, "app")

if ok then
    pcall(function() PersistentDB:Delete("diag.loadError") end)
else
    log("[rs3qb] failed to start: " .. tostring(err))
    pcall(function() PersistentDB:SetString("diag.loadError", tostring(err)) end)
    Event.ContentLayerReady.Subscribe("rs3qb-load-error", function(event)
        local text = ui.Text.new(event.component)
        text:SetPos(10, 10)
        text:SetSize(-20, -20, 1.0, 1.0)
        text.font = id.Font.MUSEO_SANS_15PT_REGULAR
        text.maxLines = 0
        text.content = "RS3 Quest Buddy failed to start:<br>" .. (tostring(err):gsub("<", "("))
    end)
end
