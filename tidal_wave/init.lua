-- tidal_wave/init.lua
-- Tidal Wave Mod for Minetest
-- Usage: /wave_spawn [x y z dir_x dir_y dir_z speed width length height]
-- If no arguments provided, sane defaults are used and the wave spawns in front of the player.

local modname = minetest.get_current_modname() or "tidal_wave"

-- Configuration (sane defaults; tune if desired)
local MAX_NODES_PER_STEP = 700        -- max nodes changed per tick per wave (performance cap)
local WAVE_STEP_INTERVAL = 0.12       -- seconds between wave updates
local PUSH_FACTOR = 1.6               -- impulse multiplier applied to entities
local DAMAGE_FACTOR = 0.22            -- damage per unit momentum
local MIN_NODE_MOMENTUM_TO_BREAK = 6  -- minimal impulse threshold to break a node
local WATER_NODE_NAME = "default:water_source"
local FLOWING_WATER = "default:water_flowing"

-- Default wave parameters used when user types /wave_spawn with no args
local DEFAULT_SPEED = 20    -- nodes per second
local DEFAULT_WIDTH = 10    -- radius in nodes
local DEFAULT_LENGTH = 180  -- how far the wave front will travel before dissipating
local DEFAULT_HEIGHT = 6    -- vertical half-thickness (above and below center)
local DEFAULT_LIFETIME = 30 -- fallback lifetime in seconds

-- Material strength table (higher = harder to break)
local MATERIAL_STRENGTH = {
  fleshy = 1,
  choppy = 6,
  crumbly = 8,
  cracky = 22,
  level = 120,
}

local function node_strength(nodename)
  local def = minetest.registered_nodes[nodename]
  if not def then return 50 end
  local groups = def.groups or {}
  local best = 50
  for g,v in pairs(groups) do
    if MATERIAL_STRENGTH[g] then
      local val = MATERIAL_STRENGTH[g] * (1 / math.max(1, v))
      if val < best then best = val end
    end
  end
  return best
end

local function node_mass(nodename)
  local def = minetest.registered_nodes[nodename]
  if not def then return 5 end
  local groups = def.groups or {}
  local mass = 5
  if groups.wood or groups.choppy then mass = 18 end
  if groups.cracky then mass = 35 end
  if groups.fleshy then mass = 3 end
  if groups.snappy then mass = 6 end
  return mass
end

-- Wave class
local Wave = {}
Wave.__index = Wave

function Wave.new(pos, dir, speed, width, length, height, owner)
  local self = setmetatable({}, Wave)
  self.pos = vector.new(pos)
  self.dir = vector.normalize(dir)
  if self.dir.x == 0 and self.dir.y == 0 and self.dir.z == 0 then
    self.dir = {x=1, y=0, z=0}
  end
  self.speed = speed or DEFAULT_SPEED
  self.width = width or DEFAULT_WIDTH
  self.length = length or DEFAULT_LENGTH
  self.height = height or DEFAULT_HEIGHT
  self.travelled = 0
  self.alive = true
  self.accum = 0
  self.owner = owner
  self.front_center = vector.new(pos)
  self.spawn_time = minetest.get_us_time() / 1e6
  -- Light visual particle at origin for feedback if texture exists
  minetest.add_particle({
    pos = vector.add(self.pos, {x=0,y=0,z=0}),
    velocity = {x=0,y=0,z=0},
    expirationtime = 1.2,
    size = 6,
    collisiondetection = false,
    glow = 6,
    texture = "default_water.png"
  })
  return self
end

local function wave_momentum(wave)
  local density = 1000
  local volume = (2 * wave.width + 1) * (2 * wave.height + 1) * 1
  local vel = wave.speed
  local momentum = (density * volume * vel) / 2200
  return momentum
end

