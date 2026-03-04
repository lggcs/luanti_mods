-- meteors/init.lua
local MOD = minetest.get_current_modname()

-- CONFIG
local cfg = {
  global_max_concurrent = 28,
  per_player_max_nearby = 6,
  minute_spawn_cap = 60,
  spawn_radius = 80,
  spawn_height_min = 36,
  spawn_height_max = 100,
  burst_min = 3,
  burst_max = 9,
  stagger_max = 1.1,
  scheduler_interval = 2.6,
  cleanup_timeout = 300,
  default_trail_texture = "tnt_smoke.png",
  use_fire_node = (minetest.registered_nodes["fire:basic_flame"] ~= nil),
  crater_lava_chance = 0.02,        -- lowered baseline lava chance
  crater_lava_min_depth = 3,        -- only allow lava when crater depth >= this
  crater_lava_depth_check = 4,
  tnt_sound_name = "tnt_explode",
  -- realism tuning
  atmosphere_drag = 0.995,
  water_drag = 0.88,
  splash_particle = "tnt_smoke.png",
  canopy_clear_radius = 1,          -- radius (blocks) to clear leaves around lava column top
}

-- SIZE PRESETS
local SIZES = {
  small = {
    visual_scale = 0.58, speed = 26, damage = 6, impact_radius = 2, crater_depth = 2,
    debris_chance = 0.08, trail_particles = 2, spawn_weight = 55, texture = "default_stone.png",
  },
  medium = {
    visual_scale = 0.96, speed = 18, damage = 12, impact_radius = 4, crater_depth = 3,
    debris_chance = 0.16, trail_particles = 5, spawn_weight = 32, texture = "default_cobble.png",
  },
  large = {
    visual_scale = 1.36, speed = 12, damage = 30, impact_radius = 6, crater_depth = 5,
    debris_chance = 0.26, trail_particles = 1, spawn_weight = 13, texture = "default_obsidian.png",
  },
}

-- RUNTIME STATE
local state = { running = false, entities = {}, spawned_minute = 0, minute_timer = 0 }
math.randomseed(os.time())

-- HELPERS
local function node_exists(name) return name and minetest.registered_nodes[name] ~= nil end
local function def(name) if not name then return nil end return minetest.registered_nodes[name] end

local function is_flammable(node_name)
  local d = def(node_name)
  if not d then return false end
  if d.groups and d.groups.flammable and d.groups.flammable > 0 then return true end
  if node_name:find("leaves") or node_name:find("grass") then return true end
  return false
end

local function is_tree_or_wood(node_name)
  local d = def(node_name)
  if not d then return false end
  if d.groups and (d.groups.tree == 1 or d.groups.wood == 1) then return true end
  if node_name:find("tree") or node_name:find("wood") or node_name:find("leaves") then return true end
  return false
end

local function is_snowlike(node_name)
  local d = def(node_name)
  if not d then return false end
  if node_name:find("snow") then return true end
  if d.groups and (d.groups.snowlike and d.groups.snowlike > 0) then return true end
  return false
end

local function is_liquid_node(node_name)
  local d = def(node_name)
  if not d then return false end
  if d.groups and d.groups.liquid and d.groups.liquid > 0 then return true end
  if d.drawtype == "liquid" then return true end
  return false
end

local function choose_size()
  local total = 0 for _, s in pairs(SIZES) do total = total + s.spawn_weight end
  local r = math.random() * total local acc = 0
  for name, s in pairs(SIZES) do acc = acc + s.spawn_weight if r <= acc then return name, s end end
  return "small", SIZES.small
end

local function tidy_entities()
  local new = {}
  for _, ent in ipairs(state.entities) do
    if ent and ent:get_pos() then table.insert(new, ent) end
  end
  state.entities = new
end

-- find a walkable (solid) node below sample_pos within max_depth scan
local function find_solid_below(sample_pos, max_depth)
  max_depth = math.max(1, math.floor(max_depth or 32))
  for dy = 0, max_depth do
    local p = {x = sample_pos.x, y = sample_pos.y - dy, z = sample_pos.z}
    local n = minetest.get_node_or_nil(p)
    if not n or n.name == "ignore" then return nil, nil end
    local d = def(n.name)
    if d and d.walkable then
      return p, n.name
    end
  end
  return nil, nil
