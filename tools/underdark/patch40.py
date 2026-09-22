"""v4.6: external CC0 models in the world (Kenney, Poly Haven, Quaternius), bat colonies,
pale blind crawlers. Generator side: xprop intents + per-biome placement. Runtime side: a
glTF loader for files that were never imported by the editor, hull collision, bats, skins."""
import io, os
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))


def edit(path, pairs):
    s = io.open(path, encoding='utf-8').read()
    for old, new in pairs:
        assert old in s, (path, old[:70])
        assert s.count(old) == 1, ("not unique", path, old[:70])
        s = s.replace(old, new, 1)
    io.open(path, 'w', encoding='utf-8', newline='\n').write(s)
    print('ok', path)


M = 'build/mods-unpacked/zonda-CoopSync/'
UD = M + 'maps/underdark/underdark.gd'

# =========================================================== generator: world.py
edit('underdark/world.py', [
    ("""A = "res://Art/"
""", """A = "res://Art/"
X = "ext/"                     # external CC0 models shipped in maps/underdark/ext/, loaded at runtime
import json as _json, os as _os
XM = _json.load(open(_os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "ext_manifest.json")))


def xsize(rel):
    return XM[rel[len(X):]]["size"]
"""),
    ("""    def prop(self, scene, pos, yaw=0.0, scale=1.0, rot_x=0.0, box=None, snap=True, vis=320.0):
        self.intents.append(("prop", dict(scene=scene, pos=np.array(pos, dtype=float), yaw=yaw,
                                          scale=scale, rot_x=rot_x, box=box, snap=snap, vis=vis)))
""", """    def prop(self, scene, pos, yaw=0.0, scale=1.0, rot_x=0.0, box=None, snap=True, vis=320.0):
        self.intents.append(("prop", dict(scene=scene, pos=np.array(pos, dtype=float), yaw=yaw,
                                          scale=scale, rot_x=rot_x, box=box, snap=snap, vis=vis)))

    def xprop(self, rel, pos, yaw=0.0, scale=1.0, rot_x=0.0, col=None, dim=0.45, snap=True, vis=220.0, sink=0.0, up=0.0):
        \"\"\"An external piece (ext/<pack>/<file>.glb). Its base is set on the floor from the manifest
        bounds. col = None | "box" | "hull". sink = fraction of its height buried. dim = how much of
        its own colour survives the game's doubled post-brightness.\"\"\"
        info = XM.get(rel[len(X):])
        if info is None:
            raise KeyError(rel)
        lo, size = info["lo"], info["size"]
        ylift = -lo[1] * scale - sink * size[1] * scale + up
        box = None
        if col == "box":
            box = [size[0] * 0.5, size[1] * 0.5, size[2] * 0.5]
        self.intents.append(("prop", dict(scene=rel, pos=np.array(pos, dtype=float), yaw=yaw, scale=scale, rot_x=rot_x,
                                          box=box, snap=snap, vis=vis, ylift=ylift, col=col, dim=dim)))
"""),
])

# =========================================================== generator: gen.py (resolve keeps the new fields)
edit('underdark/gen.py', [
    ("""        elif kind == "prop":
            p = a["pos"]
            y = p[1]
            if a["snap"]:
                fy = floor_at(p[0], p[2], p[1] + 6.0)
                if fy is None:
                    report["warnings"].append("prop without floor %s" % a["scene"])
                    continue
                if fy > p[1] + 5.0 or not headroom(p[0], p[2], fy, 1.0):
                    continue                      # the spot is inside rock (a column, a stalactite): no floating props
                y = fy - 0.05
            box = None
            if a["box"] is not None:
                box = [b * a["scale"] for b in a["box"]]
            L["props"].append({"scene": a["scene"], "pos": v3([p[0], y, p[2]]), "rot": [round(a["rot_x"], 3), round(a["yaw"], 3), 0.0],
                               "scale": round(a["scale"], 3), "box": box, "vis": a["vis"]})""",
     """        elif kind == "prop":
            p = a["pos"]
            ylift = float(a.get("ylift", 0.0))
            y = p[1] + ylift
            if a["snap"]:
                fy = floor_at(p[0], p[2], p[1] + 6.0)
                if fy is None:
                    report["warnings"].append("prop without floor %s" % a["scene"])
                    continue
                if fy > p[1] + 5.0 or not headroom(p[0], p[2], fy, 1.0):
                    continue                      # the spot is inside rock (a column, a stalactite): no floating props
                y = fy - 0.05 + ylift
            box = None
            if a["box"] is not None:
                box = [b * a["scale"] for b in a["box"]]
            ent = {"scene": a["scene"], "pos": v3([p[0], y, p[2]]), "rot": [round(a["rot_x"], 3), round(a["yaw"], 3), 0.0],
                   "scale": round(a["scale"], 3), "box": box, "vis": a["vis"]}
            if a.get("col") == "hull":
                ent["col"] = "hull"
            if "dim" in a:
                ent["dim"] = a["dim"]
            L["props"].append(ent)"""),
])

