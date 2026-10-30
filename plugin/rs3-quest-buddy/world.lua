-- World highlights for the current step, RuneLite style:
--   * NPCs and scenery the step names ("trapdoor", "rocks"): a cyan outline
--     of their tiles and a bobbing arrow above them (the API has no model
--     outline, so this marks them instead). At most a few of each name, the
--     nearest ones.
--   * the step's destination: a beacon on the tile, until you're close
--   * a dotted path, one dot per tile, from the player towards the
--     destination (or the nearest highlighted target) when it's far away.
--     It walks around walls and solid objects (path.lua); ground the game
--     treats as blocked without an object there (water, cliffs) it can't see.
-- Tile markers are ShapeEntities (they follow the ground and draw
-- themselves); arrows and path dots are drawn fresh every frame from the
-- Draw event.

local Path = require("path")

local gameWorld = World           -- the API's World table (ground heights); our module shadows the name
local World = {}

local TILE = 512                  -- fine units per tile
local MAX_MARKERS = 8             -- NPC + scenery markers at once
local MAX_SAME_NAME = 3           -- markers per scenery name ("Door"), nearest first
local MAX_SAME_CLIMB = 1          -- stairs and ladders (all names together): just the nearest, where the dots lead
local FLOOR_NEAR = 40             -- tiles; this close to a target on another floor, show the stairs
local CROSSING_NEAR = 100         -- tiles; a dungeon entrance further than this is from another trip
local LOC_SEARCH_RANGE = 24       -- tiles around the player searched for scenery
local BEACON_HIDE_DISTANCE = 6    -- tiles; closer than this the beacon is just clutter
local PATH_MIN_DISTANCE = 4       -- tiles; closer than this the highlights are enough
local PATH_DOTS = 24              -- tiles of path shown ahead of the player
local PATH_RADIUS = 32            -- tiles around the player the path is planned in
local MAP_REFRESH_TICKS = 5       -- rebuild the walls map this often (doors open and close)
local LOC_ARROW_HEIGHT = 700      -- above the ground, for scenery without bounds
local HIGHLIGHT = 0x00FFFFFF      -- RGBA, RuneLite's default cyan
local BEACON_COLOUR = 0xFFD24AFF  -- gold, so the destination stands apart
local DOT_COLOUR = 0xFFE81EFF     -- brighter yellow than the beacon, to stand out on grass and stone
local BEACON_HEIGHT = 1800

local npcNames = {}               -- display names to highlight
local sceneryMatch = nil          -- function(loc) -> true to outline that object, or nil
local fallbackMatch = nil         -- used when nothing else is in sight (stairs upstairs, doors to enter)
local placeFor = nil              -- function(name) -> which one of several the step means (Advance.Placement)
local navTile = nil               -- { x, y, plane } destination, or nil
local markers, markerShapes = {}, {}
local beacon, beaconKey = nil, nil
local trackedNPCs = {}            -- NPCEntity list refreshed every tick
local trackedLocs = {}            -- { x, top, z } over each highlighted object
local targetsSeen = {}            -- fine positions of highlighted things, for the path
local pathDots = {}               -- fine positions of the path's dots, rebuilt every tick
local frame, tick = 0, 0
local walls, wallsTick, wallsX, wallsZ = nil, -100, nil, nil

World.pathEnabled = true
World.beaconEnabled = true   -- the destination tile marker (a setting)
World.dotSize = 90                -- half the width of a path dot, fine units (a tile is 512)
-- What the last update showed, for the recording: nil when no dots, else
-- { target = "x,y", walkable = true when routed around walls, detour = true
-- when that route bends noticeably away from a straight line }.
World.pathInfo = nil
World.pathSuppressed = false      -- a teleport is the better way there: no dots
local hidden = false               -- true during cutscenes: draw nothing