function Wave:sweep_and_apply()
  local center = self.front_center
  local dir = self.dir
  local width = self.width
  local height = self.height
  local nodes_changed = 0
  local momentum = wave_momentum(self)
  local minp = {
    x = math.floor(center.x - width - 1),
    y = math.floor(center.y - height - 1),
    z = math.floor(center.z - width - 1),
  }
  local maxp = {
    x = math.ceil(center.x + width + 1),
    y = math.ceil(center.y + height + 1),
    z = math.ceil(center.z + width + 1),
  }

  for x = minp.x, maxp.x do
    if nodes_changed > MAX_NODES_PER_STEP then break end
    for z = minp.z, maxp.z do
      if nodes_changed > MAX_NODES_PER_STEP then break end
      for y = minp.y, maxp.y do
        if nodes_changed > MAX_NODES_PER_STEP then break end
        local dx = x + 0.5 - center.x
        local dz = z + 0.5 - center.z
        local dy = y + 0.5 - center.y
        local r = math.sqrt(dx*dx + dz*dz)
        if r <= width and math.abs(dy) <= height then
          local pos = {x=x,y=y,z=z}
          local n = minetest.get_node(pos)
          local nodename = n.name
          if nodename ~= "air" and nodename ~= WATER_NODE_NAME and nodename ~= FLOWING_WATER then
            local mass = node_mass(nodename)
            local strength = node_strength(nodename)
            local local_momentum = momentum * (1 - (r/width))
            local effective_impulse = local_momentum / math.max(1, mass)
            if effective_impulse >= MIN_NODE_MOMENTUM_TO_BREAK and effective_impulse >= strength/10 then
              local drops = minetest.get_node_drops(nodename, "")
              for _, item in ipairs(drops) do
                minetest.add_item(vector.add(pos, {x=0.5,y=0.5,z=0.5}), item)
              end
              minetest.set_node(pos, {name = FLOWING_WATER})
              nodes_changed = nodes_changed + 1
            else
              if effective_impulse >= strength/20 and math.random() < 0.09 then
                minetest.set_node(pos, {name = FLOWING_WATER})
                nodes_changed = nodes_changed + 1
              end
            end
          elseif nodename == WATER_NODE_NAME or nodename == FLOWING_WATER then
            minetest.set_node(pos, {name = FLOWING_WATER})
          end
        end
      end
    end
  end

  local objs = minetest.get_objects_inside_radius(center, width + 2)
  for _, obj in ipairs(objs) do
    if nodes_changed > MAX_NODES_PER_STEP then break end
    if not obj then goto continue end
    local objpos = obj:get_pos()
    if not objpos then goto continue end
    local rel = vector.subtract(objpos, center)
    local flat_rel = {x = rel.x, y = 0, z = rel.z}
    local dist = math.sqrt(flat_rel.x*flat_rel.x + flat_rel.z*flat_rel.z)
    if dist <= width + 2 then
      local push_dir = vector.normalize(vector.add(flat_rel, vector.multiply(dir, 0.25)))
      if push_dir.x == 0 and push_dir.z == 0 then push_dir = {x=dir.x, y=0, z=dir.z} end
      local entity_mass = 80
      if not obj:is_player() then
        local ent = obj:get_luaentity()
        if ent and ent.mass then entity_mass = ent.mass end
        if not ent then entity_mass = 20 end
      end
      local force = (momentum / math.max(1, entity_mass)) * PUSH_FACTOR * (1 - (dist / (width + 2)))
      local curvel = obj:get_velocity() or {x=0,y=0,z=0}
      local newvel = vector.add(curvel, vector.multiply(push_dir, force))
      newvel.y = math.max(newvel.y or 0, 3 * (1 - (dist/(width+2))))
      obj:set_velocity(newvel)
      local damage = math.floor((momentum / math.max(1, entity_mass)) * DAMAGE_FACTOR)
      if damage > 0 and obj:is_player() then
        obj:set_hp(math.max(0, obj:get_hp() - damage))
      elseif damage > 0 then
        local ent = obj:get_luaentity()
        if ent and ent.get_hp and ent.set_hp then
          ent:set_hp(math.max(0, ent:get_hp() - damage))
        end
      end
      nodes_changed = nodes_changed + 1
    end
    ::continue::
  end
end

