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


## v4: The Great Rift

`gen.py` now builds the world from `rift_world.py` (the descent) and `sdf_rift.py` (the shapes):

- `Rift`: one meandering abyss whose radius follows control points, with broad wall noise.
- Solids put rock back into the air: `ShelfSolid` (balconies that follow the real wall), `BeamSolid` (flat-decked spans and roots), `RodSolid` (the Ribs), `ConeSolid` (stalactites and lava needles), `PlugSolid` (the Lid).
- `world.py` is kept as a library (chambers, tunnels, tubes, props) for the side caves.
- The validator checks that every station has a floor, every drop fits the rope and every gap can be thrown across.

Run `python gen.py out`, then copy `out/underdark.glb` and `out/layout.json` into `mods-unpacked/zonda-CoopSync/maps/underdark/`.
