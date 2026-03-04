-- Rising Flood Mod
-- Creates a layered flood that rises upward around the player

local FLOOD_RADIUS = 8
local FLOOD_STEP   = 3   -- spacing between water sources
local FLOOD_HEIGHT = 5   -- how many layers upward the flood rises

-- Memory of replaced nodes per player
local flood_memory = {}

-- Helper: flood in layers
local function flood_area(playername, pos, radius, step, height)
    flood_memory[playername] = {}
    local mem = flood_memory[playername]

    for y = 0, height - 1 do
        for x = -radius, radius, step do
            for z = -radius, radius, step do
                local p = {x = pos.x + x, y = pos.y + y, z = pos.z + z}
                local node = minetest.get_node(p)
                if node.name ~= "default:water_source" then
                    table.insert(mem, {pos = p, old = node.name})
                    minetest.set_node(p, {name = "default:water_source"})
                end
            end
        end
    end
end

-- Helper: restore remembered nodes
local function unflood_area(playername)
    local mem = flood_memory[playername]
    if not mem then return end
    for _, entry in ipairs(mem) do
        minetest.set_node(entry.pos, {name = entry.old})
    end
    flood_memory[playername] = nil
end

-- /flood command
minetest.register_chatcommand("flood", {
    description = "Create a rising flood of water around you",
    privs = {server = true},
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        local pos = vector.round(player:get_pos())
        flood_area(name, pos, FLOOD_RADIUS, FLOOD_STEP, FLOOD_HEIGHT)
        return true, "The floodwaters are rising!"
    end
})

-- /unflood command
minetest.register_chatcommand("unflood", {
    description = "Remove flood water and restore terrain",
    privs = {server = true},
    func = function(name)
        unflood_area(name)
        return true, "The waters recede and the land is dry again."
    end
})