# =========================================================== generator: rift_world.py placement
edit('underdark/rift_world.py', [
    # the balcony pass
    ("""        if decor:
            self.decorate(info)
            self.detail(info)""", """        if decor:
            self.decorate(info)
            self.detail(info)
            self.xdetail(info)"""),
    ("""    def detail(self, s):
        rng, R, L = self.rng, self.R, self.L
        b, y, p, i = s["biome"], s["y"], s["p"], s["i"]""", """    # ------------------------------------------------------------ the external kits, per biome
    # Kenney (stylised, single palette), Poly Haven (photoscanned), Quaternius (low-poly ruins).
    # Scales: Kenney pieces are ~1 unit tall so they get x2.2..3; Quaternius walls are 2 m so x1.6;
    # Poly Haven is real metres. Everything sits on the floor from the manifest bounds.

    def xdetail(self, s):
        rng, R, L = self.rng, self.R, self.L
        b, y, p, i = s["biome"], s["y"], s["p"], s["i"]
        pts, angs = s["pts"], s["angs"]
        n = len(pts)
        if n < 3:
            return
        inner = lambda q, a, d=2.5: q + self.out_dir(a) * d          # toward the wall
        jit = lambda r=1.0: np.array([rng.uniform(-r, r), 0, rng.uniform(-r, r)])
        back = max(1.5, p * 0.5 - 2.2)                                # against the back wall
        lip = -(p * 0.5 - 2.0)                                        # along the edge
        face_void = lambda a: godot_yaw_facing(-self.out_dir(a))     # -Z toward the rift
        mid = n // 2
        SK = X + "quat/Skull.glb"
        if b == MOUTH:
            # the last camp before the dark: a broken gate, crates, a lamp post at the lip
            if i % 2 == 0:
                q, a = pts[mid], angs[mid]
                R.xprop(X + "quat/Wall_ArchRound_Broken.glb", inner(q, a, back), yaw=face_void(a), scale=1.6, col="box", dim=0.5)
                for sgn in (-1, 1):
                    R.xprop(X + "quat/Column_Round.glb", inner(q, a, back - 0.6) + np.array([-math.sin(a), 0, math.cos(a)]) * sgn * 4.2,
                            yaw=face_void(a), scale=1.6, col="box", dim=0.5)
            q, a = pts[1], angs[1]
            for k in range(rng.randint(2, 4)):
                R.xprop(X + rng.choice(["ph/barrel_01.glb", "ph/barrel_02.glb", "ph/old_military_crate.glb", "quat/Crate.glb"]),
                        inner(q, a, rng.uniform(1.0, 3.5)) + jit(2.0), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.0, 1.3), col="box", dim=0.42)
            for q, a in list(zip(pts, angs))[1::3]:
                R.xprop(X + "graveyard/lightpost-single.glb", inner(q, a, lip + 1.2), yaw=face_void(a) + math.pi, scale=2.6, dim=0.4)
            if i % 3 == 1:
                R.xprop(X + "ph/lantern_01.glb", inner(pts[-2], angs[-2], 1.0) + jit(1.0), yaw=rng.uniform(0, 6.28), scale=2.2, dim=0.5)
        elif b == OSSUARY:
            # the dead were buried here once, before they were stood in rows
            for q, a in list(zip(pts, angs))[::2]:
                R.xprop(X + rng.choice(["graveyard/gravestone-round.glb", "graveyard/gravestone-cross.glb", "graveyard/gravestone-bevel.glb",
                                        "graveyard/gravestone-broken.glb", "graveyard/gravestone-wide.glb", "graveyard/gravestone-decorative.glb"]),
                        inner(q, a, rng.uniform(back - 3.0, back)) + jit(1.5), yaw=face_void(a) + rng.uniform(-0.4, 0.4), scale=2.4, dim=0.4)
                if rng.random() < 0.5:
                    R.xprop(X + rng.choice(["graveyard/coffin-old.glb", "graveyard/coffin.glb"]), inner(q, a, rng.uniform(0.5, back - 2.5)) + jit(2.0),
                            yaw=rng.uniform(0, 6.28), scale=2.4, col="box", dim=0.4)
            for q, a in list(zip(pts, angs))[1::2]:
                R.xprop(X + rng.choice(["graveyard/urn-round.glb", "graveyard/urn-square.glb", "graveyard/candle-multiple.glb", "quat/Candles_1.glb", "quat/Candles_2.glb"]),
                        inner(q, a, rng.uniform(1.0, back)) + jit(2.0), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.6, 2.4), dim=0.42)
            # a pile of skulls where the balcony narrows
            q, a = pts[-2], angs[-2]
            for k in range(rng.randint(4, 8)):
                R.xprop(SK, inner(q, a, rng.uniform(0.5, back)) + jit(1.4), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.1, 1.4),
                        rot_x=rng.uniform(-0.5, 0.5), dim=0.5)
            if i % 4 == 2:
                q, a = pts[mid], angs[mid]
                R.xprop(X + "ph/gothic_statue.glb", inner(q, a, back), yaw=face_void(a), scale=1.7, col="box", dim=0.55, sink=0.02)
            elif i % 4 == 0:
                q, a = pts[mid], angs[mid]
                R.xprop(X + "graveyard/pillar-square.glb", inner(q, a, back), yaw=face_void(a), scale=2.2, col="box", dim=0.4)
                R.xprop(X + "ph/marble_bust_01.glb", inner(q, a, back), yaw=face_void(a), scale=1.6, up=1.15 * 2.2, dim=0.6)
        elif b == FUNGAL:
            # giant mushrooms, waist high to twice your height, in the wet ground near the wall
            for q, a in list(zip(pts, angs))[1:-1]:
                for k in range(rng.randint(1, 3)):
                    R.xprop(X + rng.choice(["nature/mushroom_red.glb", "nature/mushroom_tan.glb", "nature/mushroom_redGroup.glb",
                                            "nature/mushroom_tanGroup.glb", "nature/mushroom_redTall.glb", "nature/mushroom_tanTall.glb"]),
                            inner(q, a, rng.uniform(0.5, back)) + jit(2.5), yaw=rng.uniform(0, 6.28), scale=rng.uniform(5.0, 13.0), dim=0.32)
            if i % 2 == 0:
                q, a = pts[mid], angs[mid]
                R.xprop(X + rng.choice(["nature/log.glb", "nature/log_large.glb", "nature/stump_old.glb"]), inner(q, a, rng.uniform(0.0, back)) + jit(2.0),
                        yaw=rng.uniform(0, 6.28), scale=3.0, col="box", dim=0.35)
        elif b == ROOTS:
            # dead trees still stand where roots come through the roof
            for q, a in list(zip(pts, angs))[1::2]:
                R.xprop(X + "quat/DeadTree_%d.glb" % rng.randint(1, 3), inner(q, a, rng.uniform(back - 2.0, back)) + jit(1.5),
                        yaw=rng.uniform(0, 6.28), scale=rng.uniform(2.0, 2.8), dim=0.5)
            if i % 2 == 1:
                q, a = pts[mid], angs[mid]
                R.xprop(X + rng.choice(["nature/log_stack.glb", "nature/log_stackLarge.glb", "nature/stump_round.glb"]), inner(q, a, rng.uniform(0.0, back)) + jit(2.0),
                        yaw=rng.uniform(0, 6.28), scale=2.6, col="box", dim=0.35)
        elif b == DROWNED:
            # what the water left: barrels, a boat, a broken rail along the lip
            for q, a in list(zip(pts, angs))[::2]:
                for k in range(rng.randint(1, 3)):
                    R.xprop(X + rng.choice(["ph/barrel_01.glb", "ph/barrel_02.glb", "ph/barrel_03.glb", "quat/Pot1_Broken.glb", "quat/Pot2_Broken.glb"]),
                            inner(q, a, rng.uniform(0.5, back)) + jit(2.0), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.1, 1.4), col="box", dim=0.42)
            if i % 3 == 0:
                q, a = pts[mid], angs[mid]
                R.xprop(X + "nature/canoe.glb", inner(q, a, rng.uniform(0.0, back - 1.0)), yaw=rng.uniform(0, 6.28), scale=3.0, rot_x=rng.uniform(-0.15, 0.15), dim=0.35)
            for q, a in list(zip(pts, angs))[1::3]:
                R.xprop(X + "quat/Rail_Straight.glb", inner(q, a, lip + 0.6), yaw=face_void(a) + math.pi * 0.5, scale=1.5, dim=0.5)
        elif b == VILLAGE:
            # the temple the village was built around: arches, columns, the things people kept
            q, a = pts[mid], angs[mid]
            R.xprop(X + rng.choice(["quat/Wall_ArchRound.glb", "quat/Wall_ArchRound_Overgrown.glb", "quat/Wall_ArchRound_Broken.glb", "quat/Wall_Overgrown.glb", "quat/Wall_Double_Hole.glb"]),
                    inner(q, a, back), yaw=face_void(a), scale=1.6, col="box", dim=0.5)
            for j, (q, a) in enumerate(list(zip(pts, angs))[::2]):
                R.xprop(X + ("quat/Column_Round.glb" if j % 2 == 0 else "quat/Column_Round_Short.glb"), inner(q, a, back - 1.0) + jit(0.6),
                        yaw=face_void(a), scale=1.6, col="box", dim=0.5)
            if i % 2 == 0 and n >= 5:
                q, a = pts[1], angs[1]
                R.xprop(X + "quat/Arch_Round.glb", inner(q, a, back - 3.0), yaw=face_void(a) + math.pi * 0.5, scale=1.5, dim=0.5)
            for j, (q, a) in enumerate(list(zip(pts, angs))[1::2]):
                if j % 3 == 0:
                    R.xprop(X + rng.choice(["quat/Cart.glb", "quat/Bookcase_Full.glb", "quat/Bookcase_Empty.glb"]), inner(q, a, back - 0.5) + jit(0.5),
                            yaw=face_void(a) + rng.uniform(-0.3, 0.3), scale=1.2, col="box", dim=0.5)
                else:
                    R.xprop(X + rng.choice(["quat/Chest.glb", "quat/Pot1.glb", "quat/Pot2.glb", "quat/Pot3.glb", "quat/Crate.glb"]),
                            inner(q, a, rng.uniform(1.0, back - 1.0)) + jit(1.5), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.1, 1.4), col="box", dim=0.5)
            if i % 3 == 1:
                q, a = pts[-2], angs[-2]
                R.xprop(X + "quat/Torch.glb", inner(q, a, back + 0.2), yaw=face_void(a), scale=1.5, up=1.6, dim=0.6)
                L["lights"].append({"pos": v3(inner(q, a, back - 0.8) + np.array([0, 2.6, 0])), "color": [1.0, 0.55, 0.2], "energy": 0.7, "range": 14.0})
            if i % 4 == 3:
                q, a = pts[mid], angs[mid]
                R.xprop(X + rng.choice(["quat/Statue_Stag.glb", "quat/Statue_Fox.glb"]), inner(q, a, back), yaw=face_void(a), scale=1.3, col="box", dim=0.5)
        elif b == CRYSTAL:
            # boulders shed from the walls, half sunk in the floor
            for q, a in list(zip(pts, angs))[1::2]:
                R.xprop(X + "ph/namaqualand_boulder_0%d.glb" % rng.randint(2, 6), inner(q, a, rng.uniform(0.0, back)) + jit(2.0),
                        yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.3, 2.2), col="hull", dim=0.5, sink=0.3, vis=150.0)
        elif b == FOUNDRY:
            # a mine: timber supports every few metres, carts, picks, the crates they never opened
            for q, a in zip(pts, angs):
                R.xprop(X + "dungeon/wood-support.glb", q, yaw=face_void(a) + math.pi * 0.5, scale=3.4, dim=0.42)
            if i % 2 == 0:
                q, a = pts[mid], angs[mid]
                R.xprop(X + "quat/Cart.glb", inner(q, a, back - 1.5) + jit(0.5), yaw=face_void(a) + rng.uniform(-0.4, 0.4), scale=1.2, col="box", dim=0.5)
            for q, a in list(zip(pts, angs))[1::2]:
                R.xprop(X + rng.choice(["ph/old_military_crate.glb", "quat/Crate.glb", "dungeon/barrel.glb", "quat/Bricks.glb", "quat/Chest.glb"]),
                        inner(q, a, rng.uniform(1.0, back - 1.5)) + jit(1.5), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.1, 2.4) if rng.random() < 0.3 else 1.2, col="box", dim=0.45)
            if i % 3 == 0:
                q, a = pts[-2], angs[-2]
                R.xprop(X + "ph/picke_dirty_01.glb", inner(q, a, back) + jit(0.5), yaw=face_void(a), scale=1.6, rot_x=-0.35, dim=0.55)
                R.xprop(X + "quat/BearTrap_Open.glb", inner(q, a, rng.uniform(1.0, back - 2.0)) + jit(1.0), yaw=rng.uniform(0, 6.28), scale=1.4, dim=0.5)
            if i % 4 == 1:
                q, a = pts[1], angs[1]
                R.xprop(X + rng.choice(["quat/Arch_Gothic.glb", "quat/Support_Tall.glb", "quat/Column_Square.glb"]), inner(q, a, back - 1.5), yaw=face_void(a), scale=1.6, col="box", dim=0.5)
                R.xprop(X + "dungeon/table.glb", inner(q, a, rng.uniform(1.0, back - 2.0)) + jit(1.0), yaw=rng.uniform(0, 6.28), scale=2.4, col="box", dim=0.42)
                R.xprop(X + "dungeon/chair.glb", inner(q, a, rng.uniform(1.0, back - 2.0)) + jit(1.5), yaw=rng.uniform(0, 6.28), scale=2.4, dim=0.42)
        elif b in (NEST, BURROWS):
            q, a = pts[mid], angs[mid]
            for k in range(rng.randint(3, 6)):
                R.xprop(SK, inner(q, a, rng.uniform(0.5, back)) + jit(1.6), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.1, 1.4), rot_x=rng.uniform(-0.5, 0.5), dim=0.5)
        # small photoscanned stones everywhere but the Mouth: they catch the lantern
        if b != MOUTH:
            for q, a in list(zip(pts, angs))[::3]:
                R.xprop(X + rng.choice(["ph/namaqualand_stones_01.glb", "ph/namaqualand_rocks_01.glb", "ph/namaqualand_boulders_01.glb"]),
                        inner(q, a, rng.uniform(-1.0, back)) + jit(2.0), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.5, 3.0), dim=0.5, sink=0.15, vis=120.0)
        # a colony of bats roosts under every fourth overhang in the wetter strata
        if b in (OSSUARY, ROOTS, DROWNED, FUNGAL) and i % 4 == 2:
            q, a = pts[mid], angs[mid]
            L.setdefault("bats", []).append({"pos": v3(inner(q, a, back - 1.0) + np.array([0, 6.5, 0])), "n": rng.randint(12, 20), "r": 15.0})

    def xterrace(self, T, land, path, pside, plen, biome, y_top, r, cxz):
        \"\"\"The kits on a plateau: boulder fields off the lamp line, and the biome's own furniture.\"\"\"
        rng, R = self.rng, self.R

        def ok(q, m=8.0):
            return T.side(q) >= m and self.rift.wall_r(self.rift.bearing(q), y_top) - float(np.hypot(*(q[[0, 2]] - cxz))) >= m

        for j in range(int(plen / 9.0)):
            q = land + path * rng.uniform(0.05, 0.95) + pside * rng.choice([-1, 1]) * rng.uniform(7.0, 32.0)
            if not ok(q):
                continue
            R.xprop(X + rng.choice(["ph/boulder_01.glb", "ph/namaqualand_boulder_02.glb", "ph/namaqualand_boulder_03.glb", "ph/namaqualand_boulder_04.glb",
                                    "ph/namaqualand_boulder_05.glb", "ph/namaqualand_boulder_06.glb"]),
                    q, yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.6, 2.8), col="hull", dim=0.5, sink=0.28, vis=160.0)
        for j in range(int(plen / 14.0)):
            q = land + path * rng.uniform(0.05, 0.95) + pside * rng.uniform(-30.0, 30.0)
            if not ok(q, 6.0):
                continue
            R.xprop(X + rng.choice(["ph/namaqualand_stones_01.glb", "ph/namaqualand_rocks_01.glb", "ph/namaqualand_boulders_01.glb"]),
                    q, yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.5, 3.0), dim=0.5, sink=0.15, vis=120.0)
        extra = {
            OSSUARY: (["graveyard/gravestone-round.glb", "graveyard/gravestone-cross-large.glb", "graveyard/cross.glb", "graveyard/coffin-old.glb", "quat/Skull.glb"], 2.3, 10),
            FUNGAL: (["nature/mushroom_redGroup.glb", "nature/mushroom_tanGroup.glb", "nature/mushroom_redTall.glb", "nature/mushroom_tan.glb"], 9.0, 14),
            ROOTS: (["quat/DeadTree_1.glb", "quat/DeadTree_2.glb", "quat/DeadTree_3.glb", "nature/log_large.glb"], 2.4, 8),
            DROWNED: (["ph/barrel_01.glb", "ph/barrel_03.glb", "quat/Column_BridgeSupport.glb", "nature/canoe.glb"], 1.5, 8),
            VILLAGE: (["quat/Column_Round.glb", "quat/Wall_Broken.glb", "quat/Wall_ArchRound_Broken.glb", "quat/Statue_Stag.glb", "quat/Cart.glb", "quat/Stairs.glb"], 1.6, 9),
            CRYSTAL: (["ph/namaqualand_boulder_02.glb", "ph/namaqualand_boulder_05.glb"], 2.0, 5),
            FOUNDRY: (["dungeon/wood-support.glb", "quat/Cart.glb", "quat/Support_Tall.glb", "quat/Bricks.glb", "ph/old_military_crate.glb", "quat/Column_Square.glb"], 1.6, 10),
        }.get(biome)
        if extra:
            names, sc, cnt = extra
            for j in range(cnt):
                q = land + path * rng.uniform(0.08, 0.92) + pside * rng.choice([-1, 1]) * rng.uniform(5.0, 26.0)
                if not ok(q, 6.0):
                    continue
                nm = rng.choice(names)
                s_ = sc * (3.4 / 1.6 if nm.startswith("dungeon/") else 1.0) * rng.uniform(0.85, 1.15)
                R.xprop(X + nm, q, yaw=rng.uniform(0, 6.28), scale=s_, col="box" if not nm.endswith("Skull.glb") else None, dim=0.45)

    def detail(self, s):
        rng, R, L = self.rng, self.R, self.L
        b, y, p, i = s["biome"], s["y"], s["p"], s["i"]"""),
    ("""        # on some of them, something lives
        if idx % 2 == 1:
            cx, cz = self.rift.center(y_top)""", """        self.xterrace(T, land, path, pside, plen, biome, y_top, r, cxz)
        # on some of them, something lives
        if idx % 2 == 1:
            cx, cz = self.rift.center(y_top)"""),
    # every other territorial centipede is the pale kind: blind, bone white, born down here
    ("""        yy_ = c_["trigger"][0][1]
        for (t_, b_, bi_) in STRATA:
            if t_ >= yy_ > b_:
                c_["territory"] = [t_, b_]""", """        yy_ = c_["trigger"][0][1]
        for (t_, b_, bi_) in STRATA:
            if t_ >= yy_ > b_:
                c_["territory"] = [t_, b_]
                if bi_ in (OSSUARY, CRYSTAL, FOUNDRY, BURROWS, NEST) or int(c_["id"][-1]) % 2 == 1:
                    c_["skin"] = "pale\""""),
])