function Wave:step(dt)
  if not self.alive then return end
  self.accum = self.accum + dt
  if self.accum < WAVE_STEP_INTERVAL then return end
  local steps = math.floor(self.accum / WAVE_STEP_INTERVAL)
  self.accum = self.accum - steps * WAVE_STEP_INTERVAL
  for i=1,steps do
    local move = vector.multiply(self.dir, self.speed * WAVE_STEP_INTERVAL)
    self.front_center = vector.add(self.front_center, move)
    self.travelled = self.travelled + vector.length(move)
    self:sweep_and_apply()
    -- spawn a short-lived particle band along the front for feedback
    minetest.add_particle({
      pos = vector.add(self.front_center, {x=0,y=0,z=0}),
      velocity = vector.multiply(self.dir, 0.4),
      expirationtime = 0.9,
      size = math.max(3, math.min(8, self.width / 2)),
      collisiondetection = false,
      texture = "default_water.png"
    })
    if self.travelled >= self.length then
      self.alive = false
      break
    end
    -- safety lifetime fallback
    if (minetest.get_us_time() / 1e6) - self.spawn_time > DEFAULT_LIFETIME + (self.length / math.max(1,self.speed)) then
      self.alive = false
      break
    end
  end
end

-- Wave manager
local active_waves = {}

minetest.register_globalstep(function(dtime)
  if #active_waves == 0 then return end
  for i = #active_waves, 1, -1 do
    local w = active_waves[i]
    if w and w.alive then
      w:step(dtime)
    else
      table.remove(active_waves, i)
    end
  end
end)

-- Helper to find default spawn position and direction when player types no args
local function default_spawn_for_player(player)
  local pos = player:get_pos()
  local dir = player:get_look_dir()
  local spawn_pos = vector.add(pos, vector.multiply(dir, 6))
  spawn_pos.y = spawn_pos.y - 1 -- start near ground level
  return spawn_pos, {x=dir.x, y=0, z=dir.z}
end

-- Chatcommand to spawn wave
minetest.register_chatcommand("wave_spawn", {
  params = "[x y z dir_x dir_y dir_z speed width length height]",
  description = "Spawn a tidal wave. No args uses sensible defaults in front of player.",
  func = function(name, param)
    local player = minetest.get_player_by_name(name)
    local args = {}
    for token in string.gmatch(param, "%S+") do table.insert(args, token) end

    local pos, dir, speed, width, length, height
    if #args >= 3 then
      pos = {x=tonumber(args[1]) or 0, y=tonumber(args[2]) or 5, z=tonumber(args[3]) or 0}
    elseif player then
      pos, dir = default_spawn_for_player(player)
    else
      -- fallback world origin if no player (server console)
      pos = {x=0,y=5,z=0}
    end

    if not dir then
      if #args >= 6 then
        dir = {x=tonumber(args[4]) or 1, y=tonumber(args[5]) or 0, z=tonumber(args[6]) or 0}
      elseif player then
        local look = player:get_look_dir()
        dir = {x=look.x, y=0, z=look.z}
      else
        dir = {x=1,y=0,z=0}
      end
    end

    if #args >= 7 then speed = tonumber(args[7]) or DEFAULT_SPEED else speed = DEFAULT_SPEED end
    if #args >= 8 then width = tonumber(args[8]) or DEFAULT_WIDTH else width = DEFAULT_WIDTH end
    if #args >= 9 then length = tonumber(args[9]) or DEFAULT_LENGTH else length = DEFAULT_LENGTH end
    if #args >= 10 then height = tonumber(args[10]) or DEFAULT_HEIGHT else height = DEFAULT_HEIGHT end

    -- normalize direction and ensure non-zero horizontal component
    dir = vector.normalize(dir)
    if dir.x == 0 and dir.z == 0 then dir = {x=1,y=0,z=0} end
    local spawn_pos = vector.add(pos, {x=0,y=0,z=0})

    local wave = Wave.new(spawn_pos, dir, speed, width, length, height, name)
    table.insert(active_waves, wave)
    minetest.chat_send_player(name, "Tidal wave spawned with speed=" .. speed .. " width=" .. width .. " length=" .. length .. ".")
    return true
  end,
})

-- Convenience: alias /wave for /wave_spawn
minetest.register_chatcommand("wave", {
  params = "",
  description = "Alias for /wave_spawn",
  func = function(name, param) return minetest.registered_chatcommands["wave_spawn"].func(name, param) end,
})

-- Simple admin-only /wave_stop to clear active waves
minetest.register_chatcommand("wave_stop", {
  params = "",
  description = "Stop and remove all active tidal waves (server only).",
  privs = {server=true},
  func = function(name, param)
    active_waves = {}
    return true, "All tidal waves stopped."
  end,
})
