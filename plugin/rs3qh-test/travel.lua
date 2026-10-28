-- Teleport suggestions: when the next place is far away, which lodestone
-- lands closest to it. Coordinates are each lodestone's tile (approximate
-- is fine: they only pick the nearest one). The plugin can't tell which
-- lodestones the player has unlocked, so it suggests the nearest overall.

local Travel = {}

local LODESTONES = {
    { "Al Kharid", 3297, 3184 }, { "Ardougne", 2634, 3348 }, { "Ashdale", 2474, 2708 },
    { "Bandit Camp", 3214, 2954 }, { "Burthorpe", 2899, 3544 }, { "Canifis", 3517, 3515 },
    { "Catherby", 2811, 3449 }, { "Draynor Village", 3105, 3298 }, { "Eagles' Peak", 2366, 3479 },
    { "Edgeville", 3067, 3505 }, { "Falador", 2967, 3403 },
    { "Fremennik Province", 2712, 3677 }, { "Karamja", 2761, 3147 }, { "Lumbridge", 3233, 3221 },
    { "Lunar Isle", 2085, 3914 }, { "Menaphos", 3216, 2716 }, { "Oo'glog", 2532, 2871 },
    { "Port Sarim", 3011, 3215 }, { "Prifddinas", 2208, 3360 }, { "Seers' Village", 2689, 3482 },
    { "Taverley", 2878, 3442 }, { "Varrock", 3214, 3376 }, { "Wilderness", 3143, 3635 },
    { "Yanille", 2529, 3094 },
}

local MIN_DISTANCE = 60      -- tiles; closer than this, just walk
local MIN_SAVING = 25        -- tiles a teleport must save to be worth it
local UNDERGROUND = 6400     -- dungeons sit this far north on the map
local MAX_WALK = 400         -- further than this from every lodestone: an island or instance

local function distance(x1, z1, x2, z2)
    return math.sqrt((x1 - x2) ^ 2 + (z1 - z2) ^ 2)
end

-- { name, walk } for the lodestone to use, or nil when walking is better.
-- `walk` is the distance in tiles from that lodestone to the target.
function Travel.Suggest(px, pz, tx, tz)
    -- Underground on either end: the way is a ladder or trapdoor, not a lodestone.
    if tz >= UNDERGROUND or pz >= UNDERGROUND then return nil end
    local here = distance(px, pz, tx, tz)
    if here < MIN_DISTANCE then return nil end
    local best, bestDistance = nil, math.huge
    for _, lode in ipairs(LODESTONES) do
        local d = distance(lode[2], lode[3], tx, tz)
        if d < bestDistance then best, bestDistance = lode[1], d end
    end
    if best == nil or bestDistance + MIN_SAVING >= here or bestDistance > MAX_WALK then return nil end
    return { name = best, walk = math.floor(bestDistance) }
end

-- The lodestone a step names, as { name, x, y }: "Teleport to Varrock",
-- "the Lumbridge lodestone". One called a lodestone outright wins over a
-- "teleport to" town; otherwise the first in the list.
function Travel.Named(text)
    local lower = " " .. text:lower():gsub("[^%w' ]", " ") .. " "
    local best, bestAt = nil, nil
    for _, lode in ipairs(LODESTONES) do
        local name = lode[1]:lower():gsub("[^%w' ]", " ")
        local at = lower:find(" " .. name .. " lodestone ", 1, true)
        local teleport = lower:find(" teleport to " .. name .. " ", 1, true)
        local where = at or teleport
        if where and (best == nil or (at and not bestAt)) then best, bestAt = lode, at end
    end
    return best and { name = best[1], x = best[2], y = best[3] } or nil
end

return Travel