# =========================================================== runtime: underdark.gd
edit(UD, [
    ("""var _dimmed: Dictionary = {}""", """var _dimmed: Dictionary = {}
var _ext_tmpl: Dictionary = {}         # ext/<pack>/<file>.glb -> template Node3D (never in the tree)"""),
    ("""func _place_props() -> void:
	var cache: Dictionary = {}
	for p in L.get("props", []):
		var path: String = p["scene"]
		if not cache.has(path):
			cache[path] = load(path)
		var ps: PackedScene = cache[path]
		if ps == null:
			continue
		var n: Node3D = ps.instantiate()
		n.position = _v(p["pos"])""", """func _place_props() -> void:
	var cache: Dictionary = {}
	var ext_n := 0
	for p in L.get("props", []):
		var path: String = p["scene"]
		var n: Node3D
		if path.begins_with("ext/"):
			n = _ext_instance(path, float(p.get("dim", 0.45)))
			if n == null:
				continue
			ext_n += 1
		else:
			if not cache.has(path):
				cache[path] = load(path)
			var ps: PackedScene = cache[path]
			if ps == null:
				continue
			n = ps.instantiate()
		n.position = _v(p["pos"])"""),
    ("""		var ruin: bool = path.contains("Village_") or path.contains("Ghost_Tower") or path.contains("Building_") or path.contains("Roof_") or path.contains("Door.glb") or path.contains("Tower_0")
		if path.contains("Plant_"):""", """		if str(p.get("col", "")) == "hull":
			_ext_hull(n, path, float(p["scale"]))
		var ruin: bool = path.contains("Village_") or path.contains("Ghost_Tower") or path.contains("Building_") or path.contains("Roof_") or path.contains("Door.glb") or path.contains("Tower_0")
		if path.begins_with("ext/"):
			pass                          # already dimmed to its own factor
		elif path.contains("Plant_"):"""),
    ("""func _dim_materials(n: Node, k: float) -> void:""", """# ------------------------------------------------------------------ external models
# The kits under maps/underdark/ext/ were never imported by the editor, so load() cannot see
# them. GLTFDocument reads the .glb at runtime; each file becomes one template whose mesh
# instances are copied (with their transforms) per placement.

func _ext_template(rel: String) -> Node3D:
	if _ext_tmpl.has(rel):
		return _ext_tmpl[rel]
	_ext_tmpl[rel] = null
	var bytes := FileAccess.get_file_as_bytes(DIR + rel)
	if bytes.is_empty():
		push_warning("[Underdark] ext model missing: " + rel)
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_buffer(bytes, "", state) != OK:
		push_warning("[Underdark] ext model unreadable: " + rel)
		return null
	var root: Node = doc.generate_scene(state)
	if root == null:
		return null
	var tmpl := Node3D.new()
	var found: Array = []
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		found.append([mi, (mi as MeshInstance3D).mesh])
	for imi in root.find_children("*", "ImporterMeshInstance3D", true, false):
		var im: ImporterMesh = imi.mesh
		if im != null:
			found.append([imi, im.get_mesh()])
	for pair in found:
		var src: Node3D = pair[0]
		var mesh: Mesh = pair[1]
		if mesh == null:
			continue
		var xf := Transform3D.IDENTITY
		var node: Node = src
		while node != null and node != root:
			if node is Node3D:
				xf = (node as Node3D).transform * xf
			node = node.get_parent()
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.transform = xf
		# every surface gets its own material copy so the dim never touches the shared resource
		for si in mesh.get_surface_count():
			var m: Material = mesh.surface_get_material(si)
			if m is StandardMaterial3D:
				mi.set_surface_override_material(si, (m as StandardMaterial3D).duplicate())
		tmpl.add_child(mi)
	root.free()
	_ext_tmpl[rel] = tmpl
	return tmpl


func _ext_instance(rel: String, dim: float) -> Node3D:
	var key := "%s|%.2f" % [rel, dim]
	if _ext_tmpl.has(key):
		return null if _ext_tmpl[key] == null else (_ext_tmpl[key] as Node3D).duplicate()
	var t := _ext_template(rel)
	if t == null:
		_ext_tmpl[key] = null
		return null
	var n: Node3D = t.duplicate()
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		for si in m.mesh.get_surface_count():
			var src: Material = m.get_active_material(si)
			if src is StandardMaterial3D:
				var d: StandardMaterial3D = src.duplicate()
				d.albedo_color = Color(d.albedo_color.r * dim, d.albedo_color.g * dim, d.albedo_color.b * dim, d.albedo_color.a)
				d.emission_enabled = false
				m.set_surface_override_material(si, d)
	_ext_tmpl[key] = n
	return n.duplicate()


func _ext_hull(n: Node3D, rel: String, sc: float) -> void:
	# a convex hull per mesh, so boulders can be stood on and hooked like rock
	var t := _ext_template(rel)
	if t == null:
		return
	if not t.has_meta("hulls"):
		var hulls: Array = []
		for c in t.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
				var shp: ConvexPolygonShape3D = (c as MeshInstance3D).mesh.create_convex_shape(true, true)
				if shp != null and shp.points.size() >= 4:
					hulls.append([shp.points, (c as Node3D).transform])
		t.set_meta("hulls", hulls)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.physics_material_override = load("res://physics_materials/stone.tres")
	for h in t.get_meta("hulls"):
		var pts: PackedVector3Array = h[0]
		var xf: Transform3D = h[1]
		var out := PackedVector3Array()
		out.resize(pts.size())
		for i in pts.size():
			out[i] = (xf * pts[i]) * sc
		var shape := ConvexPolygonShape3D.new()
		shape.points = out
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
	body.position = n.position
	body.rotation = n.rotation
	add_child(body)


func _place_bats() -> void:
	for b in L.get("bats", []):
		var s := BatSwarm.new()
		s.setup(b)
		add_child(s)


func _dim_materials(n: Node, k: float) -> void:"""),
    ("""	_place_ghosts()
	_place_bars()""", """	_place_ghosts()
	_place_bats()
	_place_bars()"""),
    ("""	print("[Underdark] built in %d ms: %d chunks, %d props" % [Time.get_ticks_msec() - t0, _chunks.size(), L.get("props", []).size()])""",
     """	print("[Underdark] built in %d ms: %d chunks, %d props, %d external models" % [Time.get_ticks_msec() - t0, _chunks.size(), L.get("props", []).size(), ext_n])"""),
    ("""			add_child(n)
			if bool(c.get("follower", false)):
				_follower = n""", """			add_child(n)
			if c.has("skin") and n.has_method("coop_apply_skin"):
				n.coop_apply_skin(1 if str(c["skin"]) == "pale" else 0)
			if bool(c.get("follower", false)):
				_follower = n"""),
    ("""class Ghost extends Node3D:""", """class BatSwarm extends Node3D:
	# A colony roosting under an overhang. When the local player comes near it bursts out,
	# wheels once around the balcony and is gone up the rift. Each player sees their own.
	var bats: Array = []
	var vel: Array = []
	var live := false
	var t := 0.0
	var trig := 15.0
	var n_bats := 14
	var mesh: ArrayMesh
	var mat: StandardMaterial3D

	func setup(d: Dictionary) -> void:
		position = Vector3(d["pos"][0], d["pos"][1], d["pos"][2])
		trig = float(d.get("r", 15.0))
		n_bats = int(d.get("n", 14))
		mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.012, 0.01, 0.012)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.add_vertex(Vector3(0, 0, 0.08))
		st.add_vertex(Vector3(-0.3, 0.05, -0.1))
		st.add_vertex(Vector3(-0.1, 0, -0.08))
		st.add_vertex(Vector3(0, 0, 0.08))
		st.add_vertex(Vector3(0.1, 0, -0.08))
		st.add_vertex(Vector3(0.3, 0.05, -0.1))
		mesh = st.commit()

	func _process(delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		if not live:
			if Engine.get_process_frames() % 10 != 0:
				return
			if (c.global_position - global_position).length() < trig:
				_burst()
			return
		t += delta
		for i in bats.size():
			var b: MeshInstance3D = bats[i]
			var v: Vector3 = vel[i]
			var to_home: Vector3 = global_position - b.global_position
			to_home.y = 0.0
			var wheel := Vector3(-to_home.z, 0.0, to_home.x).normalized() * 6.5
			var up := Vector3(0, clampf(t - 2.2, 0.0, 1.0) * 8.0, 0)
			var want: Vector3 = wheel + to_home.normalized() * 1.5 + up + Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * 5.0
			v = v.lerp(want, delta * 3.0)
			vel[i] = v
			b.global_position += v * delta
			var flat := Vector3(v.x, 0.0, v.z)
			if flat.length() > 0.2:
				b.look_at(b.global_position + flat.normalized() * 2.0, Vector3.UP)
			b.scale = Vector3(1.0 + 0.55 * sin(t * 27.0 + i * 1.7), 1.0, 1.0)
		if t > 7.5:
			queue_free()

	func _burst() -> void:
		live = true
		for i in n_bats:
			var b := MeshInstance3D.new()
			b.mesh = mesh
			b.material_override = mat
			b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			b.position = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * 2.0
			add_child(b)
			bats.append(b)
			vel.append(Vector3(randf() - 0.5, randf() * 0.4, randf() - 0.5) * 9.0)
		U.sfx("res://sfx/soundsnap/1022742.audio-HUMAN_VOCAL_Female_4_Breath_Medium_01.wav", -14.0, Vector3.ZERO, self, 26.0)


class Ghost extends Node3D:"""),
])

