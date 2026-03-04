-- builder_bot/init.lua
-- Minetest Builder Bot
-- - Uses any two blocks a player places as region endpoints
-- - Any player with interact priv can control their own bot
-- - Bot walks (smooth interpolation) and places nodes slowly with visible animation
-- - Markers are recorded when a player places two blocks as endpoints
-- - Alerts the player when nodes are unsupported/unplaceable
-- - Bot is removed when its owner leaves the server (periodic cleanup)
-- - Nametag set to "[Builder] <name>" at spawn time
-- - Users cannot spawn more than one bot
-- - Creative build commands: .tree, .house (faster), .pool

local modname = "builder_bot"
local datadir = minetest.get_worldpath() .. "/" .. modname .. "_data"

local function ensure_datadir()
    minetest.mkdir(datadir)
end
ensure_datadir()

-- ========== Utilities ==========

local function minmax(a,b) if a>b then return b,a else return a,b end end

local function bounds_from_two_points(p1, p2)
    local minx,maxx = minmax(p1.x,p2.x)
    local miny,maxy = minmax(p1.y,p2.y)
    local minz,maxz = minmax(p1.z,p2.z)
    return {x=minx,y=miny,z=minz},{x=maxx,y=maxy,z=maxz}
end

local function bresenham_line(p1, p2)
    local points = {}
    local x1,y1,z1 = p1.x,p1.y,p1.z
    local x2,y2,z2 = p2.x,p2.y,p2.z
    local dx = math.abs(x2-x1); local sx = x1 < x2 and 1 or -1
    local dy = math.abs(y2-y1); local sy = y1 < y2 and 1 or -1
    local dz = math.abs(z2-z1); local sz = z1 < z2 and 1 or -1
    local ax = 2*dx; local ay = 2*dy; local az = 2*dz
    if dx>=dy and dx>=dz then
        local yd = ay - dx; local zd = az - dx
        while true do
            points[#points+1] = {x=x1,y=y1,z=z1}
            if x1==x2 and y1==y2 and z1==z2 then break end
            if yd >= 0 then y1 = y1 + sy; yd = yd - ax end
            if zd >= 0 then z1 = z1 + sz; zd = zd - ax end
            x1 = x1 + sx; yd = yd + ay; zd = zd + az
        end
    elseif dy>=dx and dy>=dz then
        local xd = ax - dy; local zd = az - dy
        while true do
            points[#points+1] = {x=x1,y=y1,z=z1}
            if x1==x2 and y1==y2 and z1==z2 then break end
            if xd >= 0 then x1 = x1 + sx; xd = xd - ay end
            if zd >= 0 then z1 = z1 + sz; zd = zd - ay end
            y1 = y1 + sy; xd = xd + ax; zd = zd + az
        end
    else
        local xd = ax - dz; local yd = ay - dz
        while true do
            points[#points+1] = {x=x1,y=y1,z=z1}
            if x1==x2 and y1==y2 and z1==z2 then break end
            if xd >= 0 then x1 = x1 + sx; xd = xd - az end
            if yd >= 0 then y1 = y1 + sy; yd = yd - az end
            z1 = z1 + sz; xd = xd + ax; yd = yd + ay
        end
    end
    return points
end

local function iter_cuboid(minp, maxp, hollow)
    local coords = {}
    for z = minp.z, maxp.z do
        for y = minp.y, maxp.y do
            for x = minp.x, maxp.x do
                if not hollow
                or x == minp.x or x == maxp.x
                or y == minp.y or y == maxp.y
                or z == minp.z or z == maxp.z then
                    coords[#coords+1] = {x=x,y=y,z=z}
                end
            end
        end
    end
    return coords
end

-- Data I/O (node names only; no metadata)
local function save_region(minp, maxp, filename)
    local fh = io.open(datadir.."/"..filename..".bdat", "wb")
    if not fh then return false, "cannot open file" end
    local dx = maxp.x - minp.x + 1
    local dy = maxp.y - minp.y + 1
    local dz = maxp.z - minp.z + 1
    fh:write(string.format("%d %d %d\n", dx, dy, dz))
    for z = minp.z, maxp.z do
        for y = minp.y, maxp.y do
            for x = minp.x, maxp.x do
                local node = minetest.get_node_or_nil({x=x,y=y,z=z}) or {name="air"}
                fh:write(node.name .. "\n")
            end
        end
    end
    fh:close()
    return true
end

local function load_region_file(filename)
    local fh = io.open(datadir.."/"..filename..".bdat","rb")
    if not fh then return nil, "file not found" end
    local header = fh:read("*l")
    if not header then fh:close(); return nil,"invalid file" end
    local dx,dy,dz = header:match("^(%d+)%s+(%d+)%s+(%d+)")
    dx,dy,dz = tonumber(dx), tonumber(dy), tonumber(dz)
    if not dx then fh:close(); return nil,"bad header" end
    local nodes = {}
    for i=1,dx*dy*dz do
        local line = fh:read("*l")
        if not line then fh:close(); return nil,"unexpected eof" end
        nodes[#nodes+1] = line
    end
    fh:close()
    return {dx=dx, dy=dy, dz=dz, nodes=nodes}
end

-- Progress feedback with ETA
local function progress_update(job, playername, force)
    local now = os.time()
    if job.total and job.processed then
        if not job.start_time then job.start_time = now end
        local elapsed = now - job.start_time
        if elapsed <= 0 then elapsed = 1 end
        local rate = job.processed / elapsed
        local remaining = job.total - job.processed
        local eta = remaining / (rate > 0 and rate or 1)
        if force or (now - (job.last_update or 0) >= 3) then
            job.last_update = now
            local percent = math.floor((job.processed / job.total) * 100)
            minetest.chat_send_player(playername, "Builder Bot progress: "..percent.."% ("..job.processed.." / "..job.total..") ETA "..math.floor(eta).."s")
        end
    end
end

-- ========== Marker tracking (use any two placed blocks) ==========

local player_markers = {} -- playername -> {pos1=pos, pos2=pos, node1=name, node2=name}

local function set_marker_from_placement(player, pos, node_name)
    local name = player:get_player_name()
    player_markers[name] = player_markers[name] or {}
    local mk = player_markers[name]
    if not mk.pos1 then
        mk.pos1 = vector.new(pos)
        mk.node1 = node_name
        minetest.chat_send_player(name, "Builder Bot: marker 1 set at "..minetest.pos_to_string(pos).." using "..node_name)
    elseif not mk.pos2 then
        mk.pos2 = vector.new(pos)
        mk.node2 = node_name
        minetest.chat_send_player(name, "Builder Bot: marker 2 set at "..minetest.pos_to_string(pos).." using "..node_name)
        minetest.chat_send_player(name, "Builder Bot: region ready between marker 1 and marker 2")
    else
        mk.pos1 = mk.pos2
        mk.node1 = mk.node2
        mk.pos2 = vector.new(pos)
        mk.node2 = node_name
        minetest.chat_send_player(name, "Builder Bot: marker 1 moved to previous marker 2; marker 2 set at "..minetest.pos_to_string(pos).." using "..node_name)
    end
end

minetest.register_on_placenode(function(pos, newnode, placer, oldnode, itemstack, pointed_thing)
    if not placer or not newnode then return end
    local name = placer:get_player_name()
    local privs = minetest.get_player_privs(name)
    if not privs or not privs.interact then return end
    set_marker_from_placement(placer, pos, newnode.name)
end)

local function clear_markers_for(name, announce)
    player_markers[name] = nil
    if announce then
        minetest.chat_send_player(name, "Builder Bot: markers cleared")
    end
end

-- ========== Placement validation ==========

local function is_unplaceable_node(node_name)
    if not node_name then return true end
    if not minetest.registered_nodes[node_name] then
        return true
    end
    if node_name:match("bucket") then return true end
    if node_name:match("lava") then return true end
    if node_name:match("flowing") then return true end
    return false
end

-- ========== Bot entity (walking, non-colliding, animated) ==========

local bots = {} -- ownername -> luaentity

local function find_bot_for_owner(name)
    return bots[name]
end

local function spawn_bot(name, pos, owner)
    -- prevent spawning if owner already has a bot
    if bots[owner] then
        return nil, "owner already has a bot"
    end

    local obj = minetest.add_entity(pos, modname..":bot")
    if not obj then return nil, "failed" end
    local lua = obj:get_luaentity()
    lua.owner = owner
    lua.botname = name
    bots[owner] = lua

    -- set nametag now that owner and botname exist
    local display_name = "[Builder] " .. name
    obj:set_properties({
        nametag = display_name,
        nametag_color = "#FFFF00",
    })

    minetest.chat_send_player(owner, "Builder Bot '"..name.."' spawned at "..minetest.pos_to_string(pos))
    return lua
end

minetest.register_entity(modname..":bot", {
    initial_properties = {
        physical = false, -- no physics; walking simulated via interpolation
        collisionbox = {0,0,0, 0,0,0}, -- no collision
        visual = "mesh",
        mesh = "character.b3d",
        textures = {"character.png"},
        visual_size = {x=1,y=1},
        static_save = false, -- don't persist across server restarts
    },
    on_activate = function(self)
        self.object:set_armor_groups({immortal=1})
        self.state = {
            queue = nil,
            total = 0,
            processed = 0,
            start_time = 0,
            last_update = 0,
            working = false,
            batch = 1,            -- place one node per arrival for realistic building
            walk_speed = 4.5,     -- nodes per second (slightly faster)
            current_target = nil,
            interp_t = 0,
            last_pos = nil,
            original_walk_speed = nil,
        }
        -- idle animation
        self.object:set_animation({x=0, y=79}, 30, 0, true)
        self.state.last_pos = vector.new(self.object:get_pos())
    end,

    _pop_next_pos = function(self)
        if not self.state.queue or #self.state.queue == 0 then return nil end
        return self.state.queue[1]
    end,

    on_step = function(self, dtime)
        local st = self.state
        if not st.working or not st.queue or #st.queue == 0 then
            if st.working and (#st.queue == 0) then
                st.working = false
                -- restore original walk speed if it was changed
                if st.original_walk_speed then
                    st.walk_speed = st.original_walk_speed
                    st.original_walk_speed = nil
                end
                self.object:set_animation({x=0, y=79}, 30, 0, true)
                if self.owner then
                    minetest.chat_send_player(self.owner, "Builder Bot: task finished ("..st.processed.." / "..st.total..")")
                    clear_markers_for(self.owner, false)
                end
            end
            return
        end

        if not st.current_target then
            local next_item = self:_pop_next_pos()
            if next_item then
                st.current_target = next_item
                st.interp_t = 0
                st.last_pos = vector.new(self.object:get_pos())
            end
        end

        if st.current_target then
            local target_pos = st.current_target.pos
            local last = st.last_pos or vector.new(self.object:get_pos())
            local dist = vector.distance(last, target_pos)
            if dist < 0.01 then
                st.interp_t = 1
            else
                local travel = st.walk_speed * dtime
                local tstep = (dist > 0) and (travel / dist) or 1
                st.interp_t = st.interp_t + tstep
                if st.interp_t > 1 then st.interp_t = 1 end
                local ipos = {
                    x = last.x + (target_pos.x - last.x) * st.interp_t,
                    y = last.y + (target_pos.y - last.y) * st.interp_t,
                    z = last.z + (target_pos.z - last.z) * st.interp_t,
                }
                self.object:set_pos(ipos)
            end

            -- walking animation while moving
            self.object:set_animation({x=168, y=187}, 20, 0, true)

            if st.interp_t >= 1 then
                local item = st.current_target
                if item.action == "place" then
                    if is_unplaceable_node(item.node) then
                        if self.owner then
                            minetest.chat_send_player(self.owner, "Builder Bot: skipped unsupported node "..tostring(item.node).." at "..minetest.pos_to_string(item.pos))
                        end
                    else
                        minetest.set_node(item.pos, {name=item.node})
                    end
                elseif item.action == "erase" then
                    if not item.filter then
                        minetest.set_node(item.pos, {name="air"})
                    else
                        local n = minetest.get_node_or_nil(item.pos) or {name="air"}
                        if n.name == item.filter then
                            minetest.set_node(item.pos, {name="air"})
                        end
                    end
                end

                table.remove(st.queue, 1)
                st.processed = st.processed + 1
                st.current_target = nil
                st.interp_t = 0
                st.last_pos = vector.new(self.object:get_pos())
                progress_update(st, self.owner)
            end
        end
    end,
})

-- bot_set_task now accepts an optional opts table:
-- opts.walk_speed -> temporarily sets walk_speed for this job (restored when job finishes)
local function bot_set_task(bot, queue, owner, opts)
    local st = bot.state
    st.queue = queue
    st.total = queue and #queue or 0
    st.processed = 0
    st.start_time = os.time()
    st.last_update = 0
    st.working = (queue and #queue > 0)
    st.current_target = nil
    st.interp_t = 0
    st.last_pos = vector.new(bot.object:get_pos())
    if opts and opts.walk_speed then
        -- save original and set new speed
        if not st.original_walk_speed then st.original_walk_speed = st.walk_speed end
        st.walk_speed = opts.walk_speed
    end
    if st.working then
        bot.object:set_animation({x=168, y=187}, 20, 0, true)
    end
end

local function bot_abort(bot)
    if not bot or not bot.state then return end
    bot.state.queue = {}
    bot.state.total = 0
    bot.state.processed = 0
    bot.state.working = false
    bot.state.current_target = nil
    -- restore original walk speed if necessary
    if bot.state.original_walk_speed then
        bot.state.walk_speed = bot.state.original_walk_speed
        bot.state.original_walk_speed = nil
    end
    bot.object:set_animation({x=0, y=79}, 30, 0, true)
end

-- ========== Commands and workflow ==========

minetest.register_chatcommand("botspawn", {
    params = "<botname>",
    description = "Spawn a builder bot at your position",
    privs = {interact=true},
    func = function(name, param)
        if not param or param == "" then return false, "specify bot name" end
        local player = minetest.get_player_by_name(name)
        if not player then return false, "player not found" end
        if find_bot_for_owner(name) then return false, "You already have a bot. Use .goaway to remove it." end
        local pos = vector.add(player:get_pos(), {x=0,y=1,z=0})
        local ok, err = spawn_bot(param, pos, name)
        if not ok and err then
            return false, tostring(err)
        end
        return true, "Bot spawned"
    end
})

minetest.register_on_chat_message(function(name, message)
    if not message:match("^%.") then return end

    local privs = minetest.get_player_privs(name)
    if not privs or not privs.interact then
        minetest.chat_send_player(name, "You require the interact privilege to control the builder bot")
        return true
    end

    local args = {}
    for word in message:gmatch("%S+") do args[#args+1]=word end
    local cmd = args[1]:sub(2):lower()
    local bot = find_bot_for_owner(name)
    if not bot and cmd ~= "goaway" then
        minetest.chat_send_player(name, "No bot found; spawn one with /botspawn <name>")
        return true
    end

    if cmd == "abort" then
        if bot then bot_abort(bot) end
        minetest.chat_send_player(name, "Builder Bot: job aborted")
        return true
    end

    if cmd == "goaway" then
        local mybot = find_bot_for_owner(name)
        if not mybot then minetest.chat_send_player(name, "You have no bot to remove"); return true end
        if mybot.object then mybot.object:remove() end
        bots[name] = nil
        minetest.chat_send_player(name, "Builder Bot removed")
        return true
    end

    if cmd == "reset" then
        if bot then bot_abort(bot) end
        clear_markers_for(name, true)
        return true
    end

    local mk = player_markers[name]
    if not mk or not mk.pos1 or not mk.pos2 then
        minetest.chat_send_player(name, "Place two blocks (any block) to mark the region endpoints")
        return true
    end
    local p1, p2 = mk.pos1, mk.pos2

    -- Helper to validate and warn about unplaceable nodes in a queue
    local function validate_and_filter_queue(queue)
        local bad_names = {}
        local filtered = {}
        for i=1,#queue do
            local item = queue[i]
            if item.action == "place" then
                if is_unplaceable_node(item.node) then
                    bad_names[item.node] = true
                else
                    filtered[#filtered+1] = item
                end
            else
                filtered[#filtered+1] = item
            end
        end
        if next(bad_names) then
            local bad_list = {}
            for n,_ in pairs(bad_names) do bad_list[#bad_list+1] = n end
            minetest.chat_send_player(name, "Builder Bot: skipped unsupported nodes: "..table.concat(bad_list, ", "))
        end
        return filtered
    end

    -- drawline <nodename>
    if cmd == "drawline" then
        local nodename = args[2] or mk.node1 or "default:stone"
        local pts = bresenham_line(p1, p2)
        local queue = {}
        for i=1,#pts do
            queue[#queue+1] = {pos=pts[i], action="place", node=nodename}
        end
        queue = validate_and_filter_queue(queue)
        bot_set_task(bot, queue, name)
        return true
    end

    -- cuboid <nodename> [hollow]
    if cmd == "cuboid" then
        local nodename = args[2] or mk.node1 or "default:stone"
        local hollow = args[3] == "hollow"
        local minp, maxp = bounds_from_two_points(p1, p2)
        local coords = iter_cuboid(minp, maxp, hollow)
        local queue = {}
        for i=1,#coords do
            queue[#queue+1] = {pos=coords[i], action="place", node=nodename}
        end
        queue = validate_and_filter_queue(queue)
        bot_set_task(bot, queue, name)
        return true
    end

    -- erase [nodename]
    if cmd == "erase" then
        local filter = args[2]
        local minp, maxp = bounds_from_two_points(p1, p2)
        local coords = iter_cuboid(minp, maxp, false)
        local queue = {}
        for i=1,#coords do
            queue[#queue+1] = {pos=coords[i], action="erase", filter=filter}
        end
        bot_set_task(bot, queue, name)
        return true
    end

    -- copy <name>
    if cmd == "copy" then
        local fname = args[2]
        if not fname then minetest.chat_send_player(name,"Usage: .copy <name>"); return true end
        local minp, maxp = bounds_from_two_points(p1, p2)
        local ok, err = save_region(minp, maxp, fname)
        if not ok then
            minetest.chat_send_player(name, "Copy failed: "..tostring(err))
        else
            minetest.chat_send_player(name, "Copy saved: "..fname)
            clear_markers_for(name, false)
        end
        return true
    end

    -- paste <name> (origin = marker 1)
    if cmd == "paste" then
        local fname = args[2]
        if not fname then minetest.chat_send_player(name,"Usage: .paste <name>"); return true end
        local data, err = load_region_file(fname)
        if not data then minetest.chat_send_player(name,"Load failed: "..tostring(err)); return true end
        local origin = {x=p1.x, y=p1.y, z=p1.z}
        local queue = {}
        for idx=1,#data.nodes do
            local local_idx = idx-1
            local lx = (local_idx % data.dx)
            local ly = (math.floor(local_idx / data.dx) % data.dy)
            local lz = math.floor(local_idx / (data.dx*data.dy))
            local worldpos = {x=origin.x + lx, y=origin.y + ly, z=origin.z + lz}
            queue[#queue+1] = {pos=worldpos, action="place", node=data.nodes[idx]}
        end
        queue = validate_and_filter_queue(queue)
        bot_set_task(bot, queue, name)
        return true
    end

    -- backup <name>
    if cmd == "backup" then
        local fname = args[2]
        if not fname then minetest.chat_send_player(name,"Usage: .backup <name>"); return true end
        local minp, maxp = bounds_from_two_points(p1, p2)
        local ok, err = save_region(minp, maxp, "backup_"..fname)
        if not ok then
            minetest.chat_send_player(name, "Backup failed: "..tostring(err))
        else
            minetest.chat_send_player(name, "Backup saved: "..fname)
            clear_markers_for(name, false)
        end
        return true
    end

    -- restore <name> (origin = marker 1)
    if cmd == "restore" then
        local fname = args[2]
        if not fname then minetest.chat_send_player(name,"Usage: .restore <name>"); return true end
        local data, err = load_region_file("backup_"..fname)
        if not data then minetest.chat_send_player(name,"Load failed: "..tostring(err)); return true end
        local origin = {x=p1.x, y=p1.y, z=p1.z}
        local queue = {}
        for idx=1,#data.nodes do
            local local_idx = idx-1
            local lx = (local_idx % data.dx)
            local ly = (math.floor(local_idx / data.dx) % data.dy)
            local lz = math.floor(local_idx / (data.dx*data.dy))
            local worldpos = {x=origin.x + lx, y=origin.y + ly, z=origin.z + lz}
            queue[#queue+1] = {pos=worldpos, action="place", node=data.nodes[idx]}
        end
        queue = validate_and_filter_queue(queue)
        bot_set_task(bot, queue, name)
        return true
    end

    ----------------------------------------------------------------
    -- Creative builds: .tree, .house (faster), .pool
    ----------------------------------------------------------------

    -- .tree [trunk_node] [leaf_node]
    if cmd == "tree" then
        local trunk = args[2] or "default:tree"
        local leaves = args[3] or "default:leaves"
        local height = math.max(4, math.abs(p2.y - p1.y))
        local radius = math.max(2, math.floor(height / 3))
        local base = {x=p1.x, y=p1.y, z=p1.z}
        local top_y = base.y + height - 1
        local queue = {}
        for y=base.y, top_y do
            queue[#queue+1] = {pos={x=base.x, y=y, z=base.z}, action="place", node=trunk}
        end
        for dy=-radius, radius do
            local layer_y = top_y + dy
            local layer_r = radius - math.floor(math.abs(dy) / 2)
            for dx=-layer_r, layer_r do
                for dz=-layer_r, layer_r do
                    if (dx*dx + dz*dz) <= (layer_r*layer_r) then
                        local pos = {x=base.x + dx, y=layer_y, z=base.z + dz}
                        queue[#queue+1] = {pos=pos, action="place", node=leaves}
                    end
                end
            end
        end
        queue = validate_and_filter_queue(queue)
        bot_set_task(bot, queue, name)
        return true
    end

    -- .house [wall_node] [roof_node] [floor_node]
    -- Build house faster by temporarily increasing walk speed for this job
    if cmd == "house" then
        local wall = args[2] or "default:cobble"
        local roof = args[3] or "default:wood"
        local floor = args[4] or "default:stone"
        local minp, maxp = bounds_from_two_points(p1, p2)
        local queue = {}
        local width = maxp.x - minp.x + 1
        local length = maxp.z - minp.z + 1
        local height = maxp.y - minp.y + 1
        if width < 3 or length < 3 or height < 3 then
            minetest.chat_send_player(name, "House area too small (min 3x3x3).")
            return true
        end

        -- floor
        for x=minp.x, maxp.x do
            for z=minp.z, maxp.z do
                queue[#queue+1] = {pos={x=x,y=minp.y,z=z}, action="place", node=floor}
            end
        end

        -- walls (perimeter, from minp.y+1 to maxp.y-1)
        for y=minp.y+1, maxp.y-1 do
            for x=minp.x, maxp.x do
                queue[#queue+1] = {pos={x=x,y=y,z=minp.z}, action="place", node=wall}
                queue[#queue+1] = {pos={x=x,y=y,z=maxp.z}, action="place", node=wall}
            end
            for z=minp.z+1, maxp.z-1 do
                queue[#queue+1] = {pos={x=minp.x,y=y,z=z}, action="place", node=wall}
                queue[#queue+1] = {pos={x=maxp.x,y=y,z=z}, action="place", node=wall}
            end
        end

        -- roof (top layer)
        for x=minp.x, maxp.x do
            for z=minp.z, maxp.z do
                queue[#queue+1] = {pos={x=x,y=maxp.y,z=z}, action="place", node=roof}
            end
        end

        -- door opening: center on minz wall, 2 blocks tall
        local door_x = math.floor((minp.x + maxp.x) / 2)
        for y=minp.y+1, math.min(minp.y+2, maxp.y-1) do
            queue[#queue+1] = {pos={x=door_x, y=y, z=minp.z}, action="place", node="air"}
        end

        -- windows: small openings on other walls if height allows
        if height >= 4 then
            local wy = minp.y + 2
            queue[#queue+1] = {pos={x=door_x-1, y=wy, z=maxp.z}, action="place", node="air"}
            queue[#queue+1] = {pos={x=door_x+1, y=wy, z=maxp.z}, action="place", node="air"}
            local wz = math.floor((minp.z + maxp.z) / 2)
            queue[#queue+1] = {pos={x=minp.x, y=wy, z=wz-1}, action="place", node="air"}
            queue[#queue+1] = {pos={x=minp.x, y=wy, z=wz+1}, action="place", node="air"}
            queue[#queue+1] = {pos={x=maxp.x, y=wy, z=wz-1}, action="place", node="air"}
            queue[#queue+1] = {pos={x=maxp.x, y=wy, z=wz+1}, action="place", node="air"}
        end

        queue = validate_and_filter_queue(queue)
        -- pass opts to temporarily increase walk speed for house build (faster)
        bot_set_task(bot, queue, name, {walk_speed = 8.0})
        return true
    end

    -- .pool [wall_node] [water_node]
    if cmd == "pool" then
        local wall = args[2] or "default:stonebrick"
        local water = args[3] or "default:water_source"
        local minp, maxp = bounds_from_two_points(p1, p2)
        local queue = {}
        local width = maxp.x - minp.x + 1
        local length = maxp.z - minp.z + 1
        if width < 3 or length < 3 then
            minetest.chat_send_player(name, "Pool area too small (min 3x3).")
            return true
        end

        -- excavate interior down to minp.y (erase everything within region)
        for y=minp.y, maxp.y do
            for z=minp.z, maxp.z do
                for x=minp.x, maxp.x do
                    queue[#queue+1] = {pos={x=x,y=y,z=z}, action="erase", filter=nil}
                end
            end
        end

        -- bottom lining with wall node
        for x=minp.x, maxp.x do
            for z=minp.z, maxp.z do
                queue[#queue+1] = {pos={x=x,y=minp.y,z=z}, action="place", node=wall}
            end
        end

        -- perimeter walls rising one block above minp.y
        local wall_top_y = minp.y + 1
        for y=minp.y+1, wall_top_y do
            for x=minp.x, maxp.x do
                queue[#queue+1] = {pos={x=x,y=y,z=minp.z}, action="place", node=wall}
                queue[#queue+1] = {pos={x=x,y=y,z=maxp.z}, action="place", node=wall}
            end
            for z=minp.z+1, maxp.z-1 do
                queue[#queue+1] = {pos={x=minp.x,y=y,z=z}, action="place", node=wall}
                queue[#queue+1] = {pos={x=maxp.x,y=y,z=z}, action="place", node=wall}
            end
        end

        -- fill interior with water at minp.y level (not on walls)
        for x=minp.x+1, maxp.x-1 do
            for z=minp.z+1, maxp.z-1 do
                queue[#queue+1] = {pos={x=x,y=minp.y,z=z}, action="place", node=water}
            end
        end

        queue = validate_and_filter_queue(queue)
        bot_set_task(bot, queue, name)
        return true
    end

    minetest.chat_send_player(name, "Unknown builder bot command: "..cmd)
    return true
end)

-- Periodic cleanup: remove bots whose owners are no longer online
local cleanup_timer = 0.0
minetest.register_globalstep(function(dtime)
    cleanup_timer = cleanup_timer + dtime
    if cleanup_timer < 5.0 then return end
    cleanup_timer = 0.0
    for owner, lua in pairs(bots) do
        if lua and lua.object then
            local player = minetest.get_player_by_name(owner)
            if not player then
                if lua.object then lua.object:remove() end
                bots[owner] = nil
                player_markers[owner] = nil
            end
        else
            bots[owner] = nil
            player_markers[owner] = nil
        end
    end
end)

-- ========== Shutdown safety ==========
minetest.register_on_shutdown(function()
    for _,bot in pairs(bots) do
        if bot and bot.object then bot_abort(bot) end
    end
end)
