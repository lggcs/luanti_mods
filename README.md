# Luanti/Minetest Mod Collection

A collection of utility and disaster mods for Luanti (formerly Minetest).

## Installation

1. Locate your Luanti/Minetest mods directory:
   - **Linux**: `~/.minetest/mods/` or `~/.luanti/mods/`
   - **Windows**: `%USERPROFILE%\Documents\Minetest\mods\`
   - **macOS**: `~/Documents/Minetest/mods/`

2. Copy the desired mod folder(s) from this repository into your mods directory.

3. Enable the mod in your world configuration:
   - Open Luanti
   - Go to the **Settings** > **Content** or select your world and click **Configure**
   - Enable the mod(s) you want to use

Alternatively, you can enable mods by adding `load_mod_<modname> = true` to your world's `world.mt` file.

---

## Mod Overview

### builder_bot

A building assistant bot that walks around and places nodes with smooth animation.

**Features:**
- Uses markers placed by the player (place any two blocks to define a region)
- Walks and builds nodes one-by-one with visible animation
- Supports copy/paste of regions, backups, and creative builds

**Commands:**

| Command | Description |
|---------|-------------|
| `/botspawn <name>` | Spawn a builder bot at your position |
| `.drawline <node>` | Draw a line between markers using specified node |
| `.cuboid <node> [hollow]` | Fill cuboid region with node (optionally hollow) |
| `.erase [node]` | Erase all blocks in region (or only matching node) |
| `.copy <name>` | Save current region to file |
| `.paste <name>` | Paste saved region at marker 1 position |
| `.backup <name>` | Create a backup of region |
| `.restore <name>` | Restore a backup from file |
| `.tree [trunk] [leaves]` | Build a tree at marker position |
| `.house [wall] [roof] [floor]` | Build a house in the marked region |
| `.abort` | Abort current task |
| `.goaway` | Remove your bot |
| `.reset` | Clear markers and abort |

**Privileges Required:** `interact`

---

### earthquake

Creates realistic earthquake effects including ground fissures and camera shake.

**Features:**
- Camera shake effect for nearby players
- Ground craters and debris scattering
- Fault-line rifts for magnitude 6+ earthquakes
- Non-lethal damage to entities

**Commands:**

| Command | Description |
|---------|-------------|
| `/earthquake [magnitude]` | Trigger an earthquake at your position. Magnitude is 1-9 on Richter scale. If omitted, a random magnitude between 3.0-8.5 is used. |

**Privileges Required:** None (all players can use)

---

### flood

Creates and removes rising flood waters around the player.

**Features:**
- Layered water placement rising upward
- Remembers original nodes for restoration
- Configurable radius, height, and spacing

**Commands:**

| Command | Description |
|---------|-------------|
| `/flood` | Create a rising flood around you |
| `/unflood` | Remove flood water and restore terrain |

**Privileges Required:** `server`

---

### griefer

Spawns a tunneling mob that digs through blocks and places debris.

**Features:**
- Tunnels through dirt, stone, gravel, and ores
- Picks up materials and places random blocks
- Follows nearby players
- Jumps over obstacles
- Swims in water
- Drops loot and bones on death

**Commands:**

| Command | Description |
|---------|-------------|
| `/greifer` | Spawn a griefer mob near you |

**Privileges Required:** None (all players can use)

---

### meteors

Dynamic meteor shower system with realistic impacts and craters.

**Features:**
- Three meteor sizes: small, medium, large
- Crater formation on impact
- Fire ignition on flammable blocks
- Possible lava formation in deep craters
- Underwater splash effects
- Configurable spawn rates and limits

**Commands:**

| Command | Description |
|---------|-------------|
| `/meteors start` | Begin meteor showers |
| `/meteors stop` | Stop meteor showers and remove active meteors |
| `/meteors status` | Show current status (running/stopped, active count) |

**Privileges Required:** None (all players can use)

---

### tidal_wave

Creates powerful tidal waves that sweep across terrain.

**Features:**
- Destroys blocks based on material strength and momentum
- Pushes and damages entities in its path
- Configurable speed, width, length, and height
- Drops items from destroyed nodes

**Commands:**

| Command | Description |
|---------|-------------|
| `/wave_spawn [x y z dir_x dir_y dir_z speed width length height]` | Spawn a tidal wave. With no arguments, spawns in front of player facing their look direction. |
| `/wave` | Alias for `/wave_spawn` |
| `/wave_stop` | Stop and remove all active waves |

**Privileges Required:** 
- `/wave_spawn` and `/wave`: None (all players can use)
- `/wave_stop`: `server`

---

### tornado

Spawns destructive tornadoes with EF-scale ratings (Enhanced Fujita scale).

**Features:**
- EF0-EF5 intensity levels
- Picks up and throws blocks based on intensity
- Ground-following movement
- Knockback and damage to entities
- Visual particle effects
- Wind sound audio

**EF Scale Effects:**

| Rating | Description | Radius | Max Pickable Blocks |
|--------|-------------|--------|---------------------|
| EF0 | Weak | 2 | Leaves, loose items |
| EF1 | Moderate | 3 | Leaves, wood, dirt |
| EF2 | Considerable | 4 | + weak stone |
| EF3 | Severe | 5 | + stone |
| EF4 | Devastating | 8 | Most blocks |
| EF5 | Incredible | 14 | All blocks |

**Commands:**

| Command | Description |
|---------|-------------|
| `/tornado [0-5]` | Spawn a tornado at your position. Optional EF rating (0-5). Random rating if not specified. |

**Privileges Required:** `interact`

---

## Dependencies

Most mods depend on `default` mod (included with Minetest Game). Some mods may require:

- **builder_bot**: `default` (for nodes), player model (`character.b3d`)
- **earthquake**: `default` (for sounds and node drops)
- **flood**: `default` (water_source)
- **meteors**: Optional `fire` mod for fire effects, Optional `tnt` mod for explosion sounds
- **tornado**: `tornado` textures (included: `tornado_cloud.png`)

---

## License

See [LICENSE](LICENSE) file for licensing information.

---

## Compatibility

- Luanti 5.x / Minetest 5.x
- Compatible with Minetest Game and many subgames using default nodes