-- Which build this is. As checked in, the test build used on the plugin beta
-- world: debug tools (devtools.lua) and the session recorder on by default.
-- tools/package.py rewrites this file in the zip it makes for mod.io.

return {
    name = "RS3 Quest Buddy (test)", -- shown at the top of the quest list
    release = false,      -- the public build: no debug tools, recording off until switched on
    devTools = true,      -- load devtools.lua (left out of the release zip)
    recordByDefault = true,
    -- Walking guidance: the dotted path, the destination tile marker and
    -- teleport suggestions. Off in a build where these aren't allowed; the
    -- settings for them then don't show either.
    guidance = true,
}