end

-- CRATER: returns list of bottom positions
-- treats liquids as transparent when locating true solid bottoms so underwater craters sit on real ground
local function make_crater(center, radius, depth)
  radius = math.max(1, math.floor(radius)); depth = math.max(1, math.floor(depth))
  local xmin, xmax = math.floor(center.x - radius), math.floor(center.x + radius)
  local zmin, zmax = math.floor(center.z - radius), math.floor(center.z + radius)
  local ytop = math.floor(center.y + 1)
  local ybottom = math.floor(center.y - depth)
  local bottoms = {}
  for x = xmin, xmax do
    for z = zmin, zmax do
      local dx, dz = x - center.x, z - center.z
      local dist = math.sqrt(dx*dx + dz*dz)
      if dist <= radius + 0.5 then
        local depth_factor = math.floor((radius - dist) / radius * depth + 0.5)
        local chosen_y = nil
        -- prefer the first non-liquid, non-air node within depth_factor
        for y = ytop, ybottom, -1 do
          if (ytop - y) <= depth_factor then
            local p = {x = x, y = y, z = z}
            local node = minetest.get_node_or_nil(p)
            if node and node.name and node.name ~= "ignore" then
              if node.name == "air" or is_liquid_node(node.name) then
                -- keep searching deeper
              else
                chosen_y = y
                break
              end
            end
          end
        end
        if not chosen_y then
          for y = ytop, ybottom, -1 do
            if (ytop - y) <= depth_factor then
              local p = {x = x, y = y, z = z}
              local node = minetest.get_node_or_nil(p)
              if node and node.name and node.name ~= "ignore" then chosen_y = y; break end
            end
          end
        end
        if chosen_y then
          -- carve from chosen_y up to ytop limited by depth_factor
          for y = ytop, chosen_y, -1 do
            if (ytop - y) <= depth_factor then
              local p = {x = x, y = y, z = z}
              local n = minetest.get_node_or_nil(p)
              if n and n.name and n.name ~= "ignore" then
                if node_exists("air") then minetest.set_node(p, {name = "air"}) end
              end
            end
          end
          table.insert(bottoms, {x = x, y = chosen_y, z = z})
        end
      end
    end
  end
  return bottoms
end

-- IGNITE AREA
local function ignite_area(center, radius, chance)
  radius = math.max(1, math.floor(radius))
  for dx = -radius, radius do for dz = -radius, radius do for dy = -1, 2 do
    local p = {x = center.x + dx, y = center.y + dy, z = center.z + dz}
    local n = minetest.get_node_or_nil(p)
    if n and n.name and n.name ~= "ignore" and is_flammable(n.name) then
      if math.random() < chance then
        if cfg.use_fire_node and node_exists("fire:basic_flame") then
          minetest.set_node(p, {name = "fire:basic_flame"})
        else
          if node_exists("air") then minetest.set_node(p, {name = "air"}) end
        end
      end
    end
  end end end
end

