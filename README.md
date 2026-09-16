# Idols of Ash: Co-op Sync

Full online co-op for [Idols of Ash](https://store.steampowered.com/app/4450800/Idols_of_Ash/) (Steam, game v1.41). Up to 4 players over Steam networking, no port forwarding. Also adds two custom maps and an optional graphics upgrade.

Unlike the earlier "ghost" co-op mod, this one runs a **shared world**: one set of centipedes for the whole team, visible ropes and hooks, shared level progression, respawns and spectating.

## What you get

- **See each other:** every teammate is an armored knight with a name tag and health, plus their rope and hook in real time. Movement is interpolated at 60 updates/second, and you hear your friends' hooks.
- **Shared centipedes:** the host runs the AI, everyone else sees exactly the same centipede. Each centipede hunts the **closest player**; with several centipedes they spread out over different players.
- **Shared progression:** the host picks the level and difficulty (campaign or sandbox); everyone follows automatically. Restarts and the ending are shared too. Health pickups are per player.
- **Respawn and spectate:** each player gets 1 free respawn per run, placed on solid ground next to a living teammate. Die again and you spectate; **Jump** cycles who you watch. Checkpoints refresh respawns and revive spectators. When the last living player dies, the run restarts for the whole team.
- **All sandbox maps unlocked** (without touching campaign progress or achievements).
- **F2 panel:** host/join lobby with a password, player list, and a live FPS readout.

## Custom maps (Sandbox)

### THE UNDERDARK
A full-length descent through caverns, deeper than the campaign and built for horizontal play.

- About **2,550 m** deep (the campaign is about 2,150 m), **51 rooms**, **10 biomes**, about **6 km** of horizontal travel (71% of the route vs about 43% in the campaign).
- Biomes: The Mouth, Ossuary, The Burrows, Fungal Hollow, Rootworks, Drowned Galleries, Sunken Village, Crystal Veins, The Foundry (with The Crucible), The Nest.
- **The Burrows:** crawl-tight tunnels, three holes, only one goes through.
- **The Crucible:** 12 hanging iron bars over lava. Swing, let go, throw again. One bar doesn't hold.
- **Puzzles:** light four kilns; pressure plates that need every living player (solo gets a timed door); three idol fragments that open the Foundry door.
- **The Stalker:** a fast creature that only moves while nobody is looking at it.
- Crumbling sand ledges (they rumble and shake first), chasms with pillar swings, falling boulders and icicles, fire vents, spike beds, ice shelves, centipede ambushes, per-biome music, and a scripted finale in the Nest.
- Everything that changes the world is synced for all players, and checkpoints survive a team wipe.

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

THE UNDERDARK is generated offline from a fixed seed (Python: signed distance field caves, marching cubes, hand-meshed crawl tubes) into a glTF file plus a layout file, so every player has the identical world. The generator is in [`tools/underdark`](tools/underdark).

## Known limits

- Built against game version **1.41**. A game update can break it.
- Guests should let the host drive the menus.
- Dialog scenes (lore points) pause only the player who triggered them.

## Credits

Built by Gabriel (ZondaCars) with Claude Code. Inspired by mranaglyph's original Idols-of-Ash-Coop ghost mod, which proved Steam lobbies work in this game.
