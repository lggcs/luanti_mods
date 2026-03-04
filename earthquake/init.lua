-- init.lua

-- Utility: random float
local function randf(min, max)
    return min + math.random() * (max - min)
end

-- Quick snow‐node check
local function is_snow(nodename)
    return nodename == "default:snow"
        or nodename == "default:snowblock"
end

-- Camera‐shake helper
local function shake_camera(player, intensity_deg, duration_s)
    local steps, count = math.floor(duration_s / 0.1), 0
    local function tick()
        if count < steps then
            local y  = player:get_look_horizontal()
            local p  = player:get_look_vertical()
            player:set_look_horizontal(y + math.rad(math.random(-intensity_deg, intensity_deg)))
            player:set_look_vertical(   p + math.rad(math.random(-intensity_deg, intensity_deg)))
            count = count + 1
            minetest.after(0.1, tick)
        end
    end
    tick()
end

-- Carve a realistic fault‐line rift
local function carve_rift(origin, magnitude, pname)
    local length    = math.floor(magnitude * 5)
    local width     = math.floor((magnitude - 5) * 1.5) + 1
    local depth     = math.min(math.floor((magnitude - 5) * 2), 6)
    local angle     = math.random() * 2 * math.pi
    local dx_dir    = math.cos(angle)
    local dz_dir    = math.sin(angle)
    local total_t   = length * 0.1

    -- progressively carve each segment
    for i = 1, length do
        local delay = i * (total_t / length)
        minetest.after(delay, function()
            -- center point of this slice
            local t   = i - length / 2
            local cx  = origin.x + dx_dir * t
            local cz  = origin.z + dz_dir * t
            local ix  = math.floor(cx + 0.5)
            local iz  = math.floor(cz + 0.5)

            for lx = -width, width do
            for lz = -width, width do
                if lx*lx + lz*lz <= width*width then
                    for dy = 0, depth do
                        local p = { x = ix+lx, y = origin.y - dy, z = iz+lz }
                        -- remove snow above so it doesn't float
                        local above = { x = p.x, y = p.y + 1, z = p.z }
                        local anode = minetest.get_node(above).name
                        if is_snow(anode) then
                            minetest.remove_node(above)
                        end
                        -- carve the rift
                        minetest.set_node(p, { name = "air" })
                    end
                end
            end
            end
        end)
    end

    -- notify when done
    minetest.after(total_t + 0.5, function()
        minetest.chat_send_player(pname,
          ("Fault rift %d nodes long, %d wide has opened!"):format(length, width*2))
    end)
end

-- Fluid‐like crater under players
local function sink_crater(origin, player, magnitude)
    local ppos        = player:get_pos()
    local cx, cz      = math.floor(ppos.x + 0.5), math.floor(ppos.z + 0.5)
    local ground_y    = math.floor(ppos.y - 0.5)
    local sink_d      = math.min(2, math.floor(magnitude * 0.3))
    local sink_r      = math.min(3, math.floor(magnitude * 1.2))

    for dy = 0, sink_d do
        minetest.after(dy * 0.3, function()
            local layer_r = math.floor(sink_r * (1 - dy / (sink_d + 1)))
            for dx = -layer_r, layer_r do
            for dz = -layer_r, layer_r do
                if dx*dx + dz*dz <= layer_r*layer_r then
                    local p = { x = cx+dx, y = ground_y-dy, z = cz+dz }
                    local n = minetest.get_node(p).name
                    if not is_snow(n) then
                        minetest.set_node(p, { name = "air" })
                        for _, item in ipairs(minetest.get_node_drops(n)) do
                            minetest.add_item(p, item)
                        end
                        minetest.sound_play("default_dig_dirt", {
                            pos               = p,
                            gain              = 1.0,
                            max_hear_distance = 10,
                        })
                    else
                        -- drop snow instead of letting it float
                        minetest.remove_node(p)
                    end
                end
            end
            end
        end)
    end
end

-- Core quake
local function quake_at(pos, magnitude, pname)
    local origin = vector.new(pos)
    local radius = math.floor(magnitude * 2)

    -- custom quake sound
    minetest.sound_play("earthquake", {
        pos               = origin,
        gain              = 2.5,
        max_hear_distance = radius * 2,
    })

    -- notify
    minetest.chat_send_player(pname,
      ("Earthquake! Magnitude: %.1f"):format(magnitude))

    -- shake cameras
    for _, pl in ipairs(minetest.get_connected_players()) do
        if vector.distance(pl:get_pos(), origin) <= radius * 2 then
            shake_camera(pl, magnitude * 0.5, magnitude * 0.6)
            sink_crater(origin, pl, magnitude)
        end
    end

    -- non‐lethal damage
    for _, obj in ipairs(minetest.get_objects_inside_radius(origin, radius * 2)) do
        if obj.get_hp then
            local hp  = obj:get_hp()
            local dmg = math.floor(magnitude * math.random(1, 2))
            dmg = math.min(dmg, hp - 1)
            if dmg > 0 then
                obj:punch(nil, 1.0, {
                    full_punch_interval = 1.0,
                    damage_groups       = { fleshy = dmg },
                }, nil)
            end
        end
    end

    -- surface break + scatter
    for dx = -radius, radius do
    for dz = -radius, radius do
        local dist = math.sqrt(dx*dx + dz*dz)
        if dist <= radius then
            local chance = (1 - dist / radius) * (magnitude / 10)
            if math.random() < chance then
                local p = { x = origin.x+dx, y = origin.y, z = origin.z+dz }
                local node = minetest.get_node(p)
                local def  = minetest.registered_nodes[node.name]
                if def and def.liquidtype == "none" then
                    -- remove snow by default
                    if is_snow(node.name) then
                        minetest.remove_node(p)
                    else
                        minetest.set_node(p, { name = "air" })
                        for _, item in ipairs(minetest.get_node_drops(node.name)) do
                            minetest.add_item(p, item)
                        end
                    end
                    minetest.sound_play("default_dig_dirt", {
                        pos               = p,
                        gain              = 1.0,
                        max_hear_distance = 10,
                    })
                end
            end
        end
    end
    end

    -- realistic rift if strong
    if magnitude >= 6.0 then
        carve_rift(origin, magnitude, pname)
    end
end

-- register command
minetest.register_chatcommand("earthquake", {
    params      = "[magnitude]",
    description = "Trigger a realistic quake (Richter scale).",
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        local mag = tonumber(param)
        if mag then mag = math.max(1, math.min(mag, 9))
        else      mag = randf(3.0, 8.5) end
        quake_at(player:get_pos(), mag, name)
        return true
    end,
})