-- SAFE LAVA PLACEMENT: remove leaves/wood/snow above bottom so lava sits in crater
-- only allow lava when crater depth >= configured minimum and when column above bottom is clear of liquids and non-removable solids
local function maybe_fill_lava(bottoms, crater_depth_actual)
  if not bottoms or #bottoms == 0 then return end
  crater_depth_actual = crater_depth_actual or 0
  if crater_depth_actual < cfg.crater_lava_min_depth then return end
  local lava_name = node_exists("default:lava_source") and "default:lava_source" or (node_exists("lava:source") and "lava:source" or nil)
  if not lava_name then return end

  for _, bp in ipairs(bottoms) do
    if math.random() < cfg.crater_lava_chance then
      local safe = true
      local node_at_bottom = minetest.get_node_or_nil({x = bp.x, y = bp.y, z = bp.z})
      if not node_at_bottom or node_at_bottom.name == "ignore" then safe = false end

      if not safe then goto continue end

      -- don't place lava if bottom is under or next to player-built solid structures:
      -- quick heuristic: if any non-natural solid block is adjacent at bottom level, skip
      for ax = -1, 1 do for az = -1, 1 do
        local adj = {x = bp.x + ax, y = bp.y, z = bp.z + az}
        local an = minetest.get_node_or_nil(adj)
        if an and an.name and an.name ~= "ignore" then
          local ad = def(an.name)
          if ad and ad.groups and ad.groups.cracky and not is_tree_or_wood(an.name) then
            safe = false
            break
          end
        end
      end if not safe then break end end

      if not safe then goto continue end

      -- check and clear column above bottom up to depth_check:
      for h = 1, cfg.crater_lava_depth_check do
        local checkp = {x = bp.x, y = bp.y + h, z = bp.z}
        local n = minetest.get_node_or_nil(checkp)
        if not n or n.name == "ignore" then safe = false; break end
        if n.name == "air" then
          -- fine
        elseif is_tree_or_wood(n.name) or is_snowlike(n.name) then
          -- remove canopy / snow near top to prevent flowing from leaves/snow
          -- also clear a small radius at the top to avoid nearby leaves dripping lava
          for cx = -cfg.canopy_clear_radius, cfg.canopy_clear_radius do
            for cz = -cfg.canopy_clear_radius, cfg.canopy_clear_radius do
              local cp = {x = checkp.x + cx, y = checkp.y, z = checkp.z + cz}
              local cn = minetest.get_node_or_nil(cp)
              if cn and cn.name and cn.name ~= "ignore" and (is_tree_or_wood(cn.name) or is_snowlike(cn.name) or cn.name:find("leaves")) then
                if node_exists("air") then minetest.set_node(cp, {name = "air"}) end
              end
            end
          end
        elseif is_liquid_node(n.name) then
          -- avoid placing lava if liquids exist above bottom
          safe = false; break
        else
          -- any other solid node (player building, stone, etc.) blocks safe lava placement
          safe = false; break
        end
      end

      if not safe then goto continue end

      -- final check: ensure there's at least one contiguous air block above bottom so lava won't immediately cascade out
      local top_clear = false
      for h = 1, cfg.crater_lava_depth_check do
        local p = {x = bp.x, y = bp.y + h, z = bp.z}
        local n = minetest.get_node_or_nil(p)
        if n and n.name == "air" then top_clear = true; break end
      end
      if not top_clear then goto continue end

      -- finally set lava source
      minetest.set_node({x = bp.x, y = bp.y, z = bp.z}, {name = lava_name})
    end
    ::continue::
  end
end

-- Impact helper: damage entities around a point
local function damage_nearby(source_obj, impact_pos, radius, damage)
  local objs = minetest.get_objects_inside_radius(impact_pos, radius)
  for _, obj in ipairs(objs) do
    if obj and obj:get_luaentity() then
      local lname = obj:get_luaentity().name or ""
      if not lname:match("^" .. MOD .. ":meteor_") and obj.punch then
        obj:punch(source_obj, 1.0, {full_punch_interval = 1.0, damage_groups = {fleshy = damage}}, nil)
      end
    else
      if obj:is_player() then
        obj:punch(source_obj, 1.0, {full_punch_interval = 1.0, damage_groups = {fleshy = damage}}, nil)
      end
    end
  end
end

