-- Walking path for the dotted line: A* over the tiles around the player,
-- steering around what the game says blocks walking. Pure logic (no game
-- calls) so it can be tested offline; world.lua feeds it the scenery.
--
-- What blocks: walls on a tile's edge (by rotation), and solid objects
-- (rocks, tables, trees) on whole tiles. Doors and gates count as open,
-- since the player can open them. What it can't know: water and cliffs
-- that are part of the ground rather than objects; the API doesn't expose
-- the game's collision map.

local Path = {}

-- LocShapeType values (see LocType docs).
local WALL_STRAIGHT, WALL_L, WALL_DIAGONAL, WALL_L_ALT = 0, 2, 9, 23
local CENTREPIECE_STRAIGHT, CENTREPIECE_DIAGONAL, GROUNDDECOR = 10, 11, 22

-- A wall's rotation names the tile side it stands on: 0 west, 1 north,
-- 2 east, 3 south (north is +z). L-shaped walls also cover the next side.
local SIDES = { [0] = "w", [1] = "n", [2] = "e", [3] = "s" }
local STEP = { e = { 1, 0 }, w = { -1, 0 }, n = { 0, 1 }, s = { 0, -1 } }
local OPPOSITE = { e = "w", w = "e", n = "s", s = "n" }

local function key(x, z) return x * 65536 + z end

function Path.NewMap()
    return { tiles = {}, edges = {} }
end

-- Add one object. `loc` = { x, z, width, length, shape, rotation, blocks, name }
-- with x, z its south-west tile. Returns what it counted as ("wall",
-- "solid", "door") or nil when it doesn't block.
function Path.AddLoc(map, loc)
    if not loc.blocks then return nil end
    local name = (loc.name or ""):lower()
    if name:find("door") or name:find("gate") then return "door" end
    local shape = loc.shape
    if shape == WALL_STRAIGHT or shape == WALL_L or shape == WALL_L_ALT then
        local side = SIDES[(loc.rotation or 0) % 4]
        map.edges[key(loc.x, loc.z) .. side] = true
        if shape ~= WALL_STRAIGHT then
            map.edges[key(loc.x, loc.z) .. SIDES[((loc.rotation or 0) + 1) % 4]] = true
        end
        return "wall"
    elseif shape == WALL_DIAGONAL or shape == CENTREPIECE_STRAIGHT or shape == CENTREPIECE_DIAGONAL
        or shape == GROUNDDECOR then
        for dx = 0, math.max(1, loc.width or 1) - 1 do
            for dz = 0, math.max(1, loc.length or 1) - 1 do
                map.tiles[key(loc.x + dx, loc.z + dz)] = true
            end
        end
        return "solid"
    end
    return nil
end

-- Can the player step from (x, z) one tile towards `dir` ("n", "e", ...)?
local function canStep(map, x, z, dir)
    local d = STEP[dir]
    local nx, nz = x + d[1], z + d[2]
    if map.tiles[key(nx, nz)] then return false end
    if map.edges[key(x, z) .. dir] or map.edges[key(nx, nz) .. OPPOSITE[dir]] then return false end
    return true
end

-- Diagonal moves need both L-shaped routes around the corner to be open.
local function canDiagonal(map, x, z, dx, dz)
    local h, v = dx > 0 and "e" or "w", dz > 0 and "n" or "s"
    if map.tiles[key(x + dx, z + dz)] then return false end
    return canStep(map, x, z, h) and canStep(map, x + dx, z, v)
        and canStep(map, x, z, v) and canStep(map, x, z + dz, h)
end

-- ---------- binary heap of { f, x, z } ----------

local function push(heap, node)
    heap[#heap + 1] = node
    local i = #heap
    while i > 1 do
        local parent = i // 2
        if heap[parent][1] <= heap[i][1] then break end
        heap[parent], heap[i] = heap[i], heap[parent]
        i = parent
    end
end

local function pop(heap)
    local top = heap[1]
    local last = table.remove(heap)
    if #heap > 0 then
        heap[1] = last
        local i = 1
        while true do
            local l, r, smallest = i * 2, i * 2 + 1, i
            if l <= #heap and heap[l][1] < heap[smallest][1] then smallest = l end
            if r <= #heap and heap[r][1] < heap[smallest][1] then smallest = r end
            if smallest == i then break end
            heap[i], heap[smallest] = heap[smallest], heap[i]
            i = smallest
        end
    end
    return top
end

-- Octile distance: diagonal steps cost the same as straight ones in game,
-- but preferring straight lines keeps the dots tidy.
local function estimate(x, z, tx, tz)
    local dx, dz = math.abs(tx - x), math.abs(tz - z)
    return math.max(dx, dz) + 0.4 * math.min(dx, dz)
end

-- Tiles from (sx, sz) towards (tx, tz), start excluded, staying within
-- `radius` tiles of the start. When the target is further out (or can't be
-- reached), the path goes to the reachable tile closest to it. Returns a
-- list of { x, z }, empty when the player is already as close as it gets.
function Path.Find(map, sx, sz, tx, tz, radius)
    local open, came, cost = {}, {}, {}
    local startKey = key(sx, sz)
    cost[startKey] = 0
    push(open, { estimate(sx, sz, tx, tz), sx, sz })
    local bestKey, bestX, bestZ, bestH = startKey, sx, sz, estimate(sx, sz, tx, tz)
    local expanded = 0
    while #open > 0 and expanded < 6000 do
        local node = pop(open)
        local x, z = node[2], node[3]
        local here = key(x, z)
        expanded = expanded + 1
        if x == tx and z == tz then
            bestKey, bestX, bestZ = here, x, z
            break
        end
        local h = estimate(x, z, tx, tz)
        if h < bestH then bestKey, bestX, bestZ, bestH = here, x, z, h end
        for dx = -1, 1 do
            for dz = -1, 1 do
                if (dx ~= 0 or dz ~= 0) and math.abs(x + dx - sx) <= radius and math.abs(z + dz - sz) <= radius then
                    local ok
                    if dx ~= 0 and dz ~= 0 then
                        ok = canDiagonal(map, x, z, dx, dz)
                    else
                        ok = canStep(map, x, z, dx > 0 and "e" or dx < 0 and "w" or dz > 0 and "n" or "s")
                    end
                    if ok then
                        local nextKey = key(x + dx, z + dz)
                        local newCost = cost[here] + ((dx ~= 0 and dz ~= 0) and 1.4 or 1)
                        if cost[nextKey] == nil or newCost < cost[nextKey] then
                            cost[nextKey] = newCost
                            came[nextKey] = { here, x, z }
                            push(open, { newCost + estimate(x + dx, z + dz, tx, tz), x + dx, z + dz })
                        end
                    end
                end
            end
        end
    end
    local tiles, at = {}, bestKey
    local x, z = bestX, bestZ
    while at ~= startKey and came[at] ~= nil do
        table.insert(tiles, 1, { x = x, z = z })
        local from = came[at]
        at, x, z = from[1], from[2], from[3]
    end
    return tiles
end

return Path