# =========================================================== runtime: the pale skin, host and puppets
edit(M + 'ext/centipede.gd', [
    ("""var coop_puppet := false""", """var coop_puppet := false
var coop_skin := 0               # 0 = the game's centipede, 1 = pale blind crawler (Underdark)"""),
    ("""func coop_apply_state(s: Array, sender_t: int) -> void:
	visible = true""", """func coop_apply_skin(k: int) -> void:
	coop_skin = k
	set_meta("zonda_skin", k)
	call_deferred("_coop_paint_skin")


func _coop_paint_skin() -> void:
	if coop_skin == 0 or not is_inside_tree():
		return
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.7, 0.66, 0.56)       # bone. Never saw the sun.
	m.metallic = 0.05
	m.roughness = 0.85
	for mi in find_children("*", "MeshInstance3D", true, false):
		var mesh_i := mi as MeshInstance3D
		if mesh_i.mesh == null:
			continue
		for si in mesh_i.mesh.get_surface_count():
			mesh_i.set_surface_override_material(si, m)


func on_bio_lum_state_updated() -> void:
	super()
	if coop_skin != 0:
		_coop_paint_skin()


func coop_apply_state(s: Array, sender_t: int) -> void:
	visible = true
	if s.size() > 4 and int(s[4]) != coop_skin:
		coop_apply_skin(int(s[4]))"""),
])

edit(M + 'coop_sync.gd', [
    ("""			list.append([c.global_position, c.global_basis.get_rotation_quaternion(), c._current_state is centipede_state_attack, c.stamina])""",
     """			list.append([c.global_position, c.global_basis.get_rotation_quaternion(), c._current_state is centipede_state_attack, c.stamina, int(c.get_meta("zonda_skin", 0))])"""),
])