-- REGISTER ENTITIES
local function register_meteor_entity(size_name, spec)
  minetest.register_entity(MOD .. ":meteor_" .. size_name, {
    initial_properties = {
      physical = true,
      collisionbox = {
        -0.45 * spec.visual_scale, -0.45 * spec.visual_scale, -0.45 * spec.visual_scale,
         0.45 * spec.visual_scale,  0.45 * spec.visual_scale,  0.45 * spec.visual_scale
      },
      visual = "cube",
      visual_size = {x = spec.visual_scale, y = spec.visual_scale},
      textures = {spec.texture, spec.texture, spec.texture, spec.texture, spec.texture, spec.texture},
      pointable = false,
      glow = math.floor(6 + spec.visual_scale * 2),
    },

    scfg = spec,
    lifetime = cfg.cleanup_timeout,
    timer = 0,
    impacted = false,

    on_activate = function(self)
      if self.object then self.object:set_armor_groups({immortal = 1}) end
      self.lifetime = cfg.cleanup_timeout
    end,

    on_step = function(self, dtime)
      if not self.object then return end
      self.timer = self.timer + dtime
      self.lifetime = self.lifetime - dtime
      if self.lifetime <= 0 then self.object:remove(); return end

      -- enforce downward speed, apply gentle atmospheric drag to horizontals
      local vel = self.object:get_velocity() or {x = 0, y = -self.scfg.speed, z = 0}
      vel.x = vel.x * cfg.atmosphere_drag
      vel.z = vel.z * cfg.atmosphere_drag
      self.object:set_velocity({x = vel.x, y = -self.scfg.speed, z = vel.z})

      if self.timer > 0.12 then
        self.timer = 0
        local pos = self.object:get_pos()
        if pos then
          for i = 1, math.max(1, self.scfg.trail_particles) do
            minetest.add_particle({
              pos = {x = pos.x + (math.random() - 0.5) * 0.6, y = pos.y + (math.random() - 0.5) * 0.4, z = pos.z + (math.random() - 0.5) * 0.6},
              velocity = {x = (math.random() - 0.5) * 0.6, y = -1.6 + math.random() * 0.4, z = (math.random() - 0.5) * 0.6},
              acceleration = {x = 0, y = -6, z = 0},
              expirationtime = 0.6,
              size = 0.8 + math.random() * 1.3,
              collisiondetection = false,
              texture = cfg.default_trail_texture,
              glow = 5,
            })
          end
        end
      end

      local pos = self.object:get_pos()
      if not pos or self.impacted then return end

      -- sample a point slightly below the meteor and search downward for the nearest solid/walkable node
      local sample_pos = {x = pos.x, y = pos.y - 0.6 * self.scfg.visual_scale, z = pos.z}
      local sample_node = minetest.get_node_or_nil(sample_pos)
      if not sample_node or sample_node.name == "ignore" then return end

      -- attempt to find a walkable node below within a reasonable scan depth (use crater depth * 2 as heuristic)
      local scan_depth = math.max(4, self.scfg.crater_depth * 2)
      local solid_pos, solid_name = find_solid_below(sample_pos, scan_depth)

      if solid_pos then
        -- Impact at the solid position's top surface
        self.impacted = true
        local impact_pos = vector.round({x = solid_pos.x, y = solid_pos.y + 1, z = solid_pos.z})
        -- damage nearby entities using the meteor object position as source
        damage_nearby(self.object, impact_pos, self.scfg.impact_radius, self.scfg.damage)

        -- crater: center at impact_pos (which is top of solid), but use crater_depth from size
        local bottoms = make_crater(impact_pos, self.scfg.impact_radius, self.scfg.crater_depth)

        -- decide submerged state by checking node at impact_pos
        local node_at_impact = minetest.get_node_or_nil(impact_pos)
        local submerged = node_at_impact and is_liquid_node(node_at_impact.name)

        if submerged then
          -- underwater variant: bubbles, clear some water, no ignition
          minetest.add_particlespawner({
            amount = math.max(8, self.scfg.impact_radius * 6),
            time = 0.8,
            minpos = {x = impact_pos.x - 1, y = impact_pos.y - 1, z = impact_pos.z - 1},
            maxpos = {x = impact_pos.x + 1, y = impact_pos.y + 1, z = impact_pos.z + 1},
            minvel = {x = -2, y = -1, z = -2},
            maxvel = {x = 2, y = 3, z = 2},
            minacc = {x = 0, y = -3, z = 0},
            maxacc = {x = 0, y = -5, z = 0},
            minexptime = 0.5,
            maxexptime = 1.6,
            minsize = 1.2,
            maxsize = 3.2,
            collisiondetection = false,
            texture = cfg.default_trail_texture,
          })

          -- conservatively clear water above crater bottoms to simulate boil/air-pocket
          for _, b in ipairs(bottoms) do
            for h = 1, math.min(cfg.crater_lava_depth_check, 6) do
              local p = {x = b.x, y = b.y + h, z = b.z}
              local nn = minetest.get_node_or_nil(p)
              if nn and nn.name and nn.name ~= "ignore" and is_liquid_node(nn.name) then
                if node_exists("air") then minetest.set_node(p, {name = "air"}) end
              end
            end
          end

          maybe_fill_lava(bottoms, self.scfg.crater_depth)
        else
          -- above-water impact: ignite flammables, create debris, attempt lava fills under stricter rules
          ignite_area(impact_pos, self.scfg.impact_radius, self.scfg.debris_chance * 0.9)
          maybe_fill_lava(bottoms, self.scfg.crater_depth)

          -- impact particles (dust/fire)
          minetest.add_particlespawner({
            amount = math.max(12, self.scfg.impact_radius * 7),
            time = 0.55,
            minpos = {x = impact_pos.x - 1, y = impact_pos.y - 1, z = impact_pos.z - 1},
            maxpos = {x = impact_pos.x + 1, y = impact_pos.y + 1, z = impact_pos.z + 1},
            minvel = {x = -3, y = 2, z = -3},
            maxvel = {x = 3, y = 6, z = 3},
            minacc = {x = 0, y = -9, z = 0},
            maxacc = {x = 0, y = -12, z = 0},
            minexptime = 0.6,
            maxexptime = 1.2,
            minsize = 1.8,
            maxsize = 4.0,
            collisiondetection = false,
            texture = cfg.default_trail_texture,
            glow = 8,
          })

          -- sparse debris (use fully-qualified node names and check they exist)
          for dx = -2, 2 do for dz = -2, 2 do
            if math.random() < self.scfg.debris_chance then
              local p = {x = impact_pos.x + dx, y = impact_pos.y + 2, z = impact_pos.z + dz}
              local n = minetest.get_node_or_nil(p)
              if n and n.name and n.name ~= "ignore" and n.name ~= "air" then
                if math.random() < 0.56 then
                  if node_exists("air") then minetest.set_node(p, {name = "air"}) end
                  minetest.add_item(p, n.name)
                else
                  local rubble = math.random() < 0.5 and "default:cobble" or "default:gravel"
                  if node_exists(rubble) then minetest.set_node(p, {name = rubble}) end
                end
              end
            end
          end end

          if minetest.sound_play then minetest.sound_play(cfg.tnt_sound_name, {pos = impact_pos, gain = 1.1, max_hear_distance = 64}) end
        end

        if self.object then self.object:remove() end
      else
        -- no solid found within scan depth: keep falling
        -- handle passing through liquids or thin layers
        if is_liquid_node(sample_node.name) then
          minetest.add_particlespawner({
            amount = math.max(1, math.floor(self.scfg.visual_scale * 2)),
            time = 0.2,
            minpos = {x = pos.x - 0.3, y = pos.y - 0.5, z = pos.z - 0.3},
            maxpos = {x = pos.x + 0.3, y = pos.y, z = pos.z + 0.3},
            minvel = {x = -1, y = 1, z = -1},
            maxvel = {x = 1, y = 3, z = 1},
            minacc = {x = 0, y = -5, z = 0},
            maxacc = {x = 0, y = -6, z = 0},
            minexptime = 0.3,
            maxexptime = 0.7,
            minsize = 0.6,
            maxsize = 1.8,
            collisiondetection = false,
            texture = cfg.splash_particle,
            glow = 6,
          })
          local v = self.object:get_velocity()
          if v then self.object:set_velocity({x = v.x * cfg.water_drag, y = v.y, z = v.z * cfg.water_drag}) end
        else
          -- passing through leaves/snow layers: occasionally clear thin snow to avoid stuck meteors
          if is_snowlike(sample_node.name) and math.random() < 0.45 then
            if node_exists("air") then minetest.set_node(sample_pos, {name = "air"}) end
          end
          local v2 = self.object:get_velocity()
          if v2 then self.object:set_velocity({x = v2.x * 0.995, y = v2.y, z = v2.z * 0.995}) end
        end
      end
    end,
  })
