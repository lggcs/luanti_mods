-- griefer/init.lua
-- Wandering tunneling greifer entity with sounds, extended inventory, and bones-on-death loot

local MODNAME = "griefer"
local ENTNAME = MODNAME..":greifer"

local FOLLOW_RANGE = 20
local PLACE_INTERVAL = 20
local TUNNELING_CHANCE = 0.6
local WALK_SPEED = 2.5
local RUN_SPEED = 4.0
local JUMP_SPEED = 5
local STEP_INTERVAL = 0.2
local DIG_TARGETS = {
    ["default:dirt"] = true,
    ["default:dirt_with_grass"] = true,
    ["default:gravel"] = true,
    ["default:sand"] = true,
    ["default:stone"] = true,
    ["default:stone_with_coal"] = true,
    ["default:stone_with_iron"] = true,
    ["default:mossycobble"] = true
}
local PLACE_NODES = {
    "default:dirt",
    "default:cobble",
    "default:mossycobble",
    "default:stone"
}

local DIG_SOUND = "default_dig"
local PLACE_SOUND = "default_place_node"
local HURT_SOUND = "default_hurt"

local function random_offset(r)
    local angle = math.random() * math.pi * 2
    local dist = math.random() * r
    return { x = math.cos(angle) * dist, y = 0, z = math.sin(angle) * dist }
end

local function find_nearest_player(pos, range)
    local players = minetest.get_connected_players()
    local best, bestd = nil, range + 1
    for _, p in ipairs(players) do
        local d = vector.distance(pos, p:get_pos())
        if d < bestd then
            best = p
            bestd = d
        end
    end
    if best and bestd <= range then return best, bestd end
    return nil, nil
end

local function inv_add(self, itemstring)
    if not self._inv then self._inv = {} end
    table.insert(self._inv, itemstring)
end

