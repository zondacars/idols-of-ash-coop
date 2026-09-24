# Idols of Ash: Co-op Sync

Full online co-op for [Idols of Ash](https://store.steampowered.com/app/4450800/Idols_of_Ash/) (Steam, game v1.41). Up to 4 players over Steam networking, no port forwarding. Also adds two custom maps and an optional graphics upgrade.

Unlike the earlier "ghost" co-op mod, this one runs a **shared world**: one set of centipedes for the whole team, visible ropes and hooks, shared level progression, respawns and spectating.

## What you get

- **See each other:** every teammate is an armored knight with a name tag and health, plus their rope and hook in real time. Movement is interpolated at 60 updates/second, and you hear your friends' hooks.
- **Shared centipedes:** the host runs the AI, everyone else sees exactly the same centipede. Each centipede hunts the **closest player**; with several centipedes they spread out over different players.
- **Version-checked, worldwide lobbies:** friends anywhere find your lobby, and nobody joins a session on a different build by mistake. A friend still on v4.6 or older won't see a v4.9 lobby at all, so everyone updates first.
- **Shared progression:** the host picks the level and difficulty (campaign or sandbox); everyone follows automatically. Restarts and the ending are shared too. Health pickups are per player.
- **Respawn and spectate:** each player gets 1 free respawn per run, placed on solid ground next to a living teammate. Die again and you spectate; **Jump** cycles who you watch. Checkpoints refresh respawns and revive spectators. **Rescue:** a player who runs out of respawns leaves a pale soul where they last stood, and a living teammate who stays next to it for 1.5 s pulls them back into the run on the spot (works on every map). When the last living player dies, the run restarts for the whole team.
- **3D voice chat on every level:** hold **V** to talk, or **F7** for an open mic (uses the microphone chosen in Steam > Settings > Voice). Voices come from your teammate's knight, fade with distance (out by about 70 m) and are muffled when rock is between you. In THE UNDERDARK they echo with the cave, long in the open rift and tight in tunnels, tuned per biome. A ((•)) mark shows over whoever is talking; the F2 panel has one voice volume slider (0 to 200%) and a Mute box for each teammate.
- **A hand lantern on every level:** press **L** in the campaign or any map. A caged flame in your right hand that throws a warm beam ahead, glows around you, flickers and gusts; teammates see it in your knight's hand. Remembered per player.
- **All sandbox maps unlocked** (without touching campaign progress or achievements).
- **F2 panel:** host/join lobby with a password, player list, voice volume and per-player mute, and a live FPS readout.

## Custom maps (Sandbox)

### THE UNDERDARK (v4.9, "The Great Rift")
One colossal abyss modelled on the campaign's own chasm (measured in game: the campaign is 2,100 m deep and 310 to 400 m wide, with 150 to 300 m sightlines).

- **4,144 m** deep (the campaign is 2,100 m). The rift is **190 to 460 m across**, and you can see the far wall, the ledges below you and the landmarks from hundreds of metres away.
- Strata: The Mouth, Ossuary, The Burrows, Fungal Hollow, Rootworks, Drowned Galleries, Sunken Village, Crystal Veins, The Foundry (with The Crucible), The Nest.
- **Eight great shelves:** fallen slabs that floor most of the rift on alternating sides, so there is no straight line down. Land on one, follow the lamps 160 to 340 m across it, leave by its far corner. Every second one has a centipede living on it.
- **The Short Way:** three secret ladders (The Mouth, the Drowned Galleries, and the foot of the Crystal Veins down into the Foundry) that start at a violet light. Tiny footholds, no embers, no checkpoints; they skip the normal road but never a kiln, a plate or an idol fragment. Each ends at a **relic** you keep forever: a gold name tag, then a gold rope, then a crown your team can see.
- **Air:** soft coloured haze banks per biome (spore banks in the Fungal Hollow, pale bone dust in the Ossuary, mist over the Drowned footholds, cold haze in the Crystal Veins, smoke in the Foundry), plus drifting dust, ash, spores, drips and embers that come in spells of about a minute with clear air in between. Dust and ash only show where light falls on them. **F6** turns the particles off and on (per player, remembered).
- **Set pieces that cross the whole void:** the Span (a broken 323 m stone bridge), four giant roots (420 to 460 m each), two hanging village archipelagos (44 platforms on chains), three crystal spars (405 to 420 m each).
- **Landmarks:** The Ribs (a ribcage the size of a street, grown into the Ossuary wall), The Chandelier (18 stalactites under the Lid), The Needles (rock spires standing in the lava lake).
- **The fall rule:** land a fall of 40 m or more and you die. Shorter falls cost about a third of your health. The rope itself is exactly as in the base game.
- **Ladders:** 100 of the 180 drops are small footholds a full rope apart with nothing else below. Deeper down they shrink and shift sideways. **The Plunge** is 12 in a row, about 260 m.
- **The Burrows:** crawl-tight tunnels, three holes, only one goes through.
- **The Crucible:** thin rods of hot iron across the whole rift over a lava lake, 26 m apart (more than a full rope). Grapple only: you cannot stand on a rod. A few sink.
- **Centipedes:** the Follower comes in behind you at the top and hunts the team all the way down. The others are woken in their biome and stay there after you leave. The deep-strata ones are **pale blind crawlers**, bone white and unlit.
- **The lantern (F5):** the map is nearly black by default and you carry a caged flame that throws a beam ahead of you and glows around you, casts shadows, flickers and gusts. Teammates see it swinging in your knight's hand. F5 switches LANTERN (dark) or NORMAL, per player, remembered; L overrides the lantern any time.
- **Real objects everywhere:** 588 CC0 models (Kenney, Poly Haven photoscans, Quaternius ruins) placed per biome: a broken gate and crates at the Mouth, graves, coffins, skull piles and statues in the Ossuary, giant mushrooms, dead trees, barrels and a canoe, a ruined temple with carts and torches in the Village, boulders you can stand on and hook in the Crystal Veins, timber mine supports, carts and picks in the Foundry, boulder fields on every shelf. **Bat colonies** roost under overhangs and burst out when you walk under them.
- **Puzzles:** light four kilns; pressure plates that need every living player (solo gets a timed door); three idol fragments that open the Foundry door.
- **New creatures (v4.9):** **the Brood** (when someone takes the idol, the Nest goes dark and 13 small crawlers hatch from the egg clusters around the altar), **wall spiders** in the Rootworks and the Crystal Veins (they click, drop on a thread, bite and climb back), and **the waking husk** (one "dead" centipede husk in the Crystal Veins shivers and wakes up as you pass). Every attack warns you first.
- **Lamp oil:** a full lantern burns for 12 minutes; 19 flasks along the way refill it, and holding **G** next to a teammate pours them a quarter of a full lantern from yours (you need at least 30%).
- **Cave sound:** an ambience bed per biome, an echo that changes between the open rift and tunnels, positional drips, rockfalls and chain creaks, and a heartbeat when something hunting you is within 18 m. Heat haze shimmers over the Foundry's lava lake and around its fires.
- **The Stalker:** a fast creature that only moves while nobody is looking at it. **Bells:** hit one with your hook and hunters go to the sound instead of to you.
- Crumbling sand ledges (they rumble and shake first), rocks that let go above you, fire vents, spike beds, ice shelves, waterfalls that push, per-biome music, and a scripted finale in the Nest.
- Everything that changes the world is synced for all players, and the 21 checkpoints survive a team wipe.
- **The finale:** whoever takes the idol carries it out in their hand, the exit opens only when every living player is there, and an end card shows the team time and who carried the idol. A team run clock survives deaths.
- Difficulty: about 9 out of 10 (the campaign is about a 5). 21 checkpoints; dying twice keeps your checkpoint and everything the team opened. Leave the "Additional Centipedes" slider at 0, the map places its own.

### INFERNO
A shorter, straight 1,100 m shaft in three parts (Hell, The Dark, a frozen circle) with traps.

## Enhanced graphics (F4)

Per player, remembered between sessions, NORMAL PIXELS by default. **F4** toggles between two modes, nothing in between:

| Mode | What you get |
|---|---|
| NORMAL PIXELS | the game's own look at 640x360, lit properly: indirect light in the crevices, soft shadows on the 16 nearest lights |
| ULTRA HD | native resolution through AMD FSR 2.2 (drawn at 77%, upscaled with its own anti-aliasing; 4x MSAA where FSR 2.2 is unavailable), real CC0 rock textures (ambientCG) in THE UNDERDARK, normal maps on stone, glow, filmic color, bounce lighting (SDFGI), indirect light, reflections, ultra-soft shadows on the 32 nearest lights. NORMAL light is as bright as in NORMAL PIXELS. |

Works in the campaign and every map. On a strong PC ULTRA HD costs about 20 to 30% of the FPS.

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