-- Rectangle outline (plus fill) covering width x length tiles. With
-- `withBeacon`, adds a tall vertical line so the tile shows from afar.
local function rectShape(width, length, colour, withBeacon)
    local hx, hz = width * TILE / 2 - 16, length * TILE / 2 - 16
    -- The entity sits on the centre of its south-west tile; shift bigger
    -- footprints so they cover all their tiles.
    local ox, oz = (width - 1) * TILE / 2, (length - 1) * TILE / 2
    local fill = (colour & 0xFFFFFF00) | 0x40
    local corners = {
        Vector3.new(ox - hx, 8, oz - hz), Vector3.new(ox + hx, 8, oz - hz),
        Vector3.new(ox + hx, 8, oz + hz), Vector3.new(ox - hx, 8, oz + hz),
    }
    -- Outline and fill need separate vertices to get separate alphas.
    local positions = { corners[1], corners[2], corners[3], corners[4],
        corners[1], corners[2], corners[3], corners[4] }
    local rgba = { colour, colour, colour, colour, fill, fill, fill, fill }
    local lines = { 0, 1, 1, 2, 2, 3, 3, 0 }
    if withBeacon then
        positions[9] = Vector3.new(0, 0, 0)
        positions[10] = Vector3.new(0, BEACON_HEIGHT, 0)
        rgba[9], rgba[10] = colour, colour
        lines[#lines + 1] = 8
        lines[#lines + 1] = 9
    end
    local data = ShapeData.new()
    data.positions = positions
    data.rgba = rgba
    data.lines = lines
    data.tris = { 4, 5, 6, 4, 6, 7 }
    return data
end

local function makeEntity(name, data)
    ShapeList.DestroyEntity(name) -- left over from a previous load
    local entity = ShapeList.CreateEntity(name)
    if entity == nil then return nil end
    if not entity:SetShapeData(data) then
        entity:Destroy()
        return nil
    end
    entity.ignoreDepth = true
    entity.lineWidth = 4.0
    entity.alignType = ShapeEntityAlignType.MODEL
    entity.visible = false
    return entity
end

-- Put marker `slot` on a tile, rebuilding its shape only when the size changes.
local function placeMarker(slot, coordGrid, width, length)
    local shapeKey = width .. "x" .. length
    local marker = markers[slot]
    if marker == nil or not marker.isValid or markerShapes[slot] ~= shapeKey then
        if marker ~= nil and marker.isValid then marker:Destroy() end
        marker = makeEntity("rs3qb-marker-" .. slot, rectShape(width, length, HIGHLIGHT, false))
        markers[slot] = marker
        markerShapes[slot] = shapeKey
    end
    if marker ~= nil then
        marker.coordGrid = coordGrid
        marker.visible = true
    end
end

-- What to highlight: `names` (NPC display names), `match` (function(loc)
-- picking scenery to outline, or nil), `nav` ({ x, y, plane } or nil), and
-- `fallback` (a matcher used when neither the NPCs nor the scenery are in
-- sight: the stairs upstairs, the doors for "Enter the manor"). `place`
-- (function(name) -> placement or nil) narrows several of one name to the
-- one the step means.
function World.SetTargets(names, match, nav, fallback, place)
    npcNames, sceneryMatch, navTile, fallbackMatch, placeFor = names or {}, match, nav, fallback, place
    trackedNPCs = {}
end

-- Names of everything marked on the last update, for diagnostics.
World.lastMarked = ""

local function playerEntity()
    local ok, player = pcall(Player.GetEntity)
    if ok and player ~= nil then return player end
    return nil
end

-- Global tile of a CoordGrid: x, z (nil when unreadable).
local function gridTile(coordGrid)
    local ok, x, z = pcall(function()
        return coordGrid.mapSquareX * 64 + coordGrid.localTileX, coordGrid.mapSquareZ * 64 + coordGrid.localTileZ
    end)
    if ok then return x, z end
    return nil
end

-- Tiles between the player and a { x, y } tile, or nil when unknown.
function World.DistanceTo(tile)
    local player = playerEntity()
    if player == nil or tile == nil then return nil end
    local ok, distance = pcall(function()
        local px, pz = player.position.x / TILE, player.position.z / TILE
        return math.sqrt((px - tile.x - 0.5) ^ 2 + (pz - tile.y - 0.5) ^ 2)
    end)
    return ok and distance or nil
end

-- Tiles to the nearest highlighted object, or nil when none is marked.
function World.NearestMarkedDistance()
    local player = playerEntity()
    if player == nil then return nil end
    local best = nil
    for _, loc in ipairs(trackedLocs) do
        local ok, d = pcall(function()
            return math.sqrt((player.position.x - loc.x) ^ 2 + (player.position.z - loc.z) ^ 2) / TILE
        end)
        if ok and (best == nil or d < best) then best = d end
    end
    return best
end

-- Hide everything (cutscenes) or bring it back.
function World.SetHidden(value)
    hidden = value
    if hidden then
        for i = 1, MAX_MARKERS do
            if markers[i] ~= nil and markers[i].isValid then markers[i].visible = false end
        end
        if beacon ~= nil and beacon.isValid then beacon.visible = false end
        trackedNPCs, trackedLocs, targetsSeen, pathDots = {}, {}, {}, {}
    end
end

-- Ground height at a fine position, or nil when the world can't say.
local function groundHeight(level, x, z)
    local ok, height = pcall(gameWorld.GetGroundHeight, level, x, z)
    if ok and type(height) == "number" and height >= 0 then return height end
    return nil
end

-- Top of a scenery object: its own bounds when the config has them.
local function locTop(loc)
    local top = nil
    pcall(function()
        local bounds = loc.config.customBounding
        if bounds ~= nil and bounds.maximum.y > 0 and bounds.maximum.y < 5000 then
            top = loc.position.y + bounds.maximum.y
        end
    end)
    return top or (loc.position.y + LOC_ARROW_HEIGHT)
end

-- ---------- path ----------

-- LocShapeType and RotationType values from the API docs.
local SHAPES = { WALL_STRAIGHT = 0, WALL_DIAGONALCORNER = 1, WALL_L = 2, WALL_SQUARECORNER = 3, WALL_DIAGONAL = 9,
    CENTREPIECE_STRAIGHT = 10, CENTREPIECE_DIAGONAL = 11, GROUNDDECOR = 22, WALL_L_ALT = 23 }
local ROTATIONS = { ZERO = 0, NINETY = 1, ONEEIGHTY = 2, TWOSEVENTY = 3 }

-- An enum value as its number, whether the API hands back a number or an
-- enum object (the in-game path still crossed walls; this rules that out).
local function enumNumber(value, enum, names)
    if type(value) == "number" then return value end
    for name, number in pairs(names) do
        local ok, same = pcall(function() return enum ~= nil and enum[name] == value end)
        if ok and same then return number end
    end
    local text, best, bestLength = tostring(value), nil, 0
    for name, number in pairs(names) do
        if text:find(name, 1, true) and #name > bestLength then best, bestLength = number, #name end
    end
    return best or tonumber(text:match("%-?%d+"))
end

-- Walls and solid objects around the player, rebuilt every few ticks or
-- after moving far from where it was built. World.wallStats sums up what
-- was found, for the recording.
World.wallStats = ""
local function wallsAround(player, px, pz)
    local moved = wallsX == nil or math.abs(px - wallsX) + math.abs(pz - wallsZ) > 8
    if walls ~= nil and not moved and tick - wallsTick < MAP_REFRESH_TICKS then return walls end
    local map = Path.NewMap()
    local counts = { objects = 0, blocking = 0, wall = 0, solid = 0, door = 0 }
    local shapeSample = nil
    local ok = pcall(function()
        for _, loc in pairs(LocList.ByDistance(player.coordGrid, PATH_RADIUS + 4, true)) do
            counts.objects = counts.objects + 1
            pcall(function()
                local config = loc.config
                if config.blockWalk then
                    counts.blocking = counts.blocking + 1
                    shapeSample = shapeSample or loc.shapeType
                    local x, z = gridTile(loc.coordGrid)
                    if x ~= nil then
                        local kind = Path.AddLoc(map, { x = x, z = z, width = loc.width, length = loc.length,
                            shape = enumNumber(loc.shapeType, LocShapeType, SHAPES),
                            rotation = enumNumber(loc.rotationType, RotationType, ROTATIONS), blocks = true,
                            name = loc.displayName })
                        if kind then counts[kind] = counts[kind] + 1 end
                    end
                end
            end)
        end
    end)
    World.wallStats = string.format("%d objects, %d block walking: %d walls, %d solid, %d doors; shape %s (%s)",
        counts.objects, counts.blocking, counts.wall, counts.solid, counts.door, tostring(shapeSample), type(shapeSample))
    walls, wallsTick, wallsX, wallsZ = ok and map or nil, tick, px, pz
    return walls
end

local function addDot(level, fromY, tileX, tileZ)
    local x, z = tileX * TILE + TILE / 2, tileZ * TILE + TILE / 2
    local y = groundHeight(level, x, z)
    -- A height far off the player's is a failed read (or a cliff): stay level.
    if y == nil or math.abs(y - fromY) > 1500 then y = fromY end
    pathDots[#pathDots + 1] = { x = x, y = y + 24, z = z }
end

-- Dots from the player towards fine position (tx, tz): along a walkable
-- path when the walls map is readable, else a straight line.
local function buildPath(player, tx, tz)
    pathDots = {}
    local from = player.position
    local dx, dz = tx - from.x, tz - from.z
    local tiles = math.sqrt(dx * dx + dz * dz) / TILE
    if tiles < PATH_MIN_DISTANCE then return end
    local level = 0
    pcall(function() level = player.coordGrid.level end)
    local px, pz = math.floor(from.x / TILE), math.floor(from.z / TILE)
    local map = wallsAround(player, px, pz)
    if map ~= nil then
        local targetX, targetZ = math.floor(tx / TILE), math.floor(tz / TILE)
        local route = Path.Find(map, px, pz, targetX, targetZ, PATH_RADIUS)
        for i = 1, math.min(#route, PATH_DOTS) do addDot(level, from.y, route[i].x, route[i].z) end
        -- Stop short of the target: its marker or beacon takes over there.
        if #route > 0 and #route < PATH_DOTS then table.remove(pathDots) end
        local last = route[#route]
        local straight = last and math.max(math.abs(last.x - px), math.abs(last.z - pz)) or 0
        World.pathInfo = #pathDots > 0 and { target = targetX .. "," .. targetZ, walkable = true,
            detour = #route > straight + 3 } or nil
        return
    end
    local lastKey = nil
    for i = 1, math.min(PATH_DOTS, math.floor(tiles) - 1) do
        local tileX = math.floor((from.x + dx * i / tiles) / TILE)
        local tileZ = math.floor((from.z + dz * i / tiles) / TILE)
        local key = tileX .. "," .. tileZ
        if key ~= lastKey then
            lastKey = key
            addDot(level, from.y, tileX, tileZ)
        end
    end
    World.pathInfo = #pathDots > 0 and { target = math.floor(tx / TILE) .. "," .. math.floor(tz / TILE),
        walkable = false, detour = false } or nil
end

-- ---------- per tick ----------

local function playerLevel(player)
    local ok, level = pcall(function() return player.coordGrid.level end)
    return ok and level or 0
end

-- Dungeons sit this far north on the map. A target on the other side of
-- that line is reached by a ladder or trapdoor, not by walking towards it.
local UNDERGROUND_Z = 6400

local function otherSide(player)
    if navTile == nil or player == nil then return false end
    local ok, z = pcall(function() return player.position.z / TILE end)
    return ok and (z >= UNDERGROUND_Z) ~= (navTile.y >= UNDERGROUND_Z)
end

local function isClimbable(name)
    name = tostring(name or ""):lower()
    return name:find("ladder", 1, true) ~= nil or name:find("stair", 1, true) ~= nil
        or name:find("trapdoor", 1, true) ~= nil or name:find("rope", 1, true) ~= nil
end

local function exitMatcher(loc) return isClimbable(loc.displayName) end

-- Stairs and ladders whose menu goes `direction` ("up" or "down").
local function stairsGoing(direction)
    return function(loc)
        if not isClimbable(loc.displayName) then return false end
        local ops = ""
        pcall(function()
            for _, op in pairs(loc.config.opNames) do ops = ops .. " " .. tostring(op):lower() end
        end)
        return ops == "" or ops:find(direction, 1, true) ~= nil
    end
end

-- The target is on another floor nearby (Sir Vyvin is two floors up):
-- "up" or "down", else nil.
local function otherFloor(player)
    if navTile == nil or navTile.plane == nil or player == nil then return nil end
    local level = playerLevel(player)
    if level == navTile.plane then return nil end
    local distance = World.DistanceTo(navTile)
    if distance == nil or distance > FLOOR_NEAR then return nil end
    return navTile.plane > level and "up" or "down"
end

-- Where the player crossed between the surface and a dungeon, so the dots
-- can lead back: the tile they arrived at underground (the ladder up is
-- there) and the last surface tile before going down (the trapdoor).
local lastSurface, lastUnderground, wasUnderground = nil, nil, nil
local undergroundArrival, surfaceDeparture = nil, nil

local function noteCrossing(player)
    local ok, x, z = pcall(function()
        return math.floor(player.position.x / TILE), math.floor(player.position.z / TILE)
    end)
    if not ok then return end
    local under = z >= UNDERGROUND_Z
    if wasUnderground == false and under then
        undergroundArrival, surfaceDeparture = { x = x, z = z }, lastSurface
    end
    if under then lastUnderground = { x = x, z = z } else lastSurface = { x = x, z = z } end
    wasUnderground = under
end

-- Centre of a loc's footprint, fine units (position is its south-west tile).
local function locCentre(loc)
    return loc.position.x + ((loc.width or 1) - 1) * TILE / 2, loc.position.z + ((loc.length or 1) - 1) * TILE / 2
end

local function cleanName(name) return tostring(name or ""):gsub("<[^>]*>", ""):lower() end

-- Does a scene name match a name from the guide? "Water wheel" for "water
-- wheel", "Crates" for "crate", "Small boxes" for "boxes".
local function sameThing(sceneName, wanted)
    sceneName, wanted = cleanName(sceneName), wanted:lower()
    local function bare(s) return (s:gsub("e?s$", "")) end
    return sceneName == wanted or bare(sceneName) == bare(wanted)
        or bare(sceneName:match("(%S+)$") or "") == bare(wanted:match("(%S+)$") or "")
            and (#wanted:match("(%S+)$") >= 4)
end

local PLACE_COS = 0.38            -- within ~67 degrees of the compass direction counts as "east of"
local EXTREME_NEAR = 12           -- tiles; "the bookcase on the eastern wall" is one of these nearby
local NAV_ROUGH = 16              -- tiles; a highlighted target this near the step's map spot is where to go

-- Is fine offset (dx, dz) roughly in compass direction `dir` ({ x, z })?
local function inDirection(dx, dz, dir)
    local length, dirLength = math.sqrt(dx * dx + dz * dz), math.sqrt(dir[1] ^ 2 + dir[2] ^ 2)
    return length > 0 and (dx * dir[1] + dz * dir[2]) / (length * dirLength) >= PLACE_COS
end

-- The nearest thing in the scene called `anchor` ("water wheel", "hatch"):
-- a loc nearby or one of the step's NPCs. Fine x, z, or nil.
local function findAnchor(player, anchor)
    local best, bestDistance = nil, math.huge
    local function consider(x, z)
        local d = (x - player.position.x) ^ 2 + (z - player.position.z) ^ 2
        if d < bestDistance then best, bestDistance = { x = x, z = z }, d end
    end
    pcall(function()
        for _, loc in pairs(LocList.ByDistance(player.coordGrid, LOC_SEARCH_RANGE, true)) do
            if sameThing(loc.displayName, anchor) then pcall(function() consider(locCentre(loc)) end) end
        end
    end)
    for _, name in ipairs(npcNames) do
        if sameThing(name, anchor) then
            pcall(function()
                for _, npc in pairs(NPCList.ByName(name)) do consider(npc.position.x, npc.position.z) end
            end)
        end
    end
    return best
end

-- Narrow one name's candidates (nearest first) to the one the step means,
-- as `placement` says (see Advance.Placement). Unchanged when the scene
-- doesn't fit (no anchor in sight, nothing on that side).
local function placeGroup(player, group, placement)
    local px, pz = player.position.x, player.position.z
    if placement.anchor then
        local anchor = findAnchor(player, placement.anchor)
        if anchor == nil then return group end
        local pool = group
        if placement.dir then
            pool = {}
            for _, f in ipairs(group) do
                if inDirection(f.x - anchor.x, f.z - anchor.z, placement.dir) then pool[#pool + 1] = f end
            end
            if #pool == 0 then return group end
        end
        local best, bestDistance = nil, math.huge
        for _, f in ipairs(pool) do
            local d = (f.x - anchor.x) ^ 2 + (f.z - anchor.z) ^ 2
            if d > 0 and d < bestDistance then best, bestDistance = f, d end
        end
        return best and { best } or group
    elseif placement.centre then
        -- "in the middle of the prison": the one nearest the middle of them all.
        if #group < 2 then return group end
        local cx, cz = 0, 0
        for _, f in ipairs(group) do cx, cz = cx + f.x / #group, cz + f.z / #group end
        local best, bestDistance = nil, math.huge
        for _, f in ipairs(group) do
            local d = (f.x - cx) ^ 2 + (f.z - cz) ^ 2
            if d < bestDistance then best, bestDistance = f, d end
        end
        return best and { best } or group
    elseif placement.extreme then
        -- The furthest that way; "second from the north" the next one along.
        local pool = {}
        for _, f in ipairs(group) do
            if f.d <= EXTREME_NEAR then pool[#pool + 1] = f end
        end
        table.sort(pool, function(a, b)
            return a.x * placement.dir[1] + a.z * placement.dir[2] > b.x * placement.dir[1] + b.z * placement.dir[2]
        end)
        local pick = pool[math.min(placement.rank or 1, #pool)]
        return pick and { pick } or group
    else
        local pool = {}
        for _, f in ipairs(group) do
            if inDirection(f.x - px, f.z - pz, placement.dir) then pool[#pool + 1] = f end
        end
        return #pool > 0 and pool or group
    end
end

-- Outline scenery picked by `match`, from marker `slot` on; returns the new
-- slot. The nearest first (the game's list isn't in distance order), at
-- most a few of each name and one way up or down, narrowed by `place`
-- (function(name) -> placement or nil) when the step says which one.
local function markScenery(player, match, slot, marked, place)
    local found, groups = {}, {}
    for _, loc in pairs(LocList.ByDistance(player.coordGrid, LOC_SEARCH_RANGE, true)) do
        local ok, wanted = pcall(match, loc)
        if ok and wanted then
            local x, z = 0, 0
            pcall(function() x, z = locCentre(loc) end)
            local d = 0
            pcall(function() d = math.sqrt((x - player.position.x) ^ 2 + (z - player.position.z) ^ 2) / TILE end)
            found[#found + 1] = { loc = loc, name = tostring(loc.displayName), x = x, z = z, d = d }
        end
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    if place ~= nil then
        -- Names placed the same way are one group: "the singular crate
        -- north-west of the hatch" picks among "Crate" and "Crates" alike.
        local kept, byName = {}, {}
        for _, f in ipairs(found) do
            if byName[f.name] == nil then
                local ok, placement = pcall(place, cleanName(f.name))
                placement = ok and placement or nil
                local key = f.name
                if placement then
                    key = string.format("%s|%s|%s|%s", placement.dir and placement.dir[1] or "",
                        placement.dir and placement.dir[2] or "", placement.anchor or "", tostring(placement.extreme))
                end
                groups[key] = groups[key] or { placement = placement }
                byName[f.name] = groups[key]
            end
            table.insert(byName[f.name], f)
        end
        for _, f in ipairs(found) do
            local group = byName[f.name]
            if group.placement and group.kept == nil then
                local ok, picked = pcall(placeGroup, player, group, group.placement)
                group.kept = {}
                for _, g in ipairs(ok and picked or group) do group.kept[g] = true end
            end
            if group.kept == nil or group.kept[f] then kept[#kept + 1] = f end
        end
        found = kept
    end
    local perName, climbs = {}, 0
    for _, f in ipairs(found) do
        if slot >= MAX_MARKERS then break end
        local climb = isClimbable(f.name)
        if (climb and climbs < MAX_SAME_CLIMB) or (not climb and (perName[f.name] or 0) < MAX_SAME_NAME) then
            if climb then climbs = climbs + 1 end
            perName[f.name] = (perName[f.name] or 0) + 1
            slot = slot + 1
            marked[#marked + 1] = "loc " .. f.name
            placeMarker(slot, f.loc.coordGrid, f.loc.width or 1, f.loc.length or 1)
            pcall(function()
                trackedLocs[#trackedLocs + 1] = { x = f.x, top = locTop(f.loc), z = f.z }
                targetsSeen[#targetsSeen + 1] = { x = f.x, z = f.z }
            end)
        end
    end
    return slot
end

-- Refresh what's highlighted; called every server tick. Returns how many
-- NPCs and scenery objects are marked.
function World.Update()
    tick = tick + 1
    if hidden then return 0, 0 end
    local slot, npcCount = 0, 0
    local marked = {}
    trackedNPCs, trackedLocs, targetsSeen, pathDots = {}, {}, {}, {}
    World.pathInfo = nil
    for _, name in ipairs(npcNames) do
        for _, npc in pairs(NPCList.ByName(name)) do
            if slot >= MAX_MARKERS then break end
            slot = slot + 1
            npcCount = npcCount + 1
            trackedNPCs[#trackedNPCs + 1] = npc
            marked[#marked + 1] = "npc " .. name
            local size = (npc.config and npc.config.gridSize) or 1
            placeMarker(slot, npc.coordGrid, size, size)
            pcall(function() targetsSeen[#targetsSeen + 1] = { x = npc.position.x, z = npc.position.z } end)
        end
    end
    -- Scenery the step is about, as picked by the app's matcher. On the wrong
    -- floor for the target, the stairs that way replace it (the doors on
    -- this floor aren't the ones the step means).
    local player = playerEntity()
    World.playerTile = nil
    if player ~= nil then
        noteCrossing(player)
        pcall(function()
            World.playerTile = { x = math.floor(player.position.x / TILE), z = math.floor(player.position.z / TILE),
                level = playerLevel(player) }
        end)
    end
    local npcSlots = slot
    local wrongSide = otherSide(player)
    local floorWay = not wrongSide and otherFloor(player) or nil
    if floorWay ~= nil then
        slot = markScenery(player, stairsGoing(floorWay), slot, marked)
    elseif sceneryMatch ~= nil and player ~= nil then
        slot = markScenery(player, sceneryMatch, slot, marked, placeFor)
    end
    if slot == 0 and fallbackMatch ~= nil and player ~= nil then
        slot = markScenery(player, fallbackMatch, slot, marked, placeFor)
    end
    if slot == 0 and wrongSide then slot = markScenery(player, exitMatcher, slot, marked) end
    World.lastMarked = table.concat(marked, ", ")
    for i = slot + 1, MAX_MARKERS do
        if markers[i] ~= nil and markers[i].isValid then markers[i].visible = false end
    end

    local navDistance = navTile and World.DistanceTo(navTile)
    -- A rough spot ("the room to the north") gets dots but no marker.
    if World.beaconEnabled and navTile ~= nil and not navTile.rough
        and (navDistance == nil or navDistance > BEACON_HIDE_DISTANCE) then
        if beacon == nil or not beacon.isValid then
            beacon = makeEntity("rs3qb-tile", rectShape(1, 1, BEACON_COLOUR, true))
            if beacon ~= nil then beacon:SetDrawDistance(48 * TILE, 64 * TILE) end
        end
        if beacon ~= nil then
            local key = navTile.x .. "," .. navTile.y
            if key ~= beaconKey then
                beacon.coordGrid = CoordGrid.new(navTile.plane or 0, navTile.x // 64, navTile.y // 64,
                    navTile.x % 64, navTile.y % 64)
                beaconKey = key
            end
            beacon.visible = true
        end
    elseif beacon ~= nil and beacon.isValid then
        beacon.visible = false
    end

    -- Where the dots go: back the way you came when the target is on the
    -- other side of a dungeon entrance, to the stairs when it's on another
    -- floor, else the target itself (or the nearest highlighted thing).
    if World.pathEnabled and not World.pathSuppressed and player ~= nil then
        local underground = wasUnderground == true
        local crossing = wrongSide and (underground and undergroundArrival or surfaceDeparture) or nil
        -- An entrance from some other trip (a teleport in between) is no guide.
        if crossing ~= nil and World.playerTile ~= nil
            and math.abs(crossing.x - World.playerTile.x) + math.abs(crossing.z - World.playerTile.z) > CROSSING_NEAR then
            crossing = nil
        end
        if wrongSide then
            if crossing ~= nil then pcall(buildPath, player, crossing.x * TILE + TILE / 2, crossing.z * TILE + TILE / 2) end
        elseif floorWay ~= nil and #trackedLocs > 0 then
            pcall(buildPath, player, trackedLocs[1].x, trackedLocs[1].z)
        else
            -- The nearest highlighted thing beats the map spot when it's
            -- around there: a wiki page's spot can be a whole room off (the
            -- Elemental Workshop's furnace).
            local nearest, nearestDistance = nil, math.huge
            for _, seen in ipairs(targetsSeen) do
                local d = (seen.x - player.position.x) ^ 2 + (seen.z - player.position.z) ^ 2
                if d < nearestDistance then nearest, nearestDistance = seen, d end
            end
            local nearNav = nearest ~= nil and navTile ~= nil
                and math.sqrt((nearest.x / TILE - navTile.x) ^ 2 + (nearest.z / TILE - navTile.y) ^ 2) <= NAV_ROUGH
            if navTile ~= nil and not nearNav then
                pcall(buildPath, player, navTile.x * TILE + TILE / 2, navTile.y * TILE + TILE / 2)
            elseif nearest ~= nil then
                pcall(buildPath, player, nearest.x, nearest.z)
            end
        end
    end
    return npcCount, slot - npcSlots
end

-- ---------- per-frame drawing ----------

-- A downward arrow floating above (x, top, z), bobbing gently. Two crossed
-- triangles so it reads from any camera angle.
local function drawArrowAbove(x, top, z)
    local y = top + 220 + math.sin(frame / 12) * 40
    local w, h = 110, 180
    ShapeList.Draw{
        shapePositions = {
            Vector3.new(x - w, y + h, z), Vector3.new(x + w, y + h, z), Vector3.new(x, y, z),
            Vector3.new(x, y + h, z - w), Vector3.new(x, y + h, z + w), Vector3.new(x, y, z),
        },
        shapeRGBA = { HIGHLIGHT, HIGHLIGHT, HIGHLIGHT, HIGHLIGHT, HIGHLIGHT, HIGHLIGHT },
        shapeTris = { 0, 1, 2, 3, 4, 5 },
        ignoreDepth = true,
    }
end

-- The path's dots as flat diamonds in one draw, fading only slightly ahead.
local function drawPath()
    local positions, rgba, tris = {}, {}, {}
    local size = World.dotSize
    for i, dot in ipairs(pathDots) do
        local alpha = math.floor(0xFF - (0xFF - 0xB0) * (i - 1) / math.max(1, #pathDots - 1))
        local colour = (DOT_COLOUR & 0xFFFFFF00) | alpha
        local n = #positions
        positions[n + 1] = Vector3.new(dot.x - size, dot.y, dot.z)
        positions[n + 2] = Vector3.new(dot.x, dot.y, dot.z - size)
        positions[n + 3] = Vector3.new(dot.x + size, dot.y, dot.z)
        positions[n + 4] = Vector3.new(dot.x, dot.y, dot.z + size)
        for k = 1, 4 do rgba[n + k] = colour end
        for _, v in ipairs({ 0, 1, 2, 0, 2, 3 }) do tris[#tris + 1] = n + v end
    end
    if #positions == 0 then return end
    ShapeList.Draw{ shapePositions = positions, shapeRGBA = rgba, shapeTris = tris, ignoreDepth = true }
end

function World.Draw()
    frame = frame + 1
    if hidden then return end
    for _, npc in ipairs(trackedNPCs) do
        if npc.isValid then
            pcall(function()
                local box = npc.aabb
                drawArrowAbove(box.centre.x, box.maximum.y, box.centre.z)
            end)
        end
    end
    for _, loc in ipairs(trackedLocs) do pcall(drawArrowAbove, loc.x, loc.top, loc.z) end
    if World.pathEnabled and not World.pathSuppressed then pcall(drawPath) end
end

function World.Shutdown()
    for i = 1, MAX_MARKERS do
        if markers[i] ~= nil and markers[i].isValid then markers[i]:Destroy() end
    end
    markers, markerShapes, trackedNPCs, trackedLocs, pathDots = {}, {}, {}, {}, {}
    if beacon ~= nil and beacon.isValid then beacon:Destroy() end
    beacon, beaconKey = nil, nil
end

return World
