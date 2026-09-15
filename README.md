# Idols of Ash: Co-op Sync

Full online co-op for [Idols of Ash](https://store.steampowered.com/app/4450800/Idols_of_Ash/) (Steam, game v1.41). Up to 4 players over Steam networking, no port forwarding.

Unlike the earlier "ghost" co-op mod, this one runs a **shared world**: one set of centipedes for the whole team, visible ropes and hooks, shared pickups, shared level progression, respawns and spectating.

## What you get

- **See each other:** every teammate is an armored knight with a name tag and health, plus their rope and hook in real time. Movement is interpolated at 60 updates/second so it looks smooth.
- **Shared centipedes:** the host runs the AI, everyone else sees exactly the same centipede. Each centipede hunts the **closest player**; with several centipedes they spread out over different players. They bite and knock back anyone.
- **Shared embers (health pickups):** whoever grabs one, it's gone for everyone.
- **Shared progression:** the host picks the level and difficulty (campaign or sandbox); everyone follows automatically. Restarts and the ending trigger are shared too.
- **Respawn and spectate:** each player gets 1 free respawn per run (you come back at the nearest living teammate's last grounded spot with 3 s of immunity). Die again and you spectate a living player; **Jump** cycles who you watch. When the last living player dies, the run restarts for the whole team.
- **F2 panel:** host/join lobby with a password, player list, and a live performance readout (FPS, frame time, mod cost).

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

The mod is plain GDScript loaded through Godot's `override.cfg` autoload; it does not modify any game files. It extends four of the game's scripts at runtime (climber, centipede, ember pickup, ending trigger) and runs a host-authoritative simulation: the host streams centipede head transforms, every player streams their position, camera yaw, rope points, and hook transform; guests run "puppet" centipedes whose body segments follow locally. Reliable Steam messages carry events (level changes, pickups, deaths, ending).

## Known limits

- Built against game version **1.41**. A game update can break it.
- Guests should let the host drive the menus.
- Dialog scenes (lore points) pause only the player who triggered them.

## Credits

Built by Gabriel (ZondaCars) with Claude Code. Inspired by mranaglyph's original Idols-of-Ash-Coop ghost mod, which proved Steam lobbies work in this game.
