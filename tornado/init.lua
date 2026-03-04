-- init.lua for Tornado Mod (cleaned, optimized)

local S = minetest.get_translator("tornado")

-- Cache global lookups
local M_get_node     = minetest.get_node
local M_set_node     = minetest.set_node
local M_add_particle = minetest.add_particle
local M_add_entity   = minetest.add_entity
local M_sound_play   = minetest.sound_play
local M_sound_stop   = minetest.sound_stop
local V_length       = vector.length
local V_subtract     = vector.subtract
local V_normalize    = vector.normalize
local V_round        = vector.round

-- Utility: parse JSON staticdata safely
local function parse_staticdata(sd)
  return (sd and sd ~= "") and minetest.parse_json(sd) or {}
end

-- Texture fallback table
local fallback_tiles = {
  dirt   = "default_dirt.png",
  stone  = "default_stone.png",
  sand   = "default_sand.png",
  gravel = "default_gravel.png",
  wood   = "default_wood.png",
  tree   = "default_wood.png",
  leaves = "default_leaves.png",
}

-- Resolve a node’s tile or return fallback
local function node_tile_or_fallback(nname)
  local def = minetest.registered_nodes[nname]
  if def and def.tiles and def.tiles[1] then
    local t = def.tiles[1]
    if type(t) == "string" then
      return t
    elseif type(t) == "table" and t.name then
      return t.name
    end
  end
  for key, tile in pairs(fallback_tiles) do
    if nname:find(key) then
      return tile
    end
  end
  return "default_dirt.png"
end

--------------------------------------------------------------------------------
-- EF Scale presets
--------------------------------------------------------------------------------
local EF_PRESETS = {
  [0] = { speed=3, radius=2,  height=4,  lifetime=40, dig_depth=0, pickup_mul=0.8, knockback=2, damage=0, leaf_shred=1 },
  [1] = { speed=4, radius=3,  height=6,  lifetime=50, dig_depth=1, pickup_mul=1.0, knockback=3, damage=1, leaf_shred=1 },
  [2] = { speed=5, radius=4,  height=7,  lifetime=60, dig_depth=2, pickup_mul=1.3, knockback=4, damage=2, leaf_shred=2 },
  [3] = { speed=6, radius=5,  height=8,  lifetime=70, dig_depth=3, pickup_mul=1.6, knockback=5, damage=3, leaf_shred=2 },
  [4] = { speed=7, radius=8,  height=9,  lifetime=80, dig_depth=4, pickup_mul=2.2, knockback=6, damage=4, leaf_shred=3 },
  [5] = { speed=8, radius=14, height=11, lifetime=90, dig_depth=8, pickup_mul=3.5, knockback=8, damage=5, leaf_shred=4 },
}