end

-- register entities
for name, spec in pairs(SIZES) do register_meteor_entity(name, spec) end

-- SPAWN HELPERS
local function spawn_one_near(center_pos)
  tidy_entities()
  if #state.entities >= cfg.global_max_concurrent then return false end
  local ox = center_pos.x + (math.random() - 0.5) * 2 * cfg.spawn_radius
  local oz = center_pos.z + (math.random() - 0.5) * 2 * cfg.spawn_radius
  local oy = center_pos.y + cfg.spawn_height_min + math.random(0, math.max(0, cfg.spawn_height_max - cfg.spawn_height_min))
  local size_name, spec = choose_size()
  local spawnpos = {x = ox, y = oy, z = oz}
  if minetest.get_node_or_nil(spawnpos) == nil then return false end
  local ent = minetest.add_entity(spawnpos, MOD .. ":meteor_" .. size_name)
  if ent then table.insert(state.entities, ent); return true end
  return false
end

local function spawn_burst_around(player)
  if state.spawned_minute >= cfg.minute_spawn_cap then return end
  local ppos = player:get_pos()
  if not ppos then return end
  local count = math.random(cfg.burst_min, cfg.burst_max)
  for i = 1, count do
    if state.spawned_minute >= cfg.minute_spawn_cap then break end
    if #state.entities >= cfg.global_max_concurrent then break end
    local delay = math.random() * cfg.stagger_max
    local center_copy = vector.new(ppos)
    minetest.after(delay, function()
      if not state.running then return end
      if spawn_one_near(center_copy) then state.spawned_minute = state.spawned_minute + 1 end
    end)
  end