local function inv_take_random(self)
    if not self._inv or #self._inv == 0 then return nil end
    local i = math.random(#self._inv)
    local it = table.remove(self._inv, i)
    return it
end

local function drop_inventory_as_items(self, pos)
    if not self._inv then return end
    for _, item in ipairs(self._inv) do
        local stack = ItemStack(item)
        while not stack:is_empty() do
            local drop = stack:take_item(math.min(stack:get_count(), math.random(1, math.max(1, stack:get_count()))))
            minetest.add_item(pos, drop)
        end
    end
    self._inv = {}
end

local function try_place_block(self, pos)
    for i = 1, 6 do
        local p = vector.add(pos, { x = math.random(-2,2), y = math.random(-1,1), z = math.random(-2,2) })
        local node = minetest.get_node_or_nil(p)
        if node and node.name == "air" then
            local place = PLACE_NODES[math.random(#PLACE_NODES)]
            if minetest.registered_nodes[place] and not minetest.is_protected(p, "") then
                minetest.set_node(p, { name = place })
                minetest.sound_play(PLACE_SOUND, { pos = p, gain = 0.6, max_hear_distance = 12 })
                -- simulate using one block from inventory if available, else add placed block as "used"
                local used = inv_take_random(self)
                if not used then
                    -- consume nothing but simulate that it "placed" a block by not adding to inventory
                end
                return true
            end
        end
    end
    return false
end

minetest.register_chatcommand("greifer", {
    params = "",
    description = "Spawn a greifer near you",
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found" end
        local pos = vector.add(player:get_pos(), { x = 2, y = 1, z = 0 })
        minetest.add_entity(pos, ENTNAME)
        return true, "Spawned greifer"
    end
})

minetest.register_entity(ENTNAME, {
    hp_max = 20,
    physical = true,
    collisionbox = { -0.3, 0, -0.3, 0.3, 1.6, 0.3 },
    visual = "mesh",
    mesh = "character.b3d",
    textures = { "character.png" },
    visual_size = { x = 1, y = 1 },
    pointable = false,

    timer = 0,
    place_timer = 0,
    target_pos = nil,
    following = nil,
    _inv = nil,
    walk_animation = { x = 0, y = 79 },
    stand_animation = { x = 81, y = 160 },

    on_activate = function(self, staticdata)
        self.object:set_armor_groups({ fleshy = 100 })
        self.timer = 0
        self.place_timer = math.random() * PLACE_INTERVAL
        -- seed a small inventory with random blocks
        self._inv = {}
        for i = 1, math.random(6, 18) do
            local pick = PLACE_NODES[math.random(#PLACE_NODES)]
            inv_add(self, pick .. " " .. tostring(math.random(1,4)))
        end
        if self.object.set_animation then
            self.object:set_animation(self.stand_animation, 30, 0)
        end
    end,

    on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir)
        local hp = self.object:get_hp()
        if hp <= 0 then return end
        if puncher and puncher:get_pos() then
            minetest.sound_play(HURT_SOUND, { pos = self.object:get_pos(), gain = 0.6, max_hear_distance = 12 })
            local ppos = puncher:get_pos()
            local mypos = self.object:get_pos()
            local away = vector.subtract(mypos, ppos)
            away = vector.normalize(away)
            local runvel = vector.multiply(away, RUN_SPEED)
            runvel.y = JUMP_SPEED * 0.6
            self.object:set_velocity(runvel)
        end
    end,

    on_step = function(self, dtime)
        self.timer = self.timer + dtime
        self.place_timer = self.place_timer + dtime
        if self.timer < STEP_INTERVAL then return end
        self.timer = 0

        local pos = self.object:get_pos()
        if not pos then return end

        local below = minetest.get_node_or_nil(vector.add(pos, { x = 0, y = -0.1, z = 0 }))
        local on_ground = below and below.name ~= "air" and pos.y - math.floor(pos.y) < 1.6

        local player, dist = find_nearest_player(pos, FOLLOW_RANGE)
        if player then
            self.following = player
            local ppos = player:get_pos()
            local offset = random_offset(3)
            self.target_pos = vector.add(ppos, offset)
        else
            self.following = nil
            if not self.target_pos or vector.distance(pos, self.target_pos) < 2 then
                local r = 12
                local ro = random_offset(r)
                local t = vector.add(pos, ro)
                local top = { x = t.x, y = t.y + 10, z = t.z }
                local bottom = { x = t.x, y = t.y - 20, z = t.z }
                local found_pos
                local ray = minetest.raycast(top, bottom, false, true)
                for pointed in ray do
                    if pointed.type == "node" and pointed.under then
                        found_pos = vector.add(pointed.under, { x = 0, y = 1, z = 0 })
                        break
                    end
                end
                if found_pos then
                    self.target_pos = found_pos
                else
                    self.target_pos = t
                end
            end
        end

        if self.place_timer >= PLACE_INTERVAL and math.random() < 0.5 then
            try_place_block(self, pos)
            self.place_timer = 0
        end

        local vel = { x = 0, y = 0, z = 0 }

        if self.target_pos then
            local dir = vector.subtract(self.target_pos, pos)
            dir.y = 0
            local dist_to_target = vector.length(dir)
            if dist_to_target > 0.5 then
                local desired = vector.normalize(dir)
                local speed = (self.following and (dist and dist < 6 and RUN_SPEED or WALK_SPEED)) or WALK_SPEED
                vel.x = desired.x * speed
                vel.z = desired.z * speed
                if self.object.set_animation then
                    self.object:set_animation(self.walk_animation, 30, 0)
                end
            else
                if self.object.set_animation then
                    self.object:set_animation(self.stand_animation, 30, 0)
                end
                if math.random() < 0.25 then
                    try_place_block(self, pos)
                end
            end
        else
            local r = random_offset(1.5)
            vel.x = r.x
            vel.z = r.z
            if self.object.set_animation then
                self.object:set_animation(self.walk_animation, 30, 0)
            end
        end

        local look_dir = { x = vel.x, y = 0, z = vel.z }
        if look_dir.x ~= 0 or look_dir.z ~= 0 then
            local forward_dist = 0.8
            local ahead = vector.add(pos, vector.multiply(vector.normalize(look_dir), forward_dist))
            local node_ahead = minetest.get_node_or_nil(ahead)
            if node_ahead and node_ahead.name ~= "air" then
                if DIG_TARGETS[node_ahead.name] and math.random() < TUNNELING_CHANCE and not minetest.is_protected(ahead, "") then
                    -- play dig sound, remove node, add drops to inventory
                    minetest.sound_play(DIG_SOUND, { pos = ahead, gain = 0.7, max_hear_distance = 12 })
                    local def = minetest.registered_nodes[node_ahead.name]
                    -- spawn drops into inventory simulation
                    if def and def.drop then
                        -- try to convert drop into itemstrings
                        local drops = minetest.get_node_drops(node_ahead.name, "")
                        for _, d in ipairs(drops) do
                            inv_add(self, d)
                        end
                    else
                        inv_add(self, node_ahead.name)
                    end
                    minetest.remove_node(ahead)
                else
                    if on_ground then
                        local above = minetest.get_node_or_nil(vector.add(ahead, { x = 0, y = 1, z = 0 }))
                        if above and above.name == "air" then
                            vel.y = JUMP_SPEED
                        else
                            local sideoff = random_offset(3)
                            self.target_pos = vector.add(pos, sideoff)
                        end
                    end
                end
            end
        end

        local curvel = self.object:get_velocity()
        if not on_ground then
            vel.y = curvel.y - 9.8 * STEP_INTERVAL
        else
            if not (vel.y and vel.y > 0) then vel.y = 0 end
        end

        self.object:set_velocity(vel)

        local horizontal_vel = { x = vel.x, y = 0, z = vel.z }
        local speed_h = vector.length(horizontal_vel)
        if speed_h > 0.1 then
            local yaw = math.atan2(horizontal_vel.z, horizontal_vel.x) + math.pi/2
            self.object:set_yaw(yaw)
        end

        local node_here = minetest.get_node_or_nil(pos)
        if node_here and (node_here.name == "default:water_source" or node_here.name == "default:water_flowing") then
            local up = vector.add(pos, { x = 0, y = 2, z = 0 })
            local above = minetest.get_node_or_nil(up)
            if above and above.name == "air" then
                self.object:set_velocity({ x = vel.x, y = 3, z = vel.z })
            end
        end

        if self.object:get_hp() <= 0 then
            local dpos = self.object:get_pos() or pos
            minetest.sound_play(HURT_SOUND, { pos = dpos, gain = 0.8, max_hear_distance = 16 })
            -- drop a bones node if available
            if minetest.registered_nodes["bones:bones"] and not minetest.is_protected(dpos, "") then
                minetest.set_node(dpos, { name = "bones:bones" })
                -- try to fill bones inventory if it exists
                local bones_inv = minetest.get_meta(dpos):get_inventory()
                if bones_inv and bones_inv.set_size then
                    if bones_inv.set_size("main", 8) then end
                end
            end
            -- drop inventory items as loot
            drop_inventory_as_items(self, dpos)
            self._inv = nil
            self.object:remove()
            return
        end
    end,
})