local function random_ef_weighted()
  local pool = {0,0,0,1,1,2,2,3,4,5}
  return pool[math.random(#pool)]
end

--------------------------------------------------------------------------------
-- Falling‐Node Entity (shorter life, lighter entity)
--------------------------------------------------------------------------------
minetest.register_entity("tornado:falling_node", {
  initial_properties = {
    physical         = false,
    collisionbox     = {0,0,0, 0,0,0},
    visual           = "wielditem",
    visual_size      = {x=0.3, y=0.3},
    textures         = {""},
    makes_footstep_sound = false,
    weight           = 5,
    automatic_rotate = 90,
    pointable        = false,
  },

  on_activate = function(self, staticdata)
    local data = parse_staticdata(staticdata)
    self.node_name = data.node or "default:dirt"
    self.object:set_properties({ textures = { self.node_name } })
    self.object:set_velocity({
      x = (math.random(-2,2) * 0.3),
      y = (math.random(2,4) * 0.6),
      z = (math.random(-2,2) * 0.3),
    })
    self.timer = 0
  end,

  get_staticdata = function(self)
    return minetest.write_json({ node = self.node_name })
  end,

  on_step = function(self, dtime)
    self.timer = self.timer + dtime
    if self.timer > 1.2 then
      local pos = V_round(self.object:get_pos() or {})
      local below = { x=pos.x, y=pos.y-1, z=pos.z }
      if M_get_node(below).name ~= "air" and M_get_node(pos).name == "air" then
        M_set_node(pos, { name = self.node_name })
        minetest.sound_play("tornado_debris_impact", {
          pos = pos,
          max_hear_distance = 8,
          gain = 0.8,
        })
      end
      self.object:remove()
    end
  end,
})

--------------------------------------------------------------------------------
-- Tornado Entity (ground‐following, EF, decay, dynamic audio, violence)
--------------------------------------------------------------------------------
minetest.register_entity("tornado:tornado", {
  initial_properties = {
    physical          = false,
    collisionbox      = {0,0,0, 0,0,0},
    visual            = "sprite",
    visual_size       = {x=4, y=8},
    use_texture_alpha = true,
    textures          = {"tornado_cloud.png"},
    makes_footstep_sound = false,
    pointable         = false,
  },

  -- runtime defaults
  speed           = 5,
  radius          = 3,
  height          = 6,
  max_lifetime    = 60,
  max_distance    = 200,
  ground_scan_max_depth = 10,

  ef_rating       = 0,
  decay_factor    = 1.0,
  sound_handle    = nil,

  dig_depth       = 0,
  pickup_mul      = 1.0,
  knockback       = 2,
  base_damage     = 0,
  leaf_shred_radius = 1,

  damage_interval = 0.8,
  last_hit        = {},

  on_activate = function(self, staticdata)
    local data = parse_staticdata(staticdata)
    self.ef_rating = data.ef or random_ef_weighted()
    local p = EF_PRESETS[self.ef_rating]

    -- apply preset
    self.speed     = p.speed
    self.radius    = p.radius
    self.height    = p.height
    self.max_lifetime = p.lifetime
    self.dig_depth = p.dig_depth
    self.pickup_mul= p.pickup_mul
    self.knockback= p.knockback
    self.base_damage = p.damage
    self.leaf_shred_radius = p.leaf_shred

    -- timers & tracking
    self.scan_timer        = 0
    self.lifetime          = 0
    self.distance_traveled = 0
    self.prev_pos          = self.object:get_pos()

    -- looping wind sound
    self.sound_handle = M_sound_play("tornado_wind", {
      object = self.object,
      loop   = true,
      max_hear_distance = 80,
      gain   = 1.0,
    })

    -- scale visual to EF
    self.object:set_properties({
      visual_size = {
        x = 3 + self.radius,
        y = 6 + self.height * 0.6,
      },
    })
  end,

  -- scan downward for ground
  find_ground_y = function(self, x, start_y, z)
    for dy = 0, self.ground_scan_max_depth do
      local y_check = math.floor(start_y) - dy
      if M_get_node({x=x, y=y_check, z=z}).name ~= "air" then
        return y_check
      end
    end
    return start_y - self.ground_scan_max_depth
  end,

  -- key for damage throttling
  victim_key = function(self, obj)
    if obj:is_player() then
      return "player:" .. (obj:get_player_name() or "")
    end
    return tostring(obj)
  end,

  -- shred leaves around a picked tree/leaves node
  shred_adjacent_leaves = function(self, center_pos)
    local r = self.leaf_shred_radius
    for dx = -r, r do
    for dy = -math.max(1, math.floor(r/2)), math.max(1, r) do
      for dz = -r, r do
        local p = {
            x = center_pos.x + dx,
            y = center_pos.y + dy,
            z = center_pos.z + dz,
          }
          if not minetest.is_protected(p, "") then
            local node      = minetest.get_node(p)
            local nodename  = node.name
            local groups    = (minetest.registered_nodes[nodename] or {}).groups or {}

            -- remove leaves, trunks, snowy leaves/blocks
            if (groups.leaves or 0) > 0
            or (groups.tree   or 0) > 0
            or nodename:find("snow")
            or (groups.snowy  or 0) > 0 then
              minetest.set_node(p, { name = "air" })
            end
          end
        end
      end
    end
  end,

  on_step = function(self, dtime)
    local obj = self.object
    local pos = obj:get_pos()

    -- clamp to ground
    local ground_y = self:find_ground_y(pos.x, pos.y+2, pos.z)
    local target_y = ground_y + 1
    if pos.y < target_y then
      pos.y = target_y
      obj:set_pos(pos)
    elseif pos.y > target_y + 2 then
      obj:set_pos({x=pos.x, y=target_y+1, z=pos.z})
    end

    -- movement & drift
    local yaw = obj:get_yaw()
    local dir = {
      x = -math.sin(yaw) * self.speed * self.decay_factor,
      y = 0,
      z = -math.cos(yaw) * self.speed * self.decay_factor,
    }

    -- avoid steep climbs
    local next_pos = { x=pos.x + dir.x*dtime, y=pos.y, z=pos.z + dir.z*dtime }
    local next_ground = self:find_ground_y(next_pos.x, pos.y+2, next_pos.z)
    if next_ground > ground_y + 2 then
      obj:set_yaw(yaw + (math.random()-0.5)*1.2)
      obj:set_velocity({ x=dir.x*0.2, y=0, z=dir.z*0.2 })
    else
      obj:set_velocity(dir)
      obj:set_pos({ x=next_pos.x, y=next_ground+1, z=next_pos.z })
    end

    if math.random() < 0.1 then
      obj:set_yaw(yaw + (math.random()-0.5)*0.4)
    end

    -- lifecycle & decay
    self.lifetime = self.lifetime + dtime
    self.distance_traveled = self.distance_traveled
      + V_length(V_subtract(obj:get_pos(), self.prev_pos))
    self.prev_pos = obj:get_pos()

    local t = math.min(self.lifetime / self.max_lifetime, 1)
    self.decay_factor = 1 - math.pow(t, 0.8)
    obj:set_properties({
      visual_size = {
        x = (3 + self.radius) * (0.6 + 0.4 * self.decay_factor),
        y = (6 + self.height*0.6) * (0.6 + 0.4 * self.decay_factor),
      },
    })

    -- dissipate if expired
    if self.lifetime >= self.max_lifetime
      or self.distance_traveled >= self.max_distance
      or self.decay_factor <= 0.02
    then
      if self.sound_handle then
        M_sound_stop(self.sound_handle)
      end
      obj:remove()
      return
    end

    -- block pickup (scaled by EF & decay)
    self.scan_timer = self.scan_timer + dtime
    local scan_interval = (0.22 + (1 - self.decay_factor)*0.20)
      * (1 - self.ef_rating*0.1)
    if self.scan_timer >= scan_interval then
      self.scan_timer = 0
      local base_max = math.floor(10 * self.pickup_mul)
      local decay_mul = 0.5 + 0.5*self.decay_factor
      local ef_bonus  = 1 + self.ef_rating*0.15
      local max_spawn = math.max(2, math.floor(base_max*decay_mul*ef_bonus))
      local hard_cap = (self.ef_rating>=5) and 20 or 15
      max_spawn = math.min(max_spawn, hard_cap)

      local spawn_count = 0
      local cur = obj:get_pos()
      local particle_chance = 0.7

      for dx = -self.radius, self.radius do
        if spawn_count >= max_spawn then break end
        for dz = -self.radius, self.radius do
          if spawn_count >= max_spawn then break end
          if V_length{x=dx,y=0,z=dz} <= self.radius then
            local surface_y = self:find_ground_y(cur.x+dx, cur.y+2, cur.z+dz)
            local min_y = surface_y - self.dig_depth
            local max_y = cur.y + math.floor(self.height*self.decay_factor)
            local y = min_y

            while y <= max_y and spawn_count < max_spawn do
              if not minetest.is_protected({x=cur.x+dx,y=y,z=cur.z+dz},"") then
                local p = { x=cur.x+dx, y=y, z=cur.z+dz }
                local node = M_get_node(p)
                if node.name ~= "air"
                  and self:can_tornado_pick(node.name, self.ef_rating)
                then
                  M_set_node(p, {name="air"})
                  if math.random() < particle_chance then
                    local tex = node_tile_or_fallback(node.name)
                    for i=1, math.random(2,5) do
                      M_add_particle{
                        pos = {x=p.x+math.random()-0.5, y=p.y+0.2+math.random()*0.6, z=p.z+math.random()-0.5},
                        velocity = {x=(math.random()-0.5)*2, y=1+math.random()*1.2, z=(math.random()-0.5)*2},
                        acceleration = {x=0,y=-8,z=0},
                        expirationtime = 0.4+math.random()*0.6,
                        size = 1+math.random()*1.5,
                        collisiondetection = false,
                        vertical = false,
                        texture = tex,
                      }
                    end
                  else
                    M_add_entity(p, "tornado:falling_node",
                                 minetest.write_json({node=node.name}))
                  end
                  spawn_count = spawn_count + 1
                  local g = (minetest.registered_nodes[node.name] or {}).groups or {}
                  if (g.leaves or 0)>0 or (g.tree or 0)>0 then
                    self:shred_adjacent_leaves(p)
                  end
                end
              end
              y = y + 1
            end
          end
        end
      end
    end

    -- violence: knockback & damage
    do
      local center = obj:get_pos()
      local victims = minetest.get_objects_inside_radius(center, self.radius+0.5)
      local dmg = math.floor(self.base_damage * (0.4 + 0.6*self.decay_factor))
      local kb  = self.knockback * (0.6 + 0.4*self.decay_factor)

      for _, v in ipairs(victims) do
        if v ~= obj then
          local vpos = v:get_pos()
          if vpos then
            local dir = V_normalize(V_subtract(vpos, center))
            v:add_velocity({x=dir.x*kb, y=kb*0.7, z=dir.z*kb})
            if dmg>0 then
              local key = self:victim_key(v)
              local last = self.last_hit[key] or -1e9
              if self.lifetime - last >= self.damage_interval then
                self.last_hit[key] = self.lifetime
                v:punch(obj, 0.5, {
                  full_punch_interval=1.0,
                  damage_groups={fleshy=dmg},
                }, dir)
              end
            end
          end
        end
      end
    end
  end,

  -- EF‐based pick logic (unchanged)
  can_tornado_pick = function(self, name, ef)
    local reg = minetest.registered_nodes[name]
    if not reg or name=="air" or reg.liquidtype~="none" then
      return false
    end
    local g = reg.groups or {}
    if (g.leaves or 0)>0 or (g.tree or 0)>0 then
      return true
    elseif ef<=1 then
      return (g.crumbly or 0)>0 or (g.snappy or 0)>0
    elseif ef<=3 then
      return (g.crumbly or 0)>0 or (g.snappy or 0)>0
         or ((g.cracky or 0)>0 and (g.cracky or 0)<=2)
    else
      return (g.crumbly or 0)>0 or (g.snappy or 0)>0 or (g.cracky or 0)>0
    end
  end,
})

--------------------------------------------------------------------------------
-- /tornado Chat Command
--------------------------------------------------------------------------------
local ef_labels = {
  "weak", "moderate", "considerable", "severe", "devastating", "incredible"
}

minetest.register_chatcommand("tornado", {
  params      = S("<ef_rating 0-5> (optional)"),
  description = S("Spawn a moving tornado at your position with optional EF rating"),
  privs       = { interact = true },
  func = function(name, param)
    local player = minetest.get_player_by_name(name)
    if not player then
      return false, S("Player not found")
    end

    local ef = tonumber(param)
    if not ef or ef<0 or ef>5 then
      ef = random_ef_weighted()
    else
      ef = math.floor(ef)
    end

    local pos = player:get_pos()
    pos.y = pos.y + 1

    local obj = M_add_entity(pos, "tornado:tornado",
                              minetest.write_json({ef=ef}))
    if obj then
      obj:set_yaw(math.random() * 2 * math.pi)
    end

    return true, S("Tornado spawned (EF-")..ef..S(" — ")..ef_labels[ef+1]..S(")")
  end,
})