end

-- SCHEDULER
local function scheduler()
  if not state.running then return end
  tidy_entities()
  state.minute_timer = state.minute_timer + cfg.scheduler_interval
  if state.minute_timer >= 60 then state.minute_timer = state.minute_timer - 60; state.spawned_minute = 0 end
  local players = minetest.get_connected_players()
  if #players > 0 then
    for _, p in ipairs(players) do
      if math.random() < 0.56 then
        local near = 0
        local ppos = p:get_pos()
        for _, ent in ipairs(state.entities) do
          local pos = ent:get_pos()
          if pos and vector.distance(pos, ppos) < cfg.spawn_radius * 1.4 then near = near + 1 end
        end
        if near < cfg.per_player_max_nearby then spawn_burst_around(p) end
      end
    end
  end
  minetest.after(cfg.scheduler_interval, scheduler)
end

-- COMMANDS
minetest.register_chatcommand("meteors", {
  params = "<start|stop|status>",
  description = "Control meteor showers",
  func = function(name, param)
    local cmd = param:match("^%s*(%S+)%s*$")
    if not cmd then return false, "Usage: /meteors start | stop | status" end
    cmd = cmd:lower()
    if cmd == "start" then
      if state.running then return true, "Meteor showers already running." end
      state.running = true; state.spawned_minute = 0; state.minute_timer = 0
      minetest.after(0.6, scheduler)
      return true, "Meteor showers started."
    elseif cmd == "stop" then
      if not state.running then return true, "Meteor showers not running." end
      state.running = false
      for _, ent in ipairs(state.entities) do if ent and ent:get_luaentity() then ent:remove() end end
      state.entities = {}
      return true, "Meteor showers stopped and active meteors removed."
    elseif cmd == "status" then
      tidy_entities()
      local running = state.running and "running" or "stopped"
      return true, string.format("Meteors: %s. Active: %d. Spawned this minute: %d.", running, #state.entities, state.spawned_minute)
    else
      return false, "Unknown command. Use start, stop, or status."
    end
  end,
})

minetest.register_on_shutdown(function() state.running = false end)
