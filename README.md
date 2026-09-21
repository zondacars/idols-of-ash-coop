# Idols of Ash: Co-op Sync

Full online co-op for [Idols of Ash](https://store.steampowered.com/app/4450800/Idols_of_Ash/) (Steam, game v1.41). Up to 4 players over Steam networking, no port forwarding. Also adds two custom maps and an optional graphics upgrade.

Unlike the earlier "ghost" co-op mod, this one runs a **shared world**: one set of centipedes for the whole team, visible ropes and hooks, shared level progression, respawns and spectating.

## What you get

- **See each other:** every teammate is an armored knight with a name tag and health, plus their rope and hook in real time. Movement is interpolated at 60 updates/second, and you hear your friends' hooks.
- **Shared centipedes:** the host runs the AI, everyone else sees exactly the same centipede. Each centipede hunts the **closest player**; with several centipedes they spread out over different players.
- **Shared progression:** the host picks the level and difficulty (campaign or sandbox); everyone follows automatically. Restarts and the ending are shared too. Health pickups are per player.
- **Respawn and spectate:** each player gets 1 free respawn per run, placed on solid ground next to a living teammate. Die again and you spectate; **Jump** cycles who you watch. Checkpoints refresh respawns and revive spectators. **Rescue:** a player who runs out of respawns leaves a pale soul where they last stood, and a living teammate who stays next to it for 1.5 s pulls them back into the run on the spot (works on every map). When the last living player dies, the run restarts for the whole team.
- **All sandbox maps unlocked** (without touching campaign progress or achievements).
- **F2 panel:** host/join lobby with a password, player list, and a live FPS readout.

## Custom maps (Sandbox)

### THE UNDERDARK (v4.2, "The Great Rift")
One colossal abyss modelled on the campaign's own chasm (measured in game: the campaign is 2,100 m deep and 310 to 400 m wide, with 150 to 300 m sightlines).

- **3,380 m** deep (the campaign is 2,100 m). The rift is **170 to 420 m across**, and you can see the far wall, the ledges below you and the landmarks from hundreds of metres away.
- Strata: The Mouth, Ossuary, The Burrows, Fungal Hollow, Rootworks, Drowned Galleries, Sunken Village, Crystal Veins, The Foundry (with The Crucible), The Nest.
- **Six great shelves:** fallen slabs that floor most of the rift on alternating sides, so there is no straight line down. Land on one, follow the lamps 160 to 340 m across it, leave by its far corner. Every second one has a centipede living on it.
- **The Short Way:** three secret ladders (Ossuary, Fungal Hollow, Crystal Veins) that start at a violet light. Tiny footholds, no embers, no checkpoints, and you skip whatever was on the normal road. Each ends at a **relic** you keep forever: a gold name tag, then a gold rope, then a crown your team can see.
- **Weather per biome:** dust, falling bone ash, rising spores and spore clouds, drips, rain and mist over the footholds, ice glitter, ash and sparks.
- **Set pieces that cross the whole void:** the Span (a broken 288 m stone bridge), four giant roots (385 to 395 m each), two hanging village archipelagos (51 platforms on chains), three crystal spars (about 390 m each).
- **Landmarks:** The Ribs (a ribcage the size of a street, grown into the Ossuary wall), The Chandelier (18 stalactites under the Lid), The Needles (rock spires standing in the lava lake).
- **The fall rule:** land a fall of 40 m or more and you die. Shorter falls cost about a third of your health. The rope itself is exactly as in the base game.
- **Ladders:** 57 of the 141 drops are small footholds a full rope apart with nothing else below. Deeper down they shrink and shift sideways. **The Plunge** is 9 in a row, about 200 m.
- **The Burrows:** crawl-tight tunnels, three holes, only one goes through.
- **The Crucible:** thin rods of hot iron across the whole rift over a lava lake, 26 m apart (more than a full rope). Grapple only: you cannot stand on a rod. A few sink.
- **Centipedes:** the Follower comes in behind you at the top and hunts the team all the way down. The others are woken in their biome and stay there after you leave.
- **Puzzles:** light four kilns; pressure plates that need every living player (solo gets a timed door); three idol fragments that open the Foundry door.
- **The Stalker:** a fast creature that only moves while nobody is looking at it. **Bells:** hit one with your hook and hunters go to the sound instead of to you.
- Crumbling sand ledges (they rumble and shake first), rocks that let go above you, fire vents, spike beds, ice shelves, waterfalls that push, per-biome music, and a scripted finale in the Nest.
- Everything that changes the world is synced for all players, and the 20 checkpoints survive a team wipe.
- Difficulty: about 8 out of 10 (the campaign is about a 5). Leave the "Additional Centipedes" slider at 0, the map places its own.

### INFERNO
A shorter, straight 500 m hell shaft with traps.

## Enhanced graphics (F4)

Per player, remembered between sessions, off by default. **F4** cycles:

| Mode | What it adds |
|---|---|
| OFF | the original look |
| LOW | normal maps on stone, glow, filmic color, shadows on the 8 nearest lights |
| HIGH | LOW + bounce lighting (SDFGI), indirect light, reflections, shadows on the 20 nearest lights |
| HIGH + HD | HIGH at your screen's native resolution instead of 640x360 |

Works in the campaign and every map. On a strong PC, HIGH costs almost nothing (about 200 FPS either way); HD costs about 20%.

## Install (every player)

1. Download the latest release zip from the [Releases](../../releases) page.
2. In Steam, right-click **Idols of Ash** → **Manage** → **Browse local files**.
3. Copy `override.cfg` and the `mods-unpacked` folder into that folder, next to `idols_of_ash.exe`.
4. Launch the game normally through Steam.

To uninstall, delete `override.cfg` and the `mods-unpacked` folder.

## Play

1. On the main menu press **F2**. Enter a name and a shared password.
2. One player clicks **Host Game**. Everyone else clicks **Join Game** with the same password.
3. Press **F2** again to close the panel. The **host** starts a level (Start or Sandbox). Guests follow automatically and should not start levels themselves.

## How it works (short version)

The mod is plain GDScript loaded through Godot's `override.cfg` autoload; it does not modify any game files. It extends a few of the game's scripts at runtime and runs a host-authoritative simulation: the host streams centipede transforms, every player streams position, camera, rope and hook; guests run puppet centipedes. Reliable Steam messages carry events (levels, deaths, map events, checkpoints).

THE UNDERDARK is generated offline from a fixed seed (Python: a signed distance field for the rift, rock solids put back into it for balconies, spans, ribs and spires, marching cubes, hand-meshed crawl tubes) into a glTF file plus a layout file, so every player has the identical world. The generator is in [`tools/underdark`](tools/underdark).

## Known limits

- Built against game version **1.41**. A game update can break it.
- Guests should let the host drive the menus.
- Dialog scenes (lore points) pause only the player who triggered them.

## Credits

Built by Gabriel (ZondaCars) with Claude Code. Inspired by mranaglyph's original Idols-of-Ash-Coop ghost mod, which proved Steam lobbies work in this game.
