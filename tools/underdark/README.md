# THE UNDERDARK generator

Rebuilds `maps/underdark/underdark.glb` and `layout.json` from a fixed seed.

Requires Python 3.12 with numpy, scipy, scikit-image, matplotlib.

    python gen.py out

Outputs `out/underdark.glb`, `out/layout.json`, `out/report.json` (validation: connectivity, tunnel slopes, bar gaps) and `out/preview.png`. Copy the glb and json into `mods-unpacked/zonda-CoopSync/maps/underdark/`.

- `sdf.py`: noise and signed distance primitives (chambers, tunnels, shafts, trenches, the surface bowl)
- `world.py`: the authored route, biomes, puzzles, traps, set pieces (`SCALE` sets overall size)
- `tubes.py`: hand-meshed crawl tunnels for The Burrows
- `gen.py`: meshing, placement, glTF export, validation
- `make_normals.py`: builds the F4 graphics normal/roughness maps from the game's own textures (needs the game's extracted texture files)
- `glb_bounds.py`: measures model bounds
- `ext_manifest.json`: bounds and triangle counts of the CC0 prop models (read by `world.py`, written by `convert_assets.py`)
- `convert_assets.py`: converts the downloaded CC0 model packs into `maps/underdark/ext/` (needs trimesh; expects the packs and a local `build/` folder)
- `make_zip.py`: packs a local `build/` folder into the release zip (`python make_zip.py <version> [output folder]`)
- `xprop_tour.py`: adds camera tour stops for placed props (expects `out/`)

`make_normals.py` also needs Pillow.


## v4: The Great Rift

`gen.py` now builds the world from `rift_world.py` (the descent) and `sdf_rift.py` (the shapes):

- `Rift`: one meandering abyss whose radius follows control points, with broad wall noise.
- Solids put rock back into the air: `ShelfSolid` (balconies that follow the real wall), `BeamSolid` (flat-decked spans and roots), `RodSolid` (the Ribs), `ConeSolid` (stalactites and lava needles), `PlugSolid` (the Lid), `TerraceSolid` (the great shelves).
- `world.py` is kept as a library (chambers, tunnels, tubes, props) for the side caves.
- The validator checks that every station has a floor, every drop fits the rope and every gap can be thrown across.

Run `python gen.py out`, then copy `out/underdark.glb` and `out/layout.json` into `mods-unpacked/zonda-CoopSync/maps/underdark/`.

v4.2 adds `Builder.terrace()` (a fallen slab the route walks across), `hard_routes()` (the secret ladders and their relics) and the map-side weather, rescue and relic code lives in `maps/underdark/underdark.gd` and `coop_sync.gd`.
