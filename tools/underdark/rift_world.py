"""THE UNDERDARK, second shape: THE GREAT RIFT.

One colossal abyss, 280 to 420 m across and about 3,400 m deep, modelled on the campaign's
own chasm (measured in game: 310-400 m wide, sightlines of 150-300 m). The ten biomes are
strata of the rift. You descend along wall balconies, across wall-to-wall spans, and through
side caves cut into the rock. Falls of more than ~45 m kill (a map rule), so the rope matters.
"""
import math
import numpy as np

import world as W
from world import *          # Route, BIOMES, biome ids, GLOW, A, CORPSES, PLANTS_*, sounds, v3, hdir ...
from sdf import Tunnel, noise_fields
from sdf_rift import Rift, ShelfSolid, BeamSolid, PlugSolid, RodSolid, ConeSolid, TerraceSolid

LOOK_BONE = 10
LOOK_BARK = 11

STANDING = [A + "Corpse_0%d.glb" % i for i in (1, 2, 3, 4)]       # the wrapped dead, upright
KIT = [(A + "Stone_01.glb", (1.0, 2.2)), (A + "Stone_04.glb", (0.9, 1.7)), (A + "Stone_05.glb", (0.9, 1.7)),
       (A + "Stone_02.glb", (0.9, 1.6)), (A + "Rock_01.glb", (1.4, 2.8))]

Z = 1.3           # depth scale (v4.5: "make the map 30% bigger")
RW = 1.1          # width scale
STRATA = [(t * Z, b * Z, bi) for (t, b, bi) in
          [(-30, -330, MOUTH), (-330, -765, OSSUARY), (-765, -1185, FUNGAL), (-1185, -1575, ROOTS),
           (-1575, -1965, DROWNED), (-1965, -2365, VILLAGE), (-2365, -2765, CRYSTAL), (-2765, -3230, FOUNDRY)]]
LID = (-772.0 * Z, -792.0 * Z)
LAKE_Y = -3205.0 * Z


class Builder:
    def __init__(self, seed):
        self.R = Route(seed)
        self.R.steer = lambda: None            # the old route-bending is meaningless here
        self.rng = self.R.rng
        self.L = self.R.L
        for k in ("strata", "platforms", "spars", "falls", "stations"):
            self.L[k] = []
        self.L["rules"] = {"lethal_fall_speed": 38.0, "bruise_from": 19.0, "bruise_per": 4.5}      # 38 m/s = a 40 m fall
        self.solids = []
        self.moves = []
        self.terraces = []
        self.shelves = []
        self.cp = 0
        self.a = 0.0
        self.y = 0.0
        self.dirn = 1
        self.shelf_i = 0
        self.rift = Rift((430.0, 20.0), -30.0 * Z, LAKE_Y - 4.0,
                         [(y * Z, r * RW) for (y, r) in
                          [(-30, 85), (-200, 112), (-330, 135), (-700, 145), (-790, 150), (-1000, 175), (-1185, 185),
                           (-1400, 190), (-1575, 165), (-1800, 160), (-1965, 195), (-2200, 210), (-2365, 185),
                           (-2600, 180), (-2765, 195), (-3000, 185)]] + [(LAKE_Y - 4.0, 150 * RW)], STRATA)
        self.R.group += 1
        self.R.prims.append(self.rift)
        self.R.groups.append(self.R.group)
        for (t, b, bi) in STRATA:
            self.L["strata"].append({"top": t, "bottom": b, "biome": bi})

    # ------------------------------------------------------------ small helpers

    def rw(self, a=None, y=None):
        return self.rift.wall_r(self.a if a is None else a, self.y if y is None else y)

    def spot(self, a, y, inset):
        return self.rift.point(a, y, inset)

    def out_dir(self, a):
        return np.array([math.cos(a), 0.0, math.sin(a)])

    def station(self, p, kind, biome, label=""):
        self.L["stations"].append({"pos": v3(p), "kind": kind, "biome": biome, "label": label})

    def checkpoint(self, p, label, biome):
        self.R.intents.append(("checkpoint", dict(id=self.cp, x=float(p[0]), z=float(p[2]), y=float(p[1]), label=label, biome=biome)))
        self.cp += 1

    def ghost(self, p, face):
        self.R.intents.append(("ghost", dict(pos=np.array(p, dtype=float), face=np.array(face, dtype=float))))

    def tour(self, p, look, label):
        self.L["tour"].append({"pos": v3(np.array(p) + np.array([0, 1.8, 0])), "look": v3(look), "label": label})

    # ------------------------------------------------------------ balconies

    def shelf(self, biome, length, p=None, lobe_p=None, gap=False, decor=True, label=""):
        """A balcony along the wall from the current bearing, `length` metres in the travel direction."""
        rng = self.rng
        y = self.y
        r = self.rw()
        arc = length / r
        a0, a1 = self.a, self.a + self.dirn * arc
        p = p or rng.uniform(9.0, 12.5)
        if gap and length > 34:
            g = rng.uniform(9.5, 11.5) / r
            am = 0.5 * (a0 + a1)
            for (s0, s1) in ((a0, am - self.dirn * g * 0.5), (am + self.dirn * g * 0.5, a1)):
                self.solids.append(ShelfSolid(self.rift, y, 0.5 * (s0 + s1), abs(s1 - s0) * 0.5 + 1.5 / r, p))
            self.moves.append({"type": "swing", "gap": round(g * r, 1), "y": y})
        else:
            self.solids.append(ShelfSolid(self.rift, y, 0.5 * (a0 + a1), arc * 0.5 + 2.0 / r, p))
        if lobe_p:
            self.solids.append(ShelfSolid(self.rift, y, a0 + self.dirn * 4.0 / r, 9.0 / r, lobe_p))
        info = dict(a0=a0, a1=a1, y=y, p=p, r=r, biome=biome, length=length, dirn=self.dirn, i=self.shelf_i, gap=gap, label=label)
        self.shelf_i += 1
        n = max(3, int(length / 7.0))
        if not hasattr(self, "shelves"):
            self.shelves = []
        self.shelves.append(info)
        info["pts"] = [self.spot(a0 + (a1 - a0) * f, y, p * 0.5) for f in np.linspace(0.06, 0.94, n)]
        info["angs"] = [a0 + (a1 - a0) * f for f in np.linspace(0.06, 0.94, n)]
        for q in (info["pts"][0], info["pts"][-1]):
            self.station(q, "shelf", biome, label)
        if decor:
            self.decorate(info)
            self.detail(info)
            self.xdetail(info)
        self.a = a1
        # the ones who came before stand where you go down
        if info["i"] % 2 == 0:
            self.ghost(info["pts"][-1], -self.out_dir(a1))
        return info

    def under(self, dy, switchback=None):
        """Step down to the next balcony: its start sits under the end of this one."""
        rng = self.rng
        prev_p = self.solids[-1].p if isinstance(self.solids[-1], ShelfSolid) else 10.0
        r = self.rw()
        self.y -= dy
        if switchback is None:
            switchback = rng.random() < 0.3
        if switchback:
            self.dirn *= -1
            self.a += self.dirn * (2.0 / r)
        else:
            self.a -= self.dirn * (8.0 / r)
        self.moves.append({"type": "drop", "dy": round(dy, 1), "y": self.y})
        return min(prev_p + 6.5, 19.0)

    def chain(self, biome, n, above=None):
        """The hard part: a ladder of small footholds a full rope apart. Miss one and you die.
        Deeper down the footholds shrink and stagger sideways, so you swing to them, not just lower."""
        rng = self.rng
        first = None
        k = float(np.clip((-self.y - 250.0 * Z) / (2700.0 * Z), 0.0, 1.0))        # 0 near the top, 1 at the lake
        self.chain_i = getattr(self, "chain_i", 0) + 1
        side = rng.choice([-1, 1])
        prev_q = above
        for i in range(n):
            off = rng.uniform(3.5, 5.0 + 5.0 * k)
            dy = rng.uniform(19.5, 23.0) if off < 5.0 else rng.uniform(18.5, 21.0)
            self.y -= dy
            r = self.rw()
            p = (6.5 - 2.0 * k) if i % 2 == 0 else (10.5 - 3.5 * k)
            side = -side
            am = self.a + side * (0.5 * off / r)
            self.a += self.dirn * (1.2 / r)
            self.solids.append(ShelfSolid(self.rift, self.y, am, (4.3 - 1.6 * k) / r, p, thick=3.4))
            q = self.spot(am, self.y, p * 0.5)
            self.station(q, "foothold", biome)
            self.moves.append({"type": "drop", "dy": round(dy, 1), "y": self.y, "hard": True, "side": round(off, 1)})
            if first is None:
                first = q
            # a rock lodged in the wall above this foothold. It lets go when you land.
            if self.y < -700 * Z and i >= 1 and rng.random() < 0.3 + 0.25 * k:
                hang = self.spot(am, self.y + dy - 5.0, 1.6)
                self.L["droppers"].append({"id": self.R.next_id("dr"), "kind": "boulder", "hang": v3(hang),
                                           "floor": round(float(self.y), 2), "trip": [v3(q + np.array([0, 1.0, 0])), 3.6]})
            # something comes down the wall after you
            if i == 1 and prev_q is not None and self.y < -900 * Z and self.chain_i % 2 == 0:
                self.L["centipedes"].append({"id": self.R.next_id("cen"), "trigger": [v3(q + np.array([0, 1.5, 0])), 7.0],
                                             "spawn": [v3(np.array(above) + np.array([0, 3.0, 0]))]})
                self.R.text(q, 6.0, "Legs on stone, above you. Many. Keep going down.")
            if rng.random() < 0.7:        # a tempting sand ledge off to the side that will not hold
                side = rng.choice([-1, 1]) * rng.uniform(11.0, 15.0) / r
                self.R.intents.append(("wall_crumble", dict(a=am + side, y=self.y + rng.uniform(4, 9))))
            if i % 2 == 1:
                self.R.L["lights"].append({"pos": v3(q + np.array([0, 3.0, 0])), "color": GLOW[biome], "energy": 0.7, "range": 18.0})
        self.a += self.dirn * (2.0 / self.rw())
        return first

    def run(self, biome, y_end, chain_every=1, chain_n=(5, 7), len_rng=(26, 56), dy_rng=(19.0, 23.0), gap_chance=0.6, terraces=()):
        since = 0
        lobe = None
        pending = sorted(terraces, reverse=True)
        while self.y - y_end > 1.0:
            L = self.rng.uniform(*len_rng)
            info = self.shelf(biome, L, lobe_p=lobe, gap=self.rng.random() < gap_chance)
            since += 1
            rem = self.y - y_end
            if pending and self.y - 19.0 <= pending[0] and rem > 62.0:
                pending.pop(0)
                lobe = self.terrace(biome)
                since = 0
                continue
            if rem <= 22.5:
                lobe = self.under(rem)
                continue
            if rem < 40.0:
                lobe = self.under(rem * 0.5)
                continue
            n_max = int((rem - 24.0) / 23.0)
            if pending:                      # never let a ladder carry the route past a planned terrace
                n_max = min(n_max, int((self.y - pending[0] - 12.0) / 23.0))
            if since >= chain_every and n_max >= 3:
                since = 0
                self.R.text(info["pts"][-1], 6.0, self.rng.choice([
                    "From here it is rope and nerve. The footholds are a full line apart.",
                    "Small ledges, far between. Let the rope out slowly.",
                    "No balcony below. Only what your hook can reach.",
                ]))
                self.chain(biome, min(self.rng.randint(*chain_n), n_max), above=info["pts"][-1])
                rem2 = self.y - y_end
                lobe = self.under(rem2 if rem2 <= 22.5 else self.rng.uniform(16, 21), switchback=False)
            else:
                lobe = self.under(self.rng.uniform(*dy_rng))
        # v49 (#71): a planned great shelf the run had no room left for used to vanish silently
        for t_ in pending:
            self.L.setdefault("warnings_gen", []).append(
                "%s: planned terrace at %.0f not built (run ended at %.0f, a terrace needs 62 m left below it)" % (BIOMES[biome], t_, self.y))
        return lobe

    # ------------------------------------------------------------ dressing every balcony

    def decorate(self, s):
        rng = self.rng
        R = self.R
        b = s["biome"]
        pts, angs = s["pts"], s["angs"]
        i = s["i"]
        # rock against the back wall and along the lip, like the campaign's piled slabs
        for q, a in zip(pts, angs):
            if rng.random() < 0.75:
                piece = KIT[rng.randrange(len(KIT))]
                R.intents.append(("shaft_dress", dict(S=q, y=q[1] + rng.uniform(0.5, 7.0), ang=a + rng.uniform(-0.25, 0.25),
                                                      scene=piece[0], scale=rng.uniform(*piece[1]))))
        if i % 2 == 0:
            m = pts[len(pts) // 2]
            R.L["lights"].append({"pos": v3(m + np.array([0, 5.5, 0])), "color": GLOW[b], "energy": 0.95, "range": 34.0})
        if i % 3 == 1:
            R.intents.append(("ember", dict(pos=pts[rng.randrange(len(pts))] + np.array([rng.uniform(-1, 1), 0, rng.uniform(-1, 1)]))))
        inner = lambda q, a, d=2.5: q + self.out_dir(a) * d          # toward the wall
        if b == MOUTH:
            if i % 2 == 0:
                R.prop(A + "Tent.glb", inner(pts[1], angs[1]), yaw=rng.uniform(0, 6.28))
                R.fire(pts[1] - self.out_dir(angs[1]) * 1.0, 0.45)
            for q, a in list(zip(pts, angs))[::3]:
                R.prop(A + "Village_Structure_0%d.glb" % rng.randint(1, 4), inner(q, a, 3.5), yaw=a + math.pi / 2, scale=rng.uniform(1.0, 1.5))
        elif b == OSSUARY:
            # the dead stand in rows against the wall, as they do in the campaign
            for q, a in zip(pts, angs):
                for k in range(rng.randint(0, 2)):
                    R.prop(rng.choice(STANDING), inner(q, a, rng.uniform(1.0, 3.2)) + np.array([rng.uniform(-1.2, 1.2), 0, rng.uniform(-1.2, 1.2)]),
                           yaw=godot_yaw_facing(-self.out_dir(a)), scale=rng.uniform(0.9, 1.15))
        elif b == FUNGAL:
            for q, a in list(zip(pts, angs))[1:-1]:
                for k in range(2):
                    R.prop(rng.choice(PLANTS_L + PLANTS_S), inner(q, a, rng.uniform(0.5, 3.5)) + np.array([rng.uniform(-3, 3), 0, rng.uniform(-3, 3)]),
                           yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.1, 2.4))
            R.light(pts[len(pts) // 2], rng.choice([[0.3, 1.0, 0.6], [0.4, 0.8, 1.0], [0.7, 1.0, 0.3]]), 0.5, 18, lift=3.2)
        elif b == ROOTS:
            for q, a in list(zip(pts, angs))[::2]:
                R.intents.append(("shaft_dress", dict(S=q, y=q[1] + rng.uniform(2, 9), ang=a, scene=A + "Roots.glb", scale=rng.uniform(0.8, 1.5))))
        elif b == DROWNED:
            if i % 2 == 1:
                q, a = pts[len(pts) // 2], angs[len(pts) // 2]
                top = q + self.out_dir(a) * 3.0 + np.array([0, 26.0, 0])
                self.L["falls"].append({"pos": v3(top), "height": 30.0, "push": v3(-self.out_dir(a) * 6.5), "floor": round(float(q[1]), 2)})
            for q, a in list(zip(pts, angs))[::3]:
                R.prop(rng.choice(CORPSES), q, yaw=rng.uniform(0, 6.28))
        elif b == VILLAGE:
            for q, a in list(zip(pts, angs))[1::3]:
                sc = rng.uniform(0.55, 0.8)
                R.prop(A + "Village_Building.glb", inner(q, a, 1.0), yaw=rng.uniform(0, 6.28), scale=sc, box=[5.6, 7.05, 5.6])
                R.L["lights"].append({"pos": v3(q + np.array([0, 5.0, 0])), "color": [1.0, 0.6, 0.25], "energy": 0.9, "range": 16.0})
            for q, a in list(zip(pts, angs))[::4]:
                R.prop(A + "Village_Structure_0%d.glb" % rng.randint(1, 4), q, yaw=a, scale=rng.uniform(1.0, 1.5))
        elif b == CRYSTAL:
            for q, a in zip(pts, angs):
                if rng.random() < 0.6:
                    R.intents.append(("crystal", dict(pos=inner(q, a, rng.uniform(0, 3.5)), s=rng.uniform(1.2, 3.4))))
            if i % 3 == 0:
                for q, a in zip(pts[1:-1], angs[1:-1]):
                    self.L["ice"].append({"pos": v3(q + np.array([0, 0.8, 0])), "r": 4.5, "dir": v3(-self.out_dir(a))})
        elif b == FOUNDRY:
            for q, a in list(zip(pts, angs))[1::3]:
                R.prop(rng.choice([A + "Ancient_Kiln.glb", A + "Broken_Kiln.glb"]), inner(q, a, 1.5), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.0, 1.5))
                R.L["lights"].append({"pos": v3(q + np.array([0, 3.0, 0])), "color": [1.0, 0.45, 0.15], "energy": 1.3, "range": 18.0})
            if i % 2 == 0:
                for q in pts[1:-1:2]:
                    R.intents.append(("vent", dict(x=float(q[0]), z=float(q[2]), y=float(q[1]) + 3)))
        # one hazard now and then, so a balcony is never just a walk
        if i % 4 == 3 and len(pts) > 4 and b not in (MOUTH,):
            q, a = pts[len(pts) // 2], angs[len(pts) // 2]
            R.intents.append(("spike_bed", dict(x=float(q[0]), z=float(q[2]), y_from=float(q[1]) + 3, push=v3(-self.out_dir(a)))))

    # ------------------------------------------------------------ terraces: the rift's great shelves

    def in_terrace(self, p, margin=2.0):
        return any(t["solid"].covers(p, margin) for t in self.terraces)

    def terrace(self, biome, label=None):
        """Drop onto a fallen shelf that covers most of the rift, cross it, leave by its far corner.
        Each one leans toward the side the last one left open, so no straight line down stays clear."""
        rng, R, L = self.rng, self.R, self.L
        dy = rng.uniform(16.0, 19.0)
        y_top = self.y - dy
        r = float(self.rift.radius(y_top))
        a_mid = self.a
        if self.terraces:
            want = self.terraces[-1]["a_mid"] + math.pi
            d = (want - self.a + math.pi) % (2 * math.pi) - math.pi
            d = max(-1.25, min(1.25, d))
            a_mid = self.a + d
            if abs(d) > 0.05:
                self.dirn = 1 if d > 0 else -1          # leave by the far corner: the long way across
        k = 0.2
        thick = rng.uniform(11.0, 14.5)
        T = TerraceSolid(self.rift, y_top, a_mid, k, thick)
        self.solids.append(T)
        idx = len(self.terraces)
        name = label or "THE SHELF %s" % ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX"][min(idx, 8)]
        land = self.spot(self.a, y_top, 9.0)
        self.station(land, "terrace", biome, name)
        self.moves.append({"type": "drop", "dy": round(dy, 1), "y": y_top})
        theta = math.acos(-k)
        a_exit = a_mid + self.dirn * theta
        corner = self.spot(a_exit - self.dirn * (12.0 / r), y_top, 8.0)
        self.station(corner, "terrace", biome, name)
        path = corner - land
        plen = float(np.linalg.norm(path))
        pdir = path / plen
        pside = np.array([-pdir[2], 0.0, pdir[0]])
        self.terraces.append({"solid": T, "a_mid": a_mid, "y_top": y_top, "thick": thick, "land": land, "corner": corner, "biome": biome, "name": name})
        self.moves.append({"type": "walk", "length": round(plen, 0), "y": y_top})
        R.text(land, 10.0, rng.choice([
            "A shelf of rock the size of a field, fallen across the rift. The only way on is over its far corner. Follow the lamps.",
            "The rift is floored here, wall to wall, almost. Someone lit a line of lamps across it. It is a long way to the edge.",
            "Flat ground. It feels wrong after so much rope. The lamps lead to the one corner where the dark opens again.",
        ]))
        # the lamp line: lanterns and light every ~28 m from where you land to where you leave
        nl = max(3, int(plen / 28.0))
        # v49 (#96): on the shelves where something lives (odd idx) the lamps past the trigger go
        # out one by one when it wakes (the runtime DyingLights). The corner lamp stays lit so the
        # way off the shelf is still readable. Same rng draws as before.
        dying = []
        for j in range(nl + 1):
            q = land + path * (j / nl) + pside * rng.uniform(-2.5, 2.5)
            if idx % 2 == 1 and 0.45 <= j / nl and j < nl:
                dying.append(q)
                continue
            L.setdefault("lanterns_extra", []).append({"pos": v3(q + np.array([0, 2.4, 0])), "color": GLOW[biome], "s": 1.3})
            if j % 2 == 0:
                L["lights"].append({"pos": v3(q + np.array([0, 5.0, 0])), "color": GLOW[biome], "energy": 0.9, "range": 32.0})
        # standing stones and stalagmites off the path: a plateau should not be a parking lot
        for j in range(int(plen / 16.0)):
            f = rng.uniform(0.06, 0.94)
            off = rng.choice([-1, 1]) * rng.uniform(9.0, 34.0)
            q = land + path * f + pside * off
            if T.side(q) < 10.0 or self.rift.wall_r(self.rift.bearing(q), y_top) - float(np.hypot(*(q[[0, 2]] - np.array([float(c_) for c_ in self.rift.center(y_top)])))) < 8.0:
                continue
            if rng.random() < 0.55:
                h = rng.uniform(9.0, 20.0)
                self.solids.append(RodSolid(q - np.array([0, 2.0, 0]), q + np.array([rng.uniform(-2, 2), h, rng.uniform(-2, 2)]), rng.uniform(1.9, 2.8), 1.4, rough=0.14))
            else:
                self.solids.append(ConeSolid(q - np.array([0, 2.0, 0]), rng.uniform(8.0, 17.0), rng.uniform(3.0, 4.6), rough=0.3))
        # a dead centipede across the plateau, twice the length of the ones on balconies
        hs = rng.uniform(2.2, 2.9)
        hdir = pdir * rng.choice([-1, 1]) + pside * rng.uniform(-0.45, 0.45)
        hdir = hdir / float(np.linalg.norm(hdir))
        cxz = np.array([float(c_) for c_ in self.rift.center(y_top)])
        h0 = land + path * rng.uniform(0.22, 0.4) + pside * rng.choice([-1, 1]) * rng.uniform(13.0, 19.0)
        placed_h = 0
        n_sec = 17
        # v49 K12: every piece of this husk carries a key, so gen.py can pick one great-shelf husk to
        # wake (it tags that one's props "husk_id" for the map to hide). No rng draws added.
        hkey = "t%d" % idx
        hsec = []
        for j in range(n_sec):
            q = h0 + hdir * (j * 1.5 * hs)
            if T.side(q) < 12.0 or self.rift.wall_r(self.rift.bearing(q), y_top) - float(np.hypot(*(q[[0, 2]] - cxz))) < 9.0:
                continue
            R.prop(A + ("Monster_Head.glb" if j == n_sec - 1 else "Monster_BodySection.glb"), [q[0], y_top + 0.5 * hs, q[2]],
                   yaw=godot_yaw_facing(hdir) + rng.uniform(-0.12, 0.12), scale=hs, rot_x=rng.uniform(-0.08, 0.08), snap=False)
            R.intents[-1][1]["husk_key"] = hkey
            hsec.append((j, np.array(q, dtype=float)))
            if j % 2 == 0 and j < n_sec - 1:
                for sgn in (-1, 1):
                    R.prop(A + "Monster_UpperLeg.glb", [q[0], y_top + 0.35 * hs, q[2]], yaw=godot_yaw_facing(hdir) + sgn * 1.45,
                           scale=hs * 1.3, rot_x=0.5, snap=False)
                    R.intents[-1][1]["husk_key"] = hkey
            placed_h += 1
        L.setdefault("_terrace_husks", []).append({"key": hkey, "idx": idx, "biome": biome, "y_top": float(y_top), "hs": float(hs),
                                                   "hdir": hdir.copy(), "land": land.copy(), "path": path.copy(), "sections": hsec,
                                                   "n_sec": n_sec, "lives": idx % 2 == 1})
        if placed_h >= 6:
            if not hasattr(self, "husk_marks"):
                self.husk_marks = []
            self.husk_marks.append((h0 + hdir * (n_sec // 2 * 1.5 * hs), None, biome))
        # a camp halfway, ruins, the dead
        mid = land + path * 0.5 + pside * 6.0
        R.prop(A + "Tent.glb", mid + pside * 3.0, yaw=rng.uniform(0, 6.28))
        R.fire(mid, 0.6)
        R.intents.append(("ember", dict(pos=mid - pside * 2.5)))
        for j in range(5):
            q = land + path * rng.uniform(0.1, 0.9) + pside * rng.uniform(-14, 14)
            R.prop(rng.choice(CORPSES), q, yaw=rng.uniform(0, 6.28))
        for j in range(4):
            q = land + path * rng.uniform(0.15, 0.85) + pside * rng.choice([-1, 1]) * rng.uniform(7, 22)
            R.prop(A + "Village_Structure_0%d.glb" % rng.randint(1, 4), q, yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.0, 1.6))
        for j in range(int(plen / 12.0)):
            q = land + path * rng.uniform(0.04, 0.96) + pside * rng.uniform(-30, 30)
            if T.side(q) < 6.0:
                continue
            R.prop(rng.choice([A + "Stone_04.glb", A + "Stone_05.glb", A + "Rock_01.glb"]), q, yaw=rng.uniform(0, 6.28), scale=rng.uniform(0.5, 1.4))
        self.xterrace(T, land, path, pside, plen, biome, y_top, r, cxz)
        # on some of them, something lives
        if idx % 2 == 1:
            trig = land + path * 0.45 + np.array([0, 1.5, 0])
            # v49 (#96): it comes down the lamp line from the corner end, the way the dark walks
            spawn = land + path * 0.92 + np.array([0, 3.0, 0])
            L["centipedes"].append({"id": R.next_id("cen"), "trigger": [v3(trig), 14.0], "spawn": [v3(spawn)]})
            if dying:
                # far lamps first: DyingLights puts out lights[0] first, so the dark walks toward you
                R.intents.append(("dying_lights", dict(id=R.next_id("dl"), points=dying[::-1], trigger=[trig, 14.0], off=0.0)))
            R.text(land + path * 0.4, 8.0, "The lamps ahead are going out, one by one. Something is walking down the line toward you.")
        self.tour(land + np.array([0, 22.0, 0]) - pdir * 10.0, land + path * 0.6, name)
        L["tour"][-1]["air"] = True
        R.text(corner, 8.0, "The edge. Below the corner, against the wall, there is a ledge. Everything else is air.")
        # leave by the corner: the next balcony starts just past the chord end, under the slab's lip
        self.a = a_exit + self.dirn * (4.0 / r)
        dy2 = thick * 1.25 + rng.uniform(5.0, 6.5)
        self.y = y_top - min(dy2, 23.0)
        self.moves.append({"type": "drop", "dy": round(min(dy2, 23.0), 1), "y": self.y})
        return 18.5

    # ------------------------------------------------------------ the second pass: what makes a balcony a place

    def husk(self, s, scale, n):
        """A dead centipede lying along the balcony, head toward the way down."""
        rng, R = self.rng, self.R
        a = s["angs"][1]
        step = 1.5 * scale
        if n < 4:
            return
        if not hasattr(self, "husk_marks"):
            self.husk_marks = []
        self.husk_marks.append((self.spot(a + s["dirn"] * step * (n // 2) / s["r"], s["y"], s["p"] * 0.5), a, s["biome"]))
        for j in range(n):
            a += s["dirn"] * step / s["r"]
            q = self.spot(a, s["y"], s["p"] * 0.5 + 1.6 * math.sin(j * 0.75) + 0.8)
            tang = np.array([-math.sin(a), 0, math.cos(a)]) * s["dirn"]
            head = j == n - 1
            R.prop(A + ("Monster_Head.glb" if head else "Monster_BodySection.glb"),
                   [q[0], s["y"] + 0.5 * scale, q[2]], yaw=godot_yaw_facing(tang) + rng.uniform(-0.2, 0.2),
                   scale=scale, rot_x=rng.uniform(-0.12, 0.12), snap=False)
            if not head and j % 2 == 0:
                for sgn in (-1, 1):
                    R.prop(A + "Monster_UpperLeg.glb", [q[0], s["y"] + 0.35 * scale, q[2]],
                           yaw=godot_yaw_facing(tang) + sgn * 1.45, scale=scale * 1.3, rot_x=0.5, snap=False)

    # ------------------------------------------------------------ the external kits, per biome
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
                # v49 (#78): the barrel pile gets one hull per barrel, not one box over the whole pile
                sc_ = rng.choice(["ph/wooden_crate_01.glb", "ph/wooden_crate_02.glb", "ph/wooden_barrels_01.glb", "ph/wine_barrel_01.glb"])
                R.xprop(X + sc_, inner(q, a, rng.uniform(1.0, 3.5)) + jit(2.0), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.0, 1.3),
                        col=("hull" if "barrels_01" in sc_ else "box"), dim=0.42)
            for q, a in list(zip(pts, angs))[1::3]:
                R.xprop(X + "ph/wooden_lantern_01.glb", inner(q, a, lip + 1.2), yaw=face_void(a) + math.pi, scale=1.8, dim=0.5)
            if i % 3 == 1:
                R.xprop(X + "ph/lantern_01.glb", inner(pts[-2], angs[-2], 1.0) + jit(1.0), yaw=rng.uniform(0, 6.28), scale=2.2, dim=0.5)
        elif b == OSSUARY:
            # the dead were buried here once, before they were stood in rows
            for q, a in list(zip(pts, angs))[::2]:
                R.xprop(X + rng.choice(["graveyard/gravestone-round.glb", "graveyard/gravestone-cross.glb", "graveyard/gravestone-bevel.glb",
                                        "graveyard/gravestone-broken.glb", "graveyard/gravestone-wide.glb", "graveyard/gravestone-decorative.glb"]),
                        inner(q, a, rng.uniform(back - 3.0, back)) + jit(1.5), yaw=face_void(a) + rng.uniform(-0.4, 0.4), scale=2.4, dim=0.4)
                if rng.random() < 0.5:
                    R.xprop(X + rng.choice(["graveyard/coffin-old.glb", "graveyard/coffin.glb"]), inner(q, a, back - 0.9) + jit(0.6),
                            yaw=face_void(a) + rng.uniform(-0.3, 0.3), scale=2.4, col="box", dim=0.4)
            for q, a in list(zip(pts, angs))[1::2]:
                R.xprop(X + rng.choice(["ph/antique_ceramic_vase_01.glb", "ph/ceramic_pot.glb", "ph/brass_candleholders.glb", "ph/brass_goblets.glb", "quat/Candles_1.glb"]),
                        inner(q, a, rng.uniform(1.0, back)) + jit(2.0), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.4, 2.0), dim=0.5)
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
                R.xprop(X + rng.choice(["ph/tree_stump_01.glb", "ph/tree_stump_02.glb", "ph/dead_tree_trunk_02.glb"]), inner(q, a, rng.uniform(0.0, back)) + jit(2.0),
                        yaw=rng.uniform(0, 6.28), scale=1.2, col="box", dim=0.5)
        elif b == ROOTS:
            # dead trees still stand where roots come through the roof
            for q, a in list(zip(pts, angs))[1::2]:
                R.xprop(X + "quat/DeadTree_%d.glb" % rng.randint(1, 3), inner(q, a, rng.uniform(back - 2.0, back)) + jit(1.5),
                        yaw=rng.uniform(0, 6.28), scale=rng.uniform(2.0, 2.8), dim=0.5)
            if i % 2 == 1:
                q, a = pts[mid], angs[mid]
                R.xprop(X + rng.choice(["ph/dead_tree_trunk_02.glb", "ph/tree_stump_02.glb", "ph/single_root.glb"]), inner(q, a, rng.uniform(0.0, back)) + jit(2.0),
                        yaw=rng.uniform(0, 6.28), scale=1.3, col="box", dim=0.5)
        elif b == DROWNED:
            # what the water left: barrels, a boat, a broken rail along the lip
            for q, a in list(zip(pts, angs))[::2]:
                for k in range(rng.randint(1, 3)):
                    sc_ = rng.choice(["ph/wooden_barrels_01.glb", "ph/wine_barrel_01.glb", "ph/wooden_bucket_02.glb", "ph/ceramic_pot.glb", "quat/Pot1_Broken.glb"])
                    R.xprop(X + sc_, inner(q, a, rng.uniform(0.5, back)) + jit(2.0), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.1, 1.4),
                            col=("hull" if "barrels_01" in sc_ else "box"), dim=0.42)
            if i % 3 == 0:
                q, a = pts[mid], angs[mid]
                R.xprop(X + "nature/canoe.glb", inner(q, a, back - 0.5), yaw=face_void(a) + math.pi * 0.5 + rng.uniform(-0.3, 0.3), scale=3.0, rot_x=rng.uniform(-0.15, 0.15), dim=0.3)
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
                    R.xprop(X + rng.choice(["ph/treasure_chest.glb", "ph/antique_ceramic_vase_01.glb", "ph/ceramic_pot.glb", "ph/planter_pot_clay.glb", "ph/wooden_crate_02.glb"]),
                            inner(q, a, rng.uniform(1.0, back - 1.0)) + jit(1.5), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.1, 1.5), col="box", dim=0.5)
                    if j % 4 == 1:
                        q2 = inner(q, a, rng.uniform(0.5, back - 1.5)) + jit(1.0)
                        R.xprop(X + "ph/wooden_table_02.glb", q2, yaw=rng.uniform(0, 6.28), scale=1.3, col="box", dim=0.5)
                        R.xprop(X + "ph/wooden_stool_02.glb", q2 + jit(1.4), yaw=rng.uniform(0, 6.28), scale=2.0, dim=0.5)
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
                R.xprop(X + rng.choice(["ph/old_military_crate.glb", "ph/wooden_crate_01.glb", "ph/wine_barrel_01.glb", "quat/Bricks.glb", "ph/wooden_bucket_01.glb"]),
                        inner(q, a, rng.uniform(1.0, back - 1.5)) + jit(1.5), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.1, 2.4) if rng.random() < 0.3 else 1.2, col="box", dim=0.45)
            if i % 3 == 0:
                q, a = pts[-2], angs[-2]
                R.xprop(X + "ph/picke_dirty_01.glb", inner(q, a, back) + jit(0.5), yaw=face_void(a), scale=1.6, rot_x=-0.35, dim=0.55)
                R.xprop(X + "quat/BearTrap_Open.glb", inner(q, a, rng.uniform(1.0, back - 2.0)) + jit(1.0), yaw=rng.uniform(0, 6.28), scale=1.4, dim=0.5)
                R.xprop(X + "ph/wooden_ladder.glb", inner(pts[1], angs[1], back + 0.4), yaw=face_void(angs[1]), scale=2.2, rot_x=-0.22, dim=0.5)
                R.xprop(X + rng.choice(["ph/rusted_spade_01.glb", "ph/wooden_axe_02.glb"]), inner(pts[1], angs[1], back + 0.1) + jit(0.8), yaw=face_void(angs[1]) + rng.uniform(-0.5, 0.5), scale=1.5, rot_x=-0.3, dim=0.5)
            if i % 4 == 1:
                q, a = pts[1], angs[1]
                R.xprop(X + rng.choice(["quat/Arch_Gothic.glb", "quat/Support_Tall.glb", "quat/Column_Square.glb"]), inner(q, a, back - 1.5), yaw=face_void(a), scale=1.6, col="box", dim=0.5)
                R.xprop(X + "ph/wooden_table_02.glb", inner(q, a, rng.uniform(1.0, back - 2.0)) + jit(1.0), yaw=rng.uniform(0, 6.28), scale=1.3, col="box", dim=0.5)
                R.xprop(X + "ph/wooden_stool_02.glb", inner(q, a, rng.uniform(1.0, back - 2.0)) + jit(1.5), yaw=rng.uniform(0, 6.28), scale=2.0, dim=0.5)
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
        """The kits on a plateau: boulder fields off the lamp line, and the biome's own furniture."""
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
            ROOTS: (["quat/DeadTree_1.glb", "quat/DeadTree_2.glb", "quat/DeadTree_3.glb", "ph/dead_tree_trunk_02.glb"], 2.4, 8),
            DROWNED: (["quat/Barrel.glb", "quat/Crate.glb", "quat/Column_BridgeSupport.glb", "nature/canoe.glb"], 1.5, 8),
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
                if nm.startswith("ph/"):
                    s_ = rng.uniform(1.1, 1.5)
                R.xprop(X + nm, q, yaw=rng.uniform(0, 6.28), scale=s_, col="box" if not nm.endswith("Skull.glb") else None, dim=0.45)

    def detail(self, s):
        rng, R, L = self.rng, self.R, self.L
        b, y, p, i = s["biome"], s["y"], s["p"], s["i"]
        pts, angs = s["pts"], s["angs"]
        n = len(pts)
        inner = lambda q, a, d=2.5: q + self.out_dir(a) * d
        on = lambda q: [q[0], y, q[2]]

        # 1) what hangs underneath: you see it from the balcony below and from the rope
        for k in range(rng.randint(2, 4)):
            f = rng.uniform(0.06, 0.62)
            a = s["a0"] + (s["a1"] - s["a0"]) * f
            ln = rng.uniform(6.0, 9.0) if b == MOUTH else rng.uniform(9.0, 14.5)
            base = self.spot(a, y - 1.5, rng.uniform(0.3, 0.75) * p)
            self.solids.append(ConeSolid(base, -ln, rng.uniform(3.3, 4.6), rough=0.32,
                                         look=LOOK_BARK if b == ROOTS else None,
                                         lean=(rng.uniform(-0.05, 0.05), rng.uniform(-0.05, 0.05))))

        # 2) carved columns up the back wall: someone built here
        if i % 3 == 0 and b in (MOUTH, OSSUARY, DROWNED, VILLAGE, FOUNDRY) and n >= 4 and not s.get("label"):
            for j in range(0, n - 1, 2):
                a = 0.5 * (angs[j] + angs[j + 1])
                foot = self.spot(a, y - 1.5, 0.3)
                top = self.spot(a, y + rng.uniform(11.0, 16.0), 0.1)
                self.solids.append(RodSolid(foot, top, 1.8, 1.5, rough=0.08))
                self.solids.append(RodSolid(top, top + np.array([0, 1.2, 0]), 2.5, 2.5, rough=0.05))     # capital

        # 3) a rope left hanging where the way down is, in the biomes people reached
        if b in (MOUTH, OSSUARY) and i % 2 == 1:
            lip = self.spot(angs[-1], y, p + 0.35)
            R.prop(A + "Rope_Fallen.glb", [lip[0], y - 10.1, lip[2]], yaw=rng.uniform(0, 6.28), scale=1.0, snap=False)
            R.prop(A + "Fallen_Rope.glb", on(inner(pts[-1], angs[-1], -1.5)), yaw=rng.uniform(0, 6.28), scale=1.6)

        mid = n // 2
        if b == MOUTH:
            if i % 3 == 1:
                R.prop(A + "Player_Corpse.glb", on(inner(pts[-2], angs[-2], -1.0)), yaw=rng.uniform(0, 6.28))
            for q, a in list(zip(pts, angs))[1::2]:
                R.prop(A + "Fallen_Rope.glb", on(q + np.array([rng.uniform(-2, 2), 0, rng.uniform(-2, 2)])), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.2, 2.0))
        elif b == OSSUARY:
            for q, a in list(zip(pts, angs))[::3]:
                R.prop(A + "StoneSphere.glb", [inner(q, a, 3.2)[0], y + 0.25, inner(q, a, 3.2)[2]], yaw=rng.uniform(0, 6.28), scale=rng.uniform(0.3, 0.5), snap=False)
            for k in range(rng.randint(1, 2)):
                j = rng.randrange(1, n - 1)
                R.prop(A + "Woman_Crouching.glb", on(inner(pts[j], angs[j], 0.5) + np.array([rng.uniform(-1, 1), 0, rng.uniform(-1, 1)])),
                       yaw=godot_yaw_facing(self.out_dir(angs[j])), scale=1.0)
        elif b == FUNGAL:
            pass
        elif b == ROOTS:
            R.prop(A + "Tent.glb", on(inner(pts[mid], angs[mid], 2.5)), yaw=rng.uniform(0, 6.28))
            R.prop(A + "Fallen_Rope.glb", on(pts[mid]), yaw=rng.uniform(0, 6.28), scale=1.6)
        elif b == DROWNED:
            if i % 3 == 0:
                sc = rng.uniform(0.5, 0.7)
                q = inner(pts[mid], angs[mid], p * 0.5 - 2.4)
                R.prop(A + "WaterWheel.glb", [q[0], y + 5.85 * sc - 1.4, q[2]], yaw=godot_yaw_facing(self.out_dir(angs[mid])),
                       scale=sc, rot_x=rng.uniform(0.15, 0.3), snap=False)
            for q, a in list(zip(pts, angs))[1::3]:
                R.prop(A + "Sick_Woman.glb", on(inner(q, a, 1.5)), yaw=rng.uniform(0, 6.28))
                R.prop(A + "Fallen_Rope.glb", on(q), yaw=rng.uniform(0, 6.28), scale=1.4)
        elif b == VILLAGE:
            for q, a in list(zip(pts, angs))[2::3]:
                R.prop(A + rng.choice(["Roof_Round.glb", "Roof_Rect.glb"]), on(q + np.array([rng.uniform(-1.5, 1.5), 0, rng.uniform(-1.5, 1.5)])),
                       yaw=rng.uniform(0, 6.28), scale=rng.uniform(0.55, 0.8), rot_x=rng.uniform(-0.2, 0.2))
            if n >= 5:
                R.prop(A + "Building_Rect.glb", on(inner(pts[-2], angs[-2], 2.0)), yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.2, 1.5))
                R.prop(A + "Door.glb", [inner(pts[1], angs[1], 3.0)[0], y + 1.3, inner(pts[1], angs[1], 3.0)[2]], yaw=rng.uniform(0, 6.28), scale=1.4, rot_x=0.35, snap=False)
        elif b == CRYSTAL:
            for q, a in list(zip(pts, angs))[::2]:
                R.intents.append(("crystal", dict(pos=inner(q, a, p * 0.5 - 1.2), s=rng.uniform(3.2, 5.0))))
        elif b == FOUNDRY:
            for q, a in list(zip(pts, angs))[::3]:
                R.prop(A + "Tower_02.glb", [inner(q, a, 2.0)[0], y + 0.4, inner(q, a, 2.0)[2]], yaw=rng.uniform(0, 6.28), scale=rng.uniform(0.9, 1.3), snap=False)
                R.prop(A + "StoneSphere.glb", [q[0] + rng.uniform(-2, 2), y + 0.2, q[2] + rng.uniform(-2, 2)], yaw=rng.uniform(0, 6.28), scale=rng.uniform(0.25, 0.45), snap=False)
        # the dead centipedes: a full body length of husk on most long balconies below the Mouth
        period = {OSSUARY: 3, FUNGAL: 2, ROOTS: 2, DROWNED: 3, VILLAGE: 3, CRYSTAL: 3, FOUNDRY: 3}.get(b)
        if period and s["length"] >= 24 and i % period == 0:
            sc_ = rng.uniform(1.3, 2.1)
            self.husk(s, sc_, min(rng.randint(8, 13), int((s["length"] - 10) / (1.5 * sc_))))

    # ------------------------------------------------------------ leaving and re-entering the rift

    def enter_wall(self, a=None):
        a = self.a if a is None else a
        p = self.spot(a, self.y, 1.0)
        self.R.cursor = np.array([p[0], self.y, p[2]])
        self.R.heading = a
        self.R.landing = None

    def tunnel_to_rift(self, biome, r=5.2, slope=0.10):
        R = self.R
        p0 = np.array(R.cursor, dtype=float)
        cx, cz = self.rift.center(p0[1])
        h = math.atan2(float(cz) - p0[2], float(cx) - p0[0])
        d = hdir(h)
        dist = 0.0
        end = None
        while dist < 600.0:
            dist += 2.0
            q = p0 + d * dist + np.array([0, -slope * dist + 0.55 * r, 0])
            n0, n1, n2 = noise_fields(q[None, :])
            if self.rift.e(q[None, :], n0, n1, n2)[0][0] < -6.0:
                end = dist
                break
        if end is None:
            raise RuntimeError("tunnel_to_rift never reached the rift from %s" % p0)
        a_pt = p0 - d * 7.0 + np.array([0, 0.55 * r, 0])
        b_pt = p0 + d * (end + 5.0) + np.array([0, -slope * (end + 5.0) + 0.55 * r, 0])
        t = Tunnel(biome, a_pt, b_pt, r)
        R.group += 1
        R.prims.append(t)
        R.groups.append(R.group)
        floor_end = b_pt[1] - 0.55 * r
        self.y = float(floor_end)
        self.a = self.rift.bearing(b_pt)
        R.cursor = np.array([b_pt[0], floor_end, b_pt[2]])
        return {"prims": [t], "points": [a_pt, b_pt], "r": r, "biome": biome, "group": R.group}

    def landing(self, biome, label, text=None, length=26.0, checkpoint=True):
        """Where a tunnel opens into the rift: a broad balcony centred on the opening."""
        r = self.rw()
        half = length * 0.5 / r
        self.a -= self.dirn * half
        info = self.shelf(biome, length, p=14.0, decor=True, label=label)
        mid = info["pts"][len(info["pts"]) // 2]
        if checkpoint:
            self.checkpoint(mid, label, biome)
        if text:
            self.R.text(mid, 9.0, text)
        self.tour(mid, mid - self.out_dir(0.5 * (info["a0"] + info["a1"])) * 60 + np.array([0, -25, 0]), label)
        return info

    # ------------------------------------------------------------ spans across the void

    def span(self, biome, drop, half_w, thick, rough, gap=0.0, swing=0.35, look=None):
        """A deck from this wall to the far one. Returns the beam(s); moves the builder across."""
        a0 = self.a
        a1 = a0 + math.pi + self.rng.uniform(-swing, swing)
        p0 = self.spot(a0, self.y, -7.0)
        p1 = self.spot(a1, self.y - drop, -7.0)
        beams = []
        if gap > 0:
            mid = 0.5 * (p0 + p1)
            t = (p1 - p0) / np.linalg.norm(p1 - p0)
            beams.append(BeamSolid(p0, mid - t * gap * 0.5, half_w, thick, rough))
            beams.append(BeamSolid(mid + t * gap * 0.5, p1, half_w, thick, rough))
            self.moves.append({"type": "swing", "gap": gap, "y": self.y - drop * 0.5})
        else:
            beams.append(BeamSolid(p0, p1, half_w, thick, rough))
        for bm_ in beams:
            bm_.look = look
        self.solids.extend(beams)
        self.a = a1 % (2 * math.pi)
        self.y -= drop
        self.moves.append({"type": "span", "length": round(float(np.linalg.norm(p1 - p0)), 0), "drop": drop})
        return p0, p1

    def along(self, p0, p1, f, up=0.0):
        return p0 + (p1 - p0) * f + np.array([0, up, 0])


# ==================================================================== the short way (secret hard routes)

def hard_routes(B):
    """Three hidden ladders. Each starts a gap-jump behind an ordinary balcony, drops a long way
    on footholds half the size of the normal ones, with no ember and no checkpoint, and lands on
    a balcony far below. Whoever reaches the last foothold takes a relic: a cosmetic, for good."""
    R, L, rng, rift = B.R, B.L, B.rng, B.rift
    L["relics"] = []
    L["hard_routes"] = []
    beams = [s_ for s_ in B.solids if isinstance(s_, BeamSolid)]
    main = [(np.array(s_["pos"]), rift.bearing(np.array(s_["pos"]))) for s_ in L["stations"]]
    plats = [np.array(p_["pos"]) for p_ in L["platforms"]]

    def arc_m(a, b, y):
        return abs((a - b + math.pi) % (2 * math.pi) - math.pi) * float(rift.radius(y))

    def column_clear(a_c, y_hi, y_lo, skip=None):
        for (p, a) in main:
            if y_lo + 12 < p[1] < y_hi - 12 and arc_m(a, a_c, p[1]) < 20.0:
                return False
        for t_ in B.terraces:
            if t_ is skip:
                continue
            if y_lo - 5 < t_["y_top"] < y_hi + 5 and t_["solid"].side(rift.point(a_c, t_["y_top"], 4.0)) > -12.0:
                return False
        for bm in beams:
            for f in np.linspace(0, 1, 40):
                q = bm.at(f)
                if y_lo - 10 < q[1] < y_hi + 10 and np.linalg.norm((rift.point(a_c, q[1], 4.0) - q)[[0, 2]]) < 22.0:
                    return False
        for q in plats:
            if y_lo - 10 < q[1] < y_hi + 10 and np.linalg.norm((rift.point(a_c, q[1], 4.0) - q)[[0, 2]]) < 20.0:
                return False
        if y_lo < LID[0] + 40 and y_hi > LID[1] - 20:
            return False
        return True

    # v49 (#2): a secret ladder may skip embers and checkpoints, never something the team was sent
    # down to do. Short Way 2 ran from the Fungal landing past all four kilns and fragment 1, so a
    # solo player landed under the Kiln Gate with nothing lit. Every required objective's height:
    obj_y = [float(a_["y"]) for (k_, a_) in R.intents if k_ in ("kiln", "plate") and a_.get("plinth") is None]
    obj_y += [float(a_["tunnel"]["points"][0][1]) for (k_, a_) in R.intents if k_ == "gate"]
    obj_y += [float(f_["pos"][1]) for f_ in L["fragments"]]

    def skips_objective(y_hi, y_lo):
        return any(y_lo - 6.0 < oy < y_hi for oy in obj_y)

    wanted = [("underdark_relic_1", (OSSUARY, MOUTH)), ("underdark_relic_2", (DROWNED, ROOTS, FUNGAL, VILLAGE)), ("underdark_relic_3", (FOUNDRY, CRYSTAL))]
    used_S = []
    for (rid, biomes) in wanted:
        best = None
        for S in B.shelves:
            if S["biome"] not in biomes or (S.get("label") and S["label"] not in (BIOMES[FUNGAL], BIOMES[DROWNED], "BELOW THE PLATES")) or S["length"] < 20 or any(S is u for u in used_S):
                continue
            if any(abs(S["y"] - u["y"]) < 360.0 for u in used_S):
                continue
            r_s = float(rift.radius(S["y"]))
            for j in range(4):
                # j extra ledges walk the entrance further behind the balcony until a clean line opens below
                a_c = S["a0"] - S["dirn"] * ((8.0 + 8.5 * j) / r_s)
                ledges_ok = True
                for i in range(j + 1):
                    a_i = S["a0"] - S["dirn"] * ((8.0 + 8.5 * i) / r_s)
                    y_i = S["y"] - 3.0 - 2.0 * i
                    if any(abs(p[1] - y_i) < 12.0 and arc_m(a, a_i, y_i) < 13.0 and not (abs(p[1] - S["y"]) < 0.5) for (p, a) in main):
                        ledges_ok = False
                if not ledges_ok:
                    break
                cands = [({"y": t_["y_top"]}, t_, -30.0) for t_ in B.terraces] + [(T, None, 0.0) for T in B.shelves if not T.get("label")]
                for (T, terr, bonus) in cands:
                    span = S["y"] - T["y"]
                    if not (100.0 <= span <= 340.0):
                        continue
                    if skips_objective(S["y"], T["y"]):
                        continue
                    if terr is not None:
                        if terr["solid"].side(rift.point(a_c, terr["y_top"], 4.0)) < 14.0:
                            continue
                    else:
                        lo_a, hi_a = sorted((T["a0"], T["a1"]))
                        mid_a = 0.5 * (lo_a + hi_a)
                        half = 0.5 * (hi_a - lo_a)
                        dd = abs((a_c - mid_a + math.pi) % (2 * math.pi) - math.pi)
                        if dd > half - 6.0 / float(rift.radius(T["y"])):
                            continue
                    if not column_clear(a_c, S["y"] - 2.0 - 2.0 * j, T["y"], skip=terr):
                        continue
                    score = abs(span - 250.0) + bonus + 15.0 * j
                    if best is None or score < best[0]:
                        best = (score, S, T, a_c, j)
        if best is None:
            print("hard route %s: no clean column found, skipped" % rid)
            continue
        used_S.append(best[1])
        j_best = best[4]
        best = best[:4]
        _, S, T, a_c = best
        r_ = float(rift.radius(S["y"]))
        # the way in: small ledges, each a running jump behind the balcony's quiet end
        for i in range(j_best + 1):
            a_i = S["a0"] - S["dirn"] * ((8.0 + 8.5 * i) / r_)
            y = S["y"] - 3.0 - 2.0 * i
            B.solids.append(ShelfSolid(rift, y, a_i, 2.8 / r_, 6.0, thick=3.2))
            entry = B.spot(a_i, y, 3.0)
            B.station(entry, "hard", S["biome"])
            if i > 0:
                B.moves.append({"type": "hop", "gap": 2.9, "dy": 2.0, "y": y, "secret": True})
        L["lanterns"].append({"pos": v3(entry + np.array([0, 2.2, 0])), "color": [0.75, 0.35, 1.0], "s": 0.9})
        L["lights"].append({"pos": v3(entry + np.array([0, 3.0, 0])), "color": [0.7, 0.35, 1.0], "energy": 0.6, "range": 14.0})
        R.text(entry, 4.0, "No ember on this road. No kiln, no light, nothing you were sent down here to find. What you skip, you skip.")
        R.text(S["pts"][0], 5.0, "Scratched into the rock, low down: THE SHORT WAY. Under it someone drew a skull. There is a ledge a running jump past the end of the balcony, and a violet light on it.")
        B.moves.append({"type": "hop", "gap": 3.2, "dy": 3.0, "y": y, "secret": True})
        side = rng.choice([-1, 1])
        n_f = 0
        last = entry
        while y - T["y"] > 24.0:
            rem = y - T["y"]
            dy = rng.uniform(20.0, 22.8) if rem > 47.0 else max(12.0, rem * 0.5)   # split the last two evenly: rem-21 went over the rope at rem 44-47
            y -= dy
            r_ = float(rift.radius(y))
            side = -side
            off = rng.uniform(4.5, 7.5)
            am = a_c + side * (0.5 * off / r_)
            p_ = 5.0 if n_f % 2 == 0 else 6.5
            B.solids.append(ShelfSolid(rift, y, am, 2.5 / r_, p_, thick=3.2))
            q = B.spot(am, y, p_ * 0.5)
            B.station(q, "hard", S["biome"])
            B.moves.append({"type": "drop", "dy": round(dy, 1), "y": y, "hard": True, "secret": True, "side": round(off, 1)})
            if n_f % 3 == 2:
                L["lights"].append({"pos": v3(q + np.array([0, 3.0, 0])), "color": [0.7, 0.35, 1.0], "energy": 0.45, "range": 13.0})
            if n_f >= 1 and rng.random() < 0.4:
                L["droppers"].append({"id": R.next_id("dr"), "kind": "boulder", "hang": v3(B.spot(am, y + dy - 5.0, 1.6)),
                                      "floor": round(float(y), 2), "trip": [v3(q + np.array([0, 1.0, 0])), 3.2]})
            if rng.random() < 0.6:
                R.intents.append(("wall_crumble", dict(a=am + rng.choice([-1, 1]) * rng.uniform(9.0, 13.0) / r_, y=y + rng.uniform(3, 8))))
            last = q
            n_f += 1
        B.moves.append({"type": "drop", "dy": round(y - T["y"], 1), "y": T["y"], "secret": True})
        L["relics"].append({"id": rid, "pos": v3(last + np.array([0, 1.3, 0])), "n": len(L["relics"]) + 1})
        R.text(last, 4.0, "Someone left this here for whoever came the short way. Take it. Then look down: the balcony is one rope below.")
        L["hard_routes"].append({"id": rid, "from_y": round(S["y"], 1), "to_y": round(T["y"], 1), "footholds": n_f, "biome": S["biome"]})
        B.tour(entry, last, "SHORT WAY %d entry" % len(L["relics"]))
        B.tour(last, last + np.array([0, -30, 0]), "SHORT WAY %d relic" % len(L["relics"]))
        main += [(np.array(s_["pos"]), rift.bearing(np.array(s_["pos"]))) for s_ in L["stations"][-(n_f + 1):]]


# ==================================================================== things too big to be scenery

def _ang_diff(a, b):
    return abs((a - b + math.pi) % (2 * math.pi) - math.pi)


def megastructures(B):
    """Landmarks you read from a rift's width away. None of them may touch the route, so each
    one is placed by searching for wall or void that no station comes near."""
    R, L, rng, rift = B.R, B.L, B.rng, B.rift
    st = [(np.array(s_["pos"]), rift.bearing(np.array(s_["pos"]))) for s_ in L["stations"]]
    st += [(np.array(p_["pos"]), rift.bearing(np.array(p_["pos"]))) for p_ in L["platforms"]]

    # ---- THE RIBS: something died here before the rift was dug around it
    found = None
    for n in (9, 7, 5):
        for y0 in np.arange(-350.0 * Z, -600.0 * Z, -15.0):
            Hm = 125.0 if n == 9 else 105.0
            rr = float(rift.radius(y0 - Hm * 0.5))
            half = 0.5 * n * 11.5 / rr
            if any(y0 - Hm - 40 < t_["y_top"] < y0 + 40 for t_ in B.terraces):
                continue
            near = [(p, a) for (p, a) in st if y0 - Hm - 28 < p[1] < y0 + 28]
            for a_mid in np.arange(0, 2 * math.pi, math.radians(4)):
                if all(_ang_diff(a, a_mid) > half + 20.0 / rr for (p, a) in near):
                    found = (n, y0, a_mid, Hm, rr)
                    break
            if found:
                break
        if found:
            break
    L["landmarks"] = []
    if found:
        n, y0, a_mid, Hm, rr = found
        for k in range(n):
            sk = 0.62 + 0.38 * math.sin(math.pi * (k + 0.5) / n)
            a = a_mid + (k - (n - 1) / 2.0) * 11.5 / rr
            Hk, Ak = Hm * sk, 52.0 * sk
            yk = y0 - (1.0 - sk) * 34.0
            pts = []
            for t in np.linspace(0.0, 1.0, 12):
                y = yk - Hk * t
                pts.append(B.spot(a, y, Ak * math.sin(math.pi * t ** 0.8) - 5.0))
            for i in range(len(pts) - 1):
                t = (i + 0.5) / (len(pts) - 1)
                rad = 2.5 + 1.1 * math.sin(math.pi * t)
                B.solids.append(RodSolid(pts[i], pts[i + 1], rad, rad, rough=0.12, look=LOOK_BONE))
            if k % 2 == 0:
                q = B.spot(a, yk - Hk * 0.5, Ak + 9.0)
                L["lights"].append({"pos": v3(q), "color": [0.95, 0.9, 0.75], "energy": 0.55, "range": 70.0})
        mid = B.spot(a_mid, y0 - Hm * 0.5, 30.0)
        L["landmarks"].append({"name": "The Ribs", "pos": v3(mid), "n": n})
        B.tour(B.spot(a_mid + 0.9, y0 - Hm * 0.3, 40.0) - np.array([0, 1.8, 0]), mid, "The Ribs")
        L["tour"][-1]["air"] = True
        # v49 (#51): the nearest station whose text sphere overlaps no other text (the Ribs text sat
        # exactly on the Stalker's warning and hid it)
        def _clear(s_):
            q_ = np.array(s_["pos"]) + np.array([0, 1.5, 0])
            return all(np.linalg.norm(q_ - np.array(t_["pos"])) >= 9.0 + float(t_["r"]) for t_ in L["texts"])
        band_ = [s_ for s_ in L["stations"] if abs(s_["pos"][1] - (y0 - Hm * 0.5)) < 90 and s_["kind"] != "hard"]
        near_st = min((s_ for s_ in band_ if _clear(s_)), default=None, key=lambda s_: np.linalg.norm(np.array(s_["pos"]) - mid))
        if near_st is not None:
            R.text(np.array(near_st["pos"]), 9.0, "Ribs. Each one longer than a street, grown into the wall. Whatever it was, it died before anyone dug here. The rift was cut around it.")

    # ---- THE CHANDELIER: the underside of the Lid hangs into the Fungal Hollow
    y_base = LID[1] + 5.0
    cx, cz = rift.center(y_base)
    Rr = float(rift.radius(y_base - 40))
    made = 0
    for k in range(18):
        rk = 0.6 * Rr * math.sqrt((k + 0.5) / 18.0)
        ak = k * 2.399963
        ln = 150.0 - 105.0 * (rk / (0.6 * Rr)) + rng.uniform(-14, 14)
        r0 = 7.0 + ln / 13.0
        base = np.array([float(cx) + math.cos(ak) * rk, y_base, float(cz) + math.sin(ak) * rk])
        if any(np.hypot(p[0] - base[0], p[2] - base[2]) < r0 + 14 and y_base - ln - 12 < p[1] < y_base for (p, a) in st):
            continue
        cone = ConeSolid(base, -ln, r0, rough=0.34, lean=(rng.uniform(-0.04, 0.04), rng.uniform(-0.04, 0.04)))
        B.solids.append(cone)
        tip = cone.tip()
        made += 1
        if k % 2 == 0:
            L["lights"].append({"pos": v3(tip + np.array([0, -7.0, 0])), "color": [0.35, 1.0, 0.7], "energy": 0.6, "range": 62.0})
            L["lanterns"].append({"pos": v3(tip + np.array([0, -2.5, 0])), "color": [0.35, 1.0, 0.7], "s": 3.4})
    L["landmarks"].append({"name": "The Chandelier", "pos": v3([float(cx), y_base - 80, float(cz)]), "n": made})
    B.tour(B.spot(1.0, y_base - 120.0, 22.0) - np.array([0, 1.8, 0]), [float(cx), y_base - 60.0, float(cz)], "The Chandelier")
    L["tour"][-1]["air"] = True

    # ---- THE NEEDLES: spires standing out of the lava lake
    cx, cz = rift.center(LAKE_Y)
    Rr = float(rift.radius(LAKE_Y))
    p0, p1 = getattr(B, "crucible", (None, None))
    made = 0
    for k in range(16):
        rk = Rr * (0.14 + 0.6 * math.sqrt((k + 0.5) / 16.0))
        ak = 0.7 + k * 2.399963
        h = rng.uniform(55, 150)
        r0 = 9.0 + h / 11.0
        base = np.array([float(cx) + math.cos(ak) * rk, LAKE_Y - 7.0, float(cz) + math.sin(ak) * rk])
        if p0 is not None:
            ab = (p1 - p0)[[0, 2]]
            ap = base[[0, 2]] - p0[[0, 2]]
            tt = np.clip(ap @ ab / float(ab @ ab), 0, 1)
            if np.linalg.norm(ap - ab * tt) < r0 + 28.0:
                continue
        if any(np.hypot(p[0] - base[0], p[2] - base[2]) < r0 + 18 and p[1] < LAKE_Y + h + 30 for (p, a) in st):
            continue
        cone = ConeSolid(base, h, r0, rough=0.3, lean=(rng.uniform(-0.06, 0.06), rng.uniform(-0.06, 0.06)))
        B.solids.append(cone)
        made += 1
    L["landmarks"].append({"name": "The Needles", "pos": v3([float(cx), LAKE_Y + 60, float(cz)]), "n": made})


# ==================================================================== strata that match the route

def align_strata(B):
    """v49 (#22): the strata were fixed numbers, and the route has moved under them: the Drowned
    Galleries started 175 m inside the Rootworks stratum, so the HUD, fog, music and rock colour all
    switched in the wrong place. Each boundary is now put at the first balcony of the lower biome
    (the runtime shifts it 8 m up, so the HUD switches just above that balcony), as long as the
    upper biome's last stand point is at least 10 m above it. The Ossuary/Fungal boundary stays
    where it is: it sits above the Lid, and the rock under the Lid belongs to the Fungal Hollow."""
    L, rift = B.L, B.rift
    st = [s_ for s_ in L["stations"] if s_["kind"] != "hard"]
    new = [list(t_) for t_ in rift.strata]
    for k in range(1, len(new)):
        lower, upper = new[k][2], new[k - 1][2]
        if lower == FUNGAL:
            continue
        first = next((i for i, s_ in enumerate(st) if s_["biome"] == lower), None)
        if first is None or first == 0:
            continue
        prev = [s_ for s_ in st[:first] if s_["biome"] == upper]
        if not prev:
            continue
        y_first = float(st[first]["pos"][1])
        y_last = float(prev[-1]["pos"][1])
        y_b = y_first if y_last - y_first >= 10.0 else 0.5 * (y_last + y_first) - 4.0
        if not (new[k][1] < y_b < new[k - 1][0]):
            continue                                      # never swallow a whole stratum
        new[k - 1][1] = round(y_b, 1)
        new[k][0] = round(y_b, 1)
    rift.strata = [tuple(t_) for t_ in new]
    L["strata"] = [{"top": t_, "bottom": b_, "biome": bi_} for (t_, b_, bi_) in rift.strata]


# ==================================================================== the descent

def nest_dress(R, L, n1, altar, rng):
    """The Nest is where they come from: egg clusters glow along the walls and thicken around the
    altar, and whoever built the altar left its temple: a ring of columns, an arch on the approach."""
    d, s = n1.d, n1.s
    rx, rz = float(n1.r[0]), float(n1.r[2])
    fy = n1.floor_y
    for i in range(26):
        lx = rng.uniform(-0.8, 0.8) * rx
        lz = rng.choice([-1, 1]) * rng.uniform(0.55, 0.88) * rz
        p = n1.world_point(lx, lz, fy)
        R.egg(p, rng.randint(4, 9), rng.uniform(0.55, 1.0))
        if i % 3 == 0:
            L["lights"].append({"pos": v3(p + np.array([0, 1.6, 0])), "color": [0.45, 0.95, 0.35], "energy": 0.5, "range": 11.0})
    for i in range(9):                                   # thick around the altar
        ang = i * 0.7 + rng.uniform(-0.2, 0.2)
        p = altar + (d * math.cos(ang) + s * math.sin(ang)) * rng.uniform(4.5, 9.0)
        R.egg(p, rng.randint(6, 11), rng.uniform(0.7, 1.15))
        if i % 3 == 1:
            L["lights"].append({"pos": v3(p + np.array([0, 1.8, 0])), "color": [0.45, 0.95, 0.35], "energy": 0.6, "range": 12.0})
    for i in range(8):                                   # the temple ring
        ang = i * math.pi / 4 + math.pi / 8
        p = altar + (d * math.cos(ang) + s * math.sin(ang)) * 11.0
        R.xprop(X + ("quat/Column_Round.glb" if i % 2 == 0 else "quat/Column_Round_Short.glb"), p, yaw=rng.uniform(0, 6.28), scale=2.1, col="box", dim=0.35)
    for k in (-1, 1):
        R.xprop(X + "quat/Arch_Round.glb", altar - d * 17.0 + s * k * 6.5, yaw=godot_yaw_facing(d), scale=1.9, dim=0.35)
    # v49 (#34): the broken walls stand 9.5 m off the axis (were 4.5): their box collision made an
    # invisible wall across the idol run. The inner edges now sit ~5.7 m to each side of the altar-to-
    # exit line (which passes ~1.9 m off the axis here), so they frame the run instead of blocking it.
    for k in (-1, 1):
        R.xprop(X + "quat/Wall_ArchRound_Broken.glb", altar + d * 9.0 + s * k * 9.5, yaw=godot_yaw_facing(-d), scale=1.9, col="box", dim=0.35)
    R.xprop(X + "quat/Stairs.glb", altar - d * 6.0, yaw=godot_yaw_facing(d), scale=1.6, dim=0.35)
    for i in range(14):
        ang = rng.uniform(0, 6.28)
        p = altar + (d * math.cos(ang) + s * math.sin(ang)) * rng.uniform(2.6, 4.2)
        R.xprop(X + ("quat/Skull.glb" if i % 3 else rng.choice(["quat/Candles_1.glb", "quat/Candles_2.glb"])), p,
                yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.0, 1.3), rot_x=rng.uniform(-0.4, 0.4), dim=0.4)
    L["tour"].append({"pos": v3(altar - d * 22.0 + np.array([0, 4.0, 0])), "look": v3(altar + np.array([0, 2.0, 0])), "label": "nest altar", "air": True})
    L["tour"].append({"pos": v3(altar + s * 7.0 - d * 2.0 + np.array([0, 1.7, 0])), "look": v3(altar + s * 7.0 + d * 6.0 + np.array([0, 0.4, 0])), "label": "nest eggs", "air": True})
    L["tour"].append({"pos": v3(n1.world_point(0.1 * rx, 0.45 * rz, fy + 1.7)), "look": v3(n1.world_point(0.25 * rx, 0.8 * rz, fy + 0.5)), "label": "nest wall eggs", "air": True})


def build(seed):
    B = Builder(seed)
    R, L, rng, rift = B.R, B.L, B.rng, B.rift

    # ---------------------------------------------------------------- 0 THE MOUTH
    R.bowl((0.0, 0.0, 0.0), 58.0)
    L["start"] = {"pos": v3([-30.0, 2.6, 6.0]), "yaw": godot_yaw_facing(np.array([1.0, 0.0, 0.0]))}
    R.prop(A + "Tent.glb", [-36, 0, 12], yaw=0.6)
    R.prop(A + "Tent.glb", [-40, 0, 2], yaw=-0.3)
    R.fire([-31, 0, 1], 0.8, energy=1.8, rng=28)
    R.intents.append(("ember", dict(pos=np.array([-28.0, 0, 11.0]))))
    for p in ([-20, 0, 20], [-8, 0, -26], [18, 0, 30]):
        R.prop(rng.choice(CORPSES), p, yaw=rng.uniform(0, 6.28))
    R.text([-30, 0, 6], 9.0, "A long way down. She said the idol is at the bottom. You believed her.")
    R.text([38, 0, 0], 8.0, "The mouth of it. Land a fall of forty metres and you will not get up. Shorter falls still break you. Let the rope out.")
    for k in range(20):
        a = k / 20.0 * 2 * math.pi
        L["barriers"].append({"pos": v3([math.cos(a) * 92, 60, math.sin(a) * 92]), "size": [32.0, 120.0, 4.0],
                              "yaw": godot_yaw_facing(np.array([math.cos(a), 0, math.sin(a)]))})
    R.cursor = np.array([40.0, 0.0, 0.0])
    R.heading = 0.0
    R.group = R.bowl_group
    t = R.tunnel(MOUTH, [(45, 12, 0), (45, 14, 25), (40, 12, -15)], r=7.0)
    R.light(t["points"][1], [1.0, 0.8, 0.55], 0.8, 18)
    m1 = R.chamber(MOUTH, 36, 16, 28, name="Mouth Hall")
    R.feature(m1, "lore")
    R.ceiling_spikes(m1, 6)
    B.tunnel_to_rift(MOUTH, r=6.5, slope=0.16)
    rift_info = B.landing(MOUTH, "THE RIFT", "The rock ends. Beyond the lip there is no far wall you can see, and no floor. It goes down further than the light does.")
    # THE FOLLOWER: it comes in behind you at the top and hunts the team all the way down
    L["centipedes"].append({"id": "follower", "follower": True, "trigger": [v3(rift_info["pts"][len(rift_info["pts"]) // 2]), 12.0],
                            "spawn": [v3(m1.arrival + np.array([0, 3.0, 0]))]})
    lobe = B.under(17.0, switchback=False)
    B.run(MOUTH, -330 * Z, chain_every=2, chain_n=(3, 5), len_rng=(34, 64), dy_rng=(15.0, 19.5), gap_chance=0.25, terraces=(-185 * Z,))

    # ---------------------------------------------------------------- 1 OSSUARY
    info = B.shelf(OSSUARY, 44, lobe_p=17.0, label="OSSUARY")
    B.checkpoint(info["pts"][1], BIOMES[OSSUARY], OSSUARY)
    R.text(info["pts"][1], 9.0, "Someone laid them here. Rows of them, standing, facing the dark. You do not look at the faces.")
    B.tour(info["pts"][1], info["pts"][-1], "Ossuary terraces")
    B.under(18.0)
    B.run(OSSUARY, -540 * Z, terraces=(-430 * Z,))
    # the Span: a broken rock bridge to the far wall, and the bell on its gallows
    info = B.shelf(OSSUARY, 30, lobe_p=17.0, p=14.0)
    R.text(info["pts"][-1], 8.0, "A bridge of fallen stone, broken in the middle. The far side is a hook's throw away.")
    p0, p1 = B.span(OSSUARY, 14.0, 5.0, 9.0, 0.3, gap=10.0)
    B.tour(B.along(p0, p1, 0.1), B.along(p0, p1, 0.9), "The Span")
    for f in (0.2, 0.42, 0.58, 0.8):
        L["lights"].append({"pos": v3(B.along(p0, p1, f, 5.0)), "color": GLOW[OSSUARY], "energy": 1.1, "range": 30.0})
    for f in (0.15, 0.3, 0.7, 0.85):
        R.prop(rng.choice(STANDING), B.along(p0, p1, f, 0.0), yaw=rng.uniform(0, 6.28))
    info = B.landing(OSSUARY, "THE FAR WALL", None, checkpoint=True)
    # v49 (#39): the home was 40 m under the middle of the Span, in open air, so the stalker snapped
    # back to it on every step and never moved. It now coils on real rock: the quiet end of this
    # landing (the way on leaves by the other end), 11 m from the checkpoint in the middle.
    stalk_home = info["pts"][0] + np.array([0, 1.0, 0])
    gal_a = 0.5 * (info["a0"] + info["a1"])
    g0 = B.spot(gal_a, B.y + 15.0, -6.0)
    g1 = B.spot(gal_a, B.y + 15.0, 19.0)
    B.solids.append(BeamSolid(g0, g1, 2.2, 3.5, 0.3))
    bell_pos = g1 + np.array([0, -8.0, 0]) - B.out_dir(gal_a) * 1.0
    R.intents.append(("bell", dict(x=float(bell_pos[0]), z=float(bell_pos[2]), y=B.y, scale=2.6, hang=float(bell_pos[1]), ceiling=float(g1[1] - 3.5))))
    R.text(info["pts"][len(info["pts"]) // 2], 8.0, "A bell on a stone gallows, hung by the miners. Throw your hook at it. Anything hunting will come to the sound instead of to you.")
    cz = [[v3(np.array([float(rift.center(yy)[0]), yy, float(rift.center(yy)[1])])), 270.0] for yy in (-380 * Z, -480 * Z, -580 * Z, -680 * Z, -750 * Z)]
    L["stalkers"].append({"id": "stalker1", "home": v3(stalk_home), "zone": cz, "speed": 33.0})
    R.text(info["pts"][0], 8.0, "Something pale is coiled at the end of this ledge. It does not move while you watch it. Do not look away for long.")
    L["centipedes"].append({"id": R.next_id("cen"), "trigger": [v3(info["pts"][-1]), 9.0], "spawn": [v3(B.spot(B.a + 0.5, B.y + 10, 3.0))]})
    B.under(17.0)
    B.run(OSSUARY, -748.0 * Z, terraces=(-640 * Z,))
    # the Lid seals the rift; the only way on is through the rock
    info = B.shelf(OSSUARY, 40, lobe_p=17.0, p=13.0, label="THE LID")
    R.text(info["pts"][1], 9.0, "Below you the rift is plugged, wall to wall, by one fallen slab the size of a town. There is no way through it. There are holes in the wall.")
    B.tour(info["pts"][1], info["pts"][1] + np.array([0, -30, 0]) - B.out_dir(B.a) * 80, "The Lid")
    B.solids.append(PlugSolid(rift, LID[0], LID[1]))
    B.enter_wall()

    # ---------------------------------------------------------------- 9 THE BURROWS
    t = R.tunnel(OSSUARY, [(32, 5, 15)], r=4.4)
    bm = R.chamber(BURROWS, 15, 8, 13, amp=(1.6, 1.0, 0.4), name="Burrow Mouth")
    B.checkpoint(bm.arrival + bm.d * 5.0, "THE BURROWS", BURROWS)
    R.text(bm.arrival, 7.0, "Three holes, low in the wall. One goes through. You will have to crawl.")
    R.scatter_floor(bm, 4, lambda p: R.prop(rng.choice(CORPSES), p, yaw=rng.uniform(0, 6.28)), min_r=0.3)
    R.scatter_floor(bm, 14, lambda p: R.xprop(X + rng.choice(["quat/Skull.glb", "quat/Skull.glb", "ph/rock_07.glb", "ph/rock_09.glb"]), p,
                                              yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.0, 1.4) if rng.random() < 0.5 else rng.uniform(3.0, 6.0), rot_x=rng.uniform(-0.4, 0.4), dim=0.4), min_r=0.2)
    L["ambience"].append({"pos": v3([bm.c[0], bm.floor_y + 2, bm.c[2]]), "sounds": WHISPERS, "min": 9.0, "max": 20.0, "range": 24.0, "db": -4.0})
    R.tube(bm, 0.0, [(14, 0, 2, 1.55), (10, -35, 4, 1.4), (9, 45, 5, 1.25), (0, 0, 9, 1.3), (11, -50, 5, 1.5), (14, 30, 6, 1.28),
                     (0, 0, 10, 1.3), (12, -40, 5, 1.6), (0, 0, 9, 1.3), (10, 25, 4, 1.25), (14, 10, 3, 1.7)],
           r0=1.55, true_route=True, name="the way through",
           decor=dict(candles=13.0, texts=[(6.0, "Barely wider than your shoulders. You go in on your hands and knees."),
                                           (52.0, "It narrows. Breathe out and push."),
                                           (96.0, "Somewhere above you is the weight of the Lid. You try not to think about it.")],
                      ambience=[30.0, 70.0, 110.0], bones=9.0, roots=7.0, husk=True))
    R.tube(bm, math.radians(100), [(10, 0, 0, 1.5), (12, -55, 2, 1.35), (9, -40, 1, 1.25), (5, 0, 0, 1.6)],
           r0=1.5, name="dead end A", decor=dict(end_corpse=True, end_ember=True, end_text="It ends. Someone got this far and stopped. Back out, feet first.", bones=6.0, roots=9.0))
    R.tube(bm, math.radians(-118), [(14, 0, 1, 1.5), (0, 0, 6, 1.3), (10, -60, 1, 1.3), (8, 30, 0, 2.2)],
           r0=1.5, name="dead end B", decor=dict(end_corpse=True, end_corpses=4, end_text="A pocket of bones. No way on. The hole you dropped through is above you.", bones=4.0, roots=8.0))
    br = R.chamber(BURROWS, 13, 9, 12, amp=(1.6, 1.0, 0.4), name="Breathing Room")
    R.text(br.arrival, 6.0, "You can stand. Your knees are bleeding. Somewhere ahead, green light.")
    R.scatter_floor(br, 12, lambda p: R.xprop(X + rng.choice(["quat/Skull.glb", "ph/rock_07.glb", "ph/tree_stump_02.glb", "ph/single_root.glb"]), p,
                                              yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.0, 1.5), rot_x=rng.uniform(-0.3, 0.3), dim=0.45), min_r=0.2)
    R.feature(br, "lore")
    R.tunnel(FUNGAL, [(34, 5, 95), (34, 5, 85)], r=5.0)
    B.tunnel_to_rift(FUNGAL, r=5.5, slope=0.08)

    # ---------------------------------------------------------------- 2 FUNGAL HOLLOW
    info = B.landing(FUNGAL, BIOMES[FUNGAL], "Under the Lid the rift opens wider than before, and the walls glow. Three pieces of the idol were hidden in the deep. The foundry door wants all three.")
    gate_k = "gate_kilns"
    kiln_i = 0
    lobe = B.under(10.0, switchback=False)
    y_f_end = -1150.0 * Z
    step = 0
    fungal_shelf = False
    while B.y > y_f_end + 20:
        if not fungal_shelf and B.y < -1000.0 * Z:
            fungal_shelf = True
            info = B.shelf(FUNGAL, 22, p=12.0)
            lobe_t = B.terrace(FUNGAL)
            info = B.shelf(FUNGAL, 26, p=13.0, lobe_p=lobe_t)
            B.y -= 10.0
            B.a += B.dirn * (5.0 / info["r"])
            B.moves.append({"type": "hop", "dy": 10.0, "y": B.y})
        # bracket fungus: many small round shelves, close together, a hopping descent
        Ls = rng.uniform(13, 20)
        info = B.shelf(FUNGAL, Ls, p=rng.uniform(10, 14), lobe_p=None)
        step += 1
        if step in (3, 9, 15, 21) and kiln_i < 4:
            # a kiln on a bracket of its own, off the path: swing out to it and back
            side_a = info["a0"] - B.dirn * (11.0 / info["r"])
            B.solids.append(ShelfSolid(rift, B.y + 3.0, side_a - B.dirn * (5.0 / info["r"]), 5.5 / info["r"], 11.0, thick=3.5))
            kp = B.spot(side_a - B.dirn * (5.0 / info["r"]), B.y + 3.0, 5.0)
            R.intents.append(("kiln", dict(gate=gate_k, idx=kiln_i, x=float(kp[0]), z=float(kp[2]), y=float(kp[1]) + 4, plinth=None)))
            L["lights"].append({"pos": v3(kp + np.array([0, 4, 0])), "color": [1.0, 0.55, 0.2], "energy": 0.8, "range": 20.0})
            if kiln_i == 0:
                # v49 (#2): the instruction sits at the first kiln, not 200-375 m lower at the gate
                R.text(info["pts"][0], 7.0, "A kiln, cold, on a bracket of its own off the path. There are four on the way down. Light them all, or the door at the bottom will not open.")
            kiln_i += 1
        if step == 12:
            # fragment 1: a side passage behind the glowing brackets
            B.enter_wall(0.5 * (info["a0"] + info["a1"]))
            R.tunnel(FUNGAL, [(42, 3, 20)], r=4.8)
            fr = R.chamber(FUNGAL, 14, 9, 14, amp=(1.5, 1.2, 0.5), name="Spore Vault")
            L["fragments"].append({"id": "frag1", "pos": v3(np.array([fr.c[0], fr.floor_y + 1.4, fr.c[2]]))})
            R.light([fr.c[0], fr.floor_y, fr.c[2]], [0.6, 0.9, 1.0], 1.2, 18, lift=3)
            R.scatter_floor(fr, 20, lambda p: R.prop(rng.choice(PLANTS_L), p, yaw=rng.uniform(0, 6.28), scale=rng.uniform(2.5, 5.0)))
            R.text(info["pts"][len(info["pts"]) // 2], 6.0, "A passage behind the brackets. Something glints inside.")
        dy = rng.uniform(8.0, 12.5)
        B.y -= dy
        B.a += B.dirn * (rng.uniform(3.0, 6.5) / info["r"])          # a short gap to the next bracket
        B.moves.append({"type": "hop", "dy": round(dy, 1), "y": B.y})
        if step % 7 == 0:
            B.dirn *= -1
    R.text(B.spot(B.a, B.y + 12, 5.0), 9.0, "The door below wants all four kilns lit.")
    info = B.shelf(FUNGAL, 34, p=13.0, label="KILN GATE")
    B.enter_wall(0.5 * (info["a0"] + info["a1"]))
    t = R.tunnel(FUNGAL, [(40, 9, 70), (40, 9, 80)], r=5.5)
    R.intents.append(("gate", dict(id=gate_k, kind="kilns", need=4, tunnel=t, dist=12.0)))
    B.tunnel_to_rift(ROOTS, r=5.5, slope=0.12)

    # ---------------------------------------------------------------- 3 ROOTWORKS
    info = B.landing(ROOTS, BIOMES[ROOTS], "Roots of something that should not be this deep. They cross the whole rift, wall to wall, thick as streets. You will have to walk them.")
    for k in range(4):
        q0 = B.spot(B.a, B.y, 5.0)
        # v48: roots 1 and 3 (k 0 and 2, no ambush on them) have split in the middle: a ~10 m
        # swing to the far half. The centipede roots (k 1 and 3) stay one continuous deck.
        gap_k = 10.0 if k in (0, 2) else 0.0
        p0, p1 = B.span(ROOTS, rng.uniform(68, 80), 4.6, 8.5, 0.55, gap=gap_k, swing=0.5, look=LOOK_BARK)
        B.tour(B.along(p0, p1, 0.12), B.along(p0, p1, 0.8), "Root %d" % (k + 1))
        # both deck halves are places you stand: the validator checks there is floor there
        B.station(B.along(p0, p1, 0.1), "span", ROOTS)
        B.station(B.along(p0, p1, 0.9), "span", ROOTS)
        for f in (0.1, 0.3, 0.5, 0.7, 0.9):
            L["lights"].append({"pos": v3(B.along(p0, p1, f, 4.0)), "color": GLOW[ROOTS], "energy": 0.9, "range": 24.0})
        for f in (0.22, 0.55, 0.78):
            R.prop(A + "Roots.glb", B.along(p0, p1, f, 0.0), yaw=rng.uniform(0, 6.28), scale=rng.uniform(0.5, 0.9), snap=False)
        t_dir = (p1 - p0) / np.linalg.norm(p1 - p0)
        side = np.cross(np.array([0, 1.0, 0]), t_dir)
        side = side / np.linalg.norm(side)
        # v48: the root reads as a root, not a bare beam. Every 18-25 m a tangle of the game's own
        # roots (Roots.glb, 552 triangles) hangs off alternating deck edges, its body outside the
        # 9.2 m deck so the walking lane stays clear. Its long axis runs along the root.
        span_m = float(np.linalg.norm((p1 - p0)[[0, 2]]))
        gap_f = (0.5 * gap_k + 3.0) / span_m if gap_k > 0 else -1.0
        s_m = rng.uniform(6.0, 12.0)
        sgn = rng.choice([-1, 1])
        while s_m < span_m - 8.0:
            f_ = s_m / span_m
            if abs(f_ - 0.5) > gap_f:
                o_ = side * sgn
                sc_ = rng.uniform(0.8, 1.2)
                q_ = B.along(p0, p1, f_, -0.6) + o_ * (4.9 + 1.55 * sc_)
                R.prop(A + "Roots.glb", q_, yaw=math.atan2(o_[2], -o_[0]) + rng.uniform(-0.15, 0.15), scale=sc_,
                       rot_x=rng.uniform(-0.12, 0.12), snap=False)
                sgn = -sgn
            s_m += rng.uniform(18.0, 25.0)
        if gap_k > 0:
            R.text(B.along(p0, p1, 0.5 - gap_f), 7.0, "The root has split. The far half is a hook's throw away.")
        # a thin side root that ends in mid-air, with something worth the risk at its tip
        if gap_k > 0:
            f = rng.uniform(0.30, 0.42) if rng.random() < 0.5 else rng.uniform(0.58, 0.66)       # never inside the split
        else:
            f = rng.uniform(0.35, 0.6)
        base = B.along(p0, p1, f)
        tip = base + side * rng.choice([-1, 1]) * rng.uniform(24, 34) + np.array([0, -5.0, 0])
        B.solids.append(BeamSolid(base, tip, 1.5, 2.6, 0.4))
        B.solids[-1].look = LOOK_BARK
        L["embers"].append({"pos": v3(tip + np.array([0, 1.3, 0]) - (tip - base) / np.linalg.norm(tip - base) * 2.0)})
        if k in (1, 3):
            L["centipedes"].append({"id": R.next_id("cen"), "trigger": [v3(B.along(p0, p1, 0.45, 1.5)), 9.0],
                                    "spawn": [v3(B.along(p0, p1, 0.95, 3.0))]})
            R.text(B.along(p0, p1, 0.4), 7.0, "The root is moving under your feet. No. Something is moving along it.")
        info = B.shelf(ROOTS, rng.uniform(24, 36), p=14.0, label="root landing")
        if k == 1:
            B.checkpoint(info["pts"][1], "ROOTWORKS, MIDWAY", ROOTS)
        if k < 3:
            B.under(rng.uniform(15, 19), switchback=True)
    B.under(18.0)

    # ---------------------------------------------------------------- 4 DROWNED GALLERIES
    info = B.shelf(DROWNED, 46, lobe_p=18.0, label=BIOMES[DROWNED])
    B.checkpoint(info["pts"][1], BIOMES[DROWNED], DROWNED)
    R.text(info["pts"][1], 9.0, "The water left. The mist stayed, and the falls still pour out of the walls into nothing. They will push you off if you let them.")
    B.tour(info["pts"][1], info["pts"][-1], "Drowned Galleries")
    B.under(17.0)
    B.run(DROWNED, -1760 * Z, terraces=(-1660 * Z,))
    L["centipedes"].append({"id": R.next_id("cen"), "trigger": [v3(B.spot(B.a, B.y, 5.0)), 10.0], "spawn": [v3(B.spot(B.a + B.dirn * 0.5, B.y + 8, 3.0))]})
    info = B.shelf(DROWNED, 36, lobe_p=17.0, p=13.0, label="PLATE HALL")
    B.enter_wall(0.5 * (info["a0"] + info["a1"]))
    R.tunnel(DROWNED, [(45, 6, -15)], r=5.5)
    d2 = R.chamber(DROWNED, 44, 22, 44, name="Plate Hall")
    B.checkpoint(d2.arrival + d2.d * 5.0, "PLATE HALL", DROWNED)
    gate_p = "gate_plates"
    R.text(d2.arrival, 9.0, "Four plates. Everyone stands on one. Alone, the door will not wait for you.")
    for idx, spot in enumerate([("floor", 0.0, 0.0), ("floor", 0.35, 0.62), ("wall", math.radians(-110), 6.5), ("wall", math.radians(115), 8.0)]):
        if spot[0] == "floor":
            p = d2.world_point(spot[1] * d2.r[0], spot[2] * d2.r[2], d2.floor_y)
            R.intents.append(("plate", dict(gate=gate_p, idx=idx, x=p[0], z=p[2], y=d2.floor_y + 4, plinth=None)))
        else:
            key = R.plinth(d2, spot[1], spot[2])
            R.intents.append(("plate", dict(gate=gate_p, idx=idx, plinth=key)))
    # v49 (#20): the exit used to turn a flat 180 degrees and come out straight under the PLATE HALL
    # balcony, 36 m down: one rappel and a survivable fall skipped the co-op door. A long leg along
    # the wall now carries it well round the rift first, the way the route goes on (away from the
    # balcony, so no later stand point lies under it). Same total drop as before, 16 m.
    t = R.tunnel(DROWNED, [(40, 5, -95), (75, 3, 0), (40, 8, -85)], r=5.5)
    R.intents.append(("gate", dict(id=gate_p, kind="plates", need=0, tunnel=t, dist=10.0)))
    B.tunnel_to_rift(DROWNED, r=5.5, slope=0.1)
    info = B.landing(DROWNED, "BELOW THE PLATES", "The pale thing is down here too, coiled at the end of this ledge. It only moves while nobody is looking at it. Keep your eyes on it.")
    sz = [[v3(np.array([float(rift.center(yy)[0]), yy, float(rift.center(yy)[1])])), 270.0] for yy in (-1620 * Z, -1720 * Z, -1820 * Z, -1920 * Z)]
    # v49 (#39): its home was a point 30 m under the far side of the rift with no floor within 45 m,
    # so it snapped back there on every step and never hunted. It now coils on this landing's quiet
    # end, like the first one (gen.py puts the home 1 m over the real rock there).
    L["stalkers"].append({"id": "stalker2", "home": v3(info["pts"][0] + np.array([0, 1.0, 0])), "zone": sz, "speed": 36.0})
    B.under(17.0)
    # THE PLUNGE: the longest stretch with no balcony at all
    info = B.shelf(DROWNED, 30, lobe_p=17.0, label="THE PLUNGE")
    B.checkpoint(info["pts"][1], "THE PLUNGE", DROWNED)
    R.text(info["pts"][-1], 8.0, "The galleries end. For the next two hundred metres there is only wet wall and what your hook can find on it. Do not rush it.")
    B.tour(info["pts"][-1], info["pts"][-1] + np.array([0, -60, 0]) - B.out_dir(B.a) * 12, "The Plunge")
    B.chain(DROWNED, 12, above=info["pts"][-1])
    B.under(18.0, switchback=False)
    B.run(DROWNED, -1965 * Z, terraces=(-1890 * Z,))

    # ---------------------------------------------------------------- 5 SUNKEN VILLAGE
    info = B.shelf(VILLAGE, 50, lobe_p=18.0, p=14.0, label=BIOMES[VILLAGE])
    B.checkpoint(info["pts"][1], BIOMES[VILLAGE], VILLAGE)
    R.text(info["pts"][1], 10.0, "A whole village fell into the dark and caught on its own chains. The houses hang out there over nothing, lamps still lit. The way on is across them.")
    B.tour(info["pts"][1], info["pts"][1] - B.out_dir(B.a) * 100 + np.array([0, -30, 0]), "Hanging Village")
    frag2_done = False
    for cross in range(2):
        # an archipelago of hanging platforms, wall to wall
        a0 = B.a
        a1 = a0 + math.pi + rng.uniform(-0.4, 0.4)
        n = 22
        # v48: the second crossing follows run(), whose last step-down builds no floor, so the first
        # house hung 28 m below the last balcony. Start the line no more than 12 m under the last
        # place you stood (the first house then sits within one rope of it).
        y_last = float(L["stations"][-1]["pos"][1])
        start = B.spot(a0, max(B.y, y_last - 12.0), 12.0)
        end = B.spot(a1, B.y - 150.0, 12.0)
        prev = start
        for k in range(1, n + 1):
            f = k / (n + 1.0)
            base = start + (end - start) * f
            t_dir = (end - start) / np.linalg.norm(end - start)
            side = np.cross(np.array([0, 1.0, 0]), t_dir)
            pos = base + side * rng.uniform(-5, 5) + np.array([0, rng.uniform(-2.0, 2.0), 0])
            big = k % 5 == 0
            size = [16.0, 1.4, 16.0] if big else [rng.uniform(7.5, 10.5), 1.2, rng.uniform(7.5, 10.5)]
            rigged = (k % 5 == 3)
            L["platforms"].append({"id": R.next_id("pf"), "pos": v3(pos), "size": [round(v, 2) for v in size], "yaw": 0.0,
                                   "kind": "wood", "chain": 60.0, "drop": rigged})
            B.station(pos, "platform", VILLAGE)
            B.moves.append({"type": "hop", "gap": round(float(np.linalg.norm((pos - prev) * np.array([1, 0, 1]))) - 9.0, 1), "dy": round(float(prev[1] - pos[1]), 1), "y": float(pos[1])})
            prev = pos
            if big:
                sc = 0.7
                L["props"].append({"scene": A + "Village_Building.glb", "pos": v3(pos), "rot": [0.0, round(rng.uniform(0, 6.28), 3), 0.0],
                                   "scale": sc, "box": [5.6 * sc, 7.05 * sc, 5.6 * sc], "vis": 420.0})
                L["lights"].append({"pos": v3(pos + np.array([0, 4.0, 0])), "color": [1.0, 0.6, 0.25], "energy": 1.4, "range": 26.0})
                if cross == 1 and not frag2_done and k >= 10:
                    L["fragments"].append({"id": "frag2", "pos": v3(pos + np.array([0, 14.11 * sc + 1.0, 0]))})
                    R.text(pos + np.array([6, 0, 0]), 7.0, "Something glints on that roof.")
                    frag2_done = True
            elif k % 2 == 0:
                L["lights"].append({"pos": v3(pos + np.array([0, 3.0, 0])), "color": [1.0, 0.65, 0.3], "energy": 0.7, "range": 16.0})
        B.a = a1 % (2 * math.pi)
        B.y -= 150.0
        if cross == 0:
            L["centipedes"].append({"id": R.next_id("cen"), "trigger": [v3(B.spot(B.a, B.y, 8.0)), 12.0], "spawn": [v3(B.spot(B.a + 0.4, B.y + 12, 3.0))]})
        info = B.landing(VILLAGE, "VILLAGE, FAR SIDE" if cross == 0 else "VILLAGE, LAST HOUSES", None, length=40.0)
        B.under(16.0)
        B.run(VILLAGE, (-2160 if cross == 0 else -2365) * Z, terraces=((-2080 * Z,) if cross == 0 else (-2290 * Z,)))

    # ---------------------------------------------------------------- 6 CRYSTAL VEINS
    info = B.shelf(CRYSTAL, 46, lobe_p=18.0, p=13.0, label=BIOMES[CRYSTAL])
    B.checkpoint(info["pts"][1], BIOMES[CRYSTAL], CRYSTAL)
    R.text(info["pts"][1], 10.0, "Cold light. Crystals the size of towers have grown clean across the rift. They are slick as glass, and they slope. Once you step on, you are going where they go.")
    B.tour(info["pts"][1], info["pts"][1] - B.out_dir(B.a) * 120 + np.array([0, -40, 0]), "Crystal spars")
    for k in range(3):
        a0 = B.a
        a1 = a0 + math.pi + rng.uniform(-0.45, 0.45)
        drop = rng.uniform(55, 70)
        p0 = B.spot(a0, B.y + 0.2, -8.0)
        p1 = B.spot(a1, B.y - drop, -8.0)
        L["spars"].append({"a": v3(p0), "b": v3(p1), "r": round(rng.uniform(6.5, 8.0), 2)})
        B.moves.append({"type": "spar", "length": round(float(np.linalg.norm(p1 - p0)), 0), "drop": round(drop, 0)})
        for f in (0.15, 0.4, 0.65, 0.9):
            L["lights"].append({"pos": v3(p0 + (p1 - p0) * f + np.array([0, 5, 0])), "color": GLOW[CRYSTAL], "energy": 1.0, "range": 30.0})
        B.a = a1 % (2 * math.pi)
        B.y -= drop
        info = B.landing(CRYSTAL, "CRYSTAL VEINS, SPAR %d" % (k + 1), None, length=44.0, checkpoint=(k == 1))
        if k == 1:
            B.enter_wall(0.5 * (info["a0"] + info["a1"]))
            R.tunnel(CRYSTAL, [(46, 4, 15)], r=4.8)
            fr = R.chamber(CRYSTAL, 14, 10, 14, amp=(1.5, 1.2, 0.5), name="Geode")
            L["fragments"].append({"id": "frag3", "pos": v3(np.array([fr.c[0], fr.floor_y + 1.4, fr.c[2]]))})
            R.scatter_floor(fr, 9, lambda p: R.intents.append(("crystal", dict(pos=p, s=rng.uniform(1.2, 2.8)))))
            R.text(info["pts"][len(info["pts"]) // 2], 6.0, "A crack in the wall, glowing from inside.")
            L["centipedes"].append({"id": R.next_id("cen"), "trigger": [v3(info["pts"][-1]), 10.0], "spawn": [v3(B.spot(B.a + 0.5, B.y + 10, 3.0))]})
        B.under(17.0)
        B.run(CRYSTAL, B.y - rng.uniform(40, 60), chain_every=2, chain_n=(3, 4))
    B.run(CRYSTAL, -2765 * Z, chain_every=1, terraces=(-2620 * Z,))

    # ---------------------------------------------------------------- 7 THE FOUNDRY
    info = B.shelf(FOUNDRY, 50, lobe_p=18.0, p=14.0, label=BIOMES[FOUNDRY])
    B.checkpoint(info["pts"][1], BIOMES[FOUNDRY], FOUNDRY)
    R.text(info["pts"][1], 10.0, "Heat from below. Far down there is a lake of it, and it lights the whole rift red. The kilns on the walls still burn.")
    B.tour(info["pts"][1], info["pts"][1] - B.out_dir(B.a) * 80 + np.array([0, -120, 0]), "The Foundry")
    B.under(17.0)
    # iron gantries bolted to the wall: long, narrow, and the vents do not care that you are there
    foundry_shelf = False
    while B.y > LAKE_Y + 120:
        if not foundry_shelf and B.y < -2890.0 * Z:
            foundry_shelf = True
            info = B.shelf(FOUNDRY, 30)
            lobe_t = B.terrace(FOUNDRY)
            # v48: a checkpoint on the great shelf splits the 554 m Foundry stretch. It sits at the
            # exit corner every player has to walk through (a Short Way 3 landing passes it too).
            B.checkpoint(B.terraces[-1]["corner"], "THE FOUNDRY, THE GREAT SHELF", FOUNDRY)
            info = B.shelf(FOUNDRY, 34, lobe_p=lobe_t)
            B.under(18.0, switchback=False)
        r = B.rw()
        Lg = rng.uniform(34, 52)
        a_mid = B.a + B.dirn * (Lg * 0.5 / r)
        c = B.spot(a_mid, B.y, 6.5)
        tang = np.array([-math.sin(a_mid), 0, math.cos(a_mid)])
        L["platforms"].append({"id": R.next_id("pf"), "pos": v3(c), "size": [4.2, 0.8, round(Lg, 1)], "yaw": round(godot_yaw_facing(tang), 4),
                               "kind": "iron", "chain": 0.0, "drop": False})
        for f in (-0.35, 0.0, 0.35):
            q = c + tang * Lg * f
            if rng.random() < 0.6:
                L["vents"].append({"pos": v3(q + np.array([0, 0.1, 0])), "period": round(rng.uniform(5.0, 8.0), 2), "phase": round(rng.uniform(0, 9), 2)})
        L["lights"].append({"pos": v3(c + np.array([0, 4, 0])), "color": GLOW[FOUNDRY], "energy": 1.2, "range": 26.0})
        B.station(c, "gantry", FOUNDRY)
        B.a += B.dirn * (Lg / r)
        info = B.shelf(FOUNDRY, rng.uniform(26, 40), lobe_p=None)
        # v48: the ladder hangs straight off this balcony, like run() builds it. Stepping down
        # with under() first moved the cursor 16-21 m with no floor there, so the first foothold
        # sat 37-42 m below the balcony (two of them past the 40 m lethal line).
        if rng.random() < 0.9:
            B.chain(FOUNDRY, rng.randint(3, 5), above=info["pts"][-1])
            B.under(17.0, switchback=False)
        else:
            B.under(rng.uniform(16, 21))
    # THE CRUCIBLE: monkey bars clean across the rift, over the lake
    B.run(FOUNDRY, LAKE_Y + 22.0, chain_every=1)
    info = B.shelf(FOUNDRY, 40, lobe_p=18.0, p=15.0, label="THE CRUCIBLE")
    B.checkpoint(info["pts"][1], "THE CRUCIBLE", FOUNDRY)
    R.text(info["pts"][1], 10.0, "No floor. Only thin rods of iron, a full rope apart, and the heat. You cannot stand on them. Swing, let go at the top, throw again. Rest where the iron is wide. Not every rod holds.")
    a0 = B.a
    a1 = a0 + math.pi
    p0 = B.spot(a0, B.y + 12.0, 10.0)
    p1 = B.spot(a1, B.y + 12.0, 10.0)
    B.crucible = (p0.copy(), p1.copy())
    span_len = float(np.linalg.norm(p1 - p0))
    # thin rods, a full rope apart (25 m is the rope's maximum): swing, let go, throw again
    lead = 14.0                                   # the first and last rods sit a throw from their balconies
    n_gap = int((span_len - 2 * lead) / 25.5)
    pitch = (span_len - 2 * lead) / n_gap
    d_bar = (p1 - p0) / span_len
    yaw_bar = math.atan2(d_bar[2], d_bar[0])
    L["rules"]["bar_pitch"] = round(pitch, 2)
    B.tour(info["pts"][1], p0 + (p1 - p0) * 0.5, "The Crucible")
    for i in range(n_gap + 1):
        pos = p0 + d_bar * (lead + pitch * i) + np.array([0, rng.uniform(-1.0, 1.0), 0])
        if i > 0 and i < n_gap and i % 5 == 0:
            # a small cage hung 9 m under this rod: lower yourself onto it, breathe, hook the same rod again
            L["platforms"].append({"id": R.next_id("pf"), "pos": v3(pos + np.array([0, -9.0, 0])), "size": [5.0, 0.9, 5.0], "yaw": 0.0,
                                   "kind": "iron", "chain": 40.0, "drop": False, "rest": True})
            L["embers"].append({"pos": v3(pos + np.array([0, -7.6, 0]))})
        if i == 1:
            L["tour"].append({"pos": v3(pos + np.array([0, 0.3, 0])), "look": v3(pos + d_bar * 26.0), "label": "standing on rod 2 (should slide off)"})
            L["tour"].append({"pos": v3(pos + np.array([0, 2.0, 0]) - d_bar * 7.0), "look": v3(pos), "label": "rod 2 close", "air": True})
        R.intents.append(("bar", dict(idx=i + 1, pos=pos, yaw=yaw_bar, length=12.0, width=0.22, thick=0.22, lava_y=LAKE_Y,
                                      sink=(i % 3 == 2))))
    cx, cz = rift.center(LAKE_Y)
    L["lava"].append({"center": v3([float(cx), LAKE_Y, float(cz)]), "yaw": 0.0, "half_w": 215.0, "half_l": 215.0, "kill_top": 5.0})
    for k in range(10):
        aa = k / 10.0 * 2 * math.pi
        L["lights"].append({"pos": v3([float(cx) + math.cos(aa) * 95, LAKE_Y + 10, float(cz) + math.sin(aa) * 95]), "color": [1.0, 0.4, 0.08], "energy": 1.1, "range": 95.0})
    B.a = a1 % (2 * math.pi)
    # v49 (#51): one text, not two on top of each other (the door text sat 1 m from this one)
    info = B.landing(FOUNDRY, "PAST THE CRUCIBLE", "You made it across. Your hands will not stop shaking. In the wall, a door wears the mark of the idol. It wants all three pieces.", length=40.0)
    B.enter_wall(0.5 * (info["a0"] + info["a1"]))
    t = R.tunnel(FOUNDRY, [(40, 10, 0), (30, 8, 15)], r=5.5)
    R.intents.append(("gate", dict(id="gate_idol", kind="idol", need=3, tunnel=t, dist=12.0)))
    R.tunnel(NEST, [(60, 40, 20), (60, 45, -25), (50, 35, 15)], r=6.0)

    # ---------------------------------------------------------------- 8 THE NEST
    n0 = R.chamber(NEST, 30, 16, 26, name="Nest Landing")
    B.checkpoint(n0.arrival + n0.d * 5.0, BIOMES[NEST], NEST)
    R.fire(n0.arrival + n0.d * 4 + n0.s * 3, 0.6)
    R.intents.append(("ember", dict(pos=n0.arrival + n0.d * 3 - n0.s * 3)))
    R.intents.append(("ember", dict(pos=n0.arrival + n0.d * 3 + n0.s * 5)))
    R.text(n0.arrival, 8.0, "This is where they come from.")
    t = R.tunnel(NEST, [(50, 10, -10)], r=6.5)
    n1 = R.chamber(NEST, 100, 52, 92, amp=(7.0, 3.2, 0.8), name="The Nest")
    # the Follower comes out of the dark at the far side of the Nest, about 80 m behind the altar,
    # so it reaches you while you run for the exit (from the tunnel mouth it was 250 m away and
    # would have arrived after the level was over)
    # v48: 80 m behind the altar was over the chasm (the trench spans |lx| < 24 m), so the Follower
    # dropped into it. It now comes out on the altar side of the chasm, about 60 m behind the altar.
    L["follower_finale"] = {"spawn": v3(n1.world_point(0.72 * n1.r[0] - 52.0, -0.25 * n1.r[2], n1.floor_y + 4.0))}
    L["centipedes"].append({"id": R.next_id("cen"), "trigger": [v3(n1.arrival + n1.d * 14), 10.0], "spawn": [v3(t["points"][0] + np.array([0, 2.5, 0]))]})
    # v48 finale: when the idol is taken the chasers come out BETWEEN the altar and the exit tunnel,
    # flanking the escape line 31-40 m from the altar (never on the line), so the run out is a run
    # past them, not away from them. The exit sits at 0.85 rx on the axis, the altar at 0.72 rx.
    L["centipedes"].append({"id": R.next_id("cen"), "on": "idol",
                            "spawn": [v3(n1.world_point(0.72 * n1.r[0] + 12.0, 0.30 * n1.r[2], n1.floor_y + 5)),
                                      v3(n1.world_point(0.72 * n1.r[0] + 12.0, -0.30 * n1.r[2], n1.floor_y + 5)),
                                      v3(n1.world_point(0.72 * n1.r[0] + 22.0, -0.20 * n1.r[2], n1.floor_y + 5))]})
    R.chasm(n1, 20.0, 26.0, spacing=11.5)
    for i in range(4):
        bp = n1.world_point(rng.uniform(0.45, 0.8) * n1.r[0], rng.uniform(-0.35, 0.35) * n1.r[2], n1.floor_y)
        R.intents.append(("dropper", dict(kind="boulder", x=bp[0], z=bp[2], y_floor=n1.floor_y, ceiling_from=n1.floor_y + 3)))
    R.scatter_floor(n1, 40, lambda p: R.prop(rng.choice(CORPSES), p, yaw=rng.uniform(0, 6.28)), min_r=0.3)
    for i in range(14):
        p = n1.world_point(rng.uniform(-0.6, 0.6) * n1.r[0], rng.choice([-1, 1]) * rng.uniform(0.3, 0.7) * n1.r[2], n1.floor_y)
        R.prop(A + "Spikes_01.glb", p, yaw=rng.uniform(0, 6.28), scale=rng.uniform(0.08, 0.16))
    R.ceiling_spikes(n1, 22)
    for i in range(12):
        R.light(n1.world_point(rng.uniform(-0.7, 0.7) * n1.r[0], rng.uniform(-0.7, 0.7) * n1.r[2], n1.floor_y), [1.0, 0.15, 0.1], 1.0, 24, snap=True, lift=2)
    altar = n1.world_point(0.72 * n1.r[0], 0, n1.floor_y)
    R.intents.append(("altar", dict(x=altar[0], z=altar[2], y=n1.floor_y + 4)))
    R.text(n1.arrival, 10.0, "At the far end, on the altar, it waits. Like she said.")
    nest_dress(R, L, n1, altar, rng)
    R.bell(n1, lx_frac=-0.35, lz_frac=0.45, scale=3.0)
    for i in range(5):
        L["ambience"].append({"pos": v3(n1.world_point(rng.uniform(-70, 70), rng.uniform(-60, 60), n1.floor_y + 8)),
                              "sounds": SNARLS + BREATHS, "min": 8.0, "max": 20.0, "range": 60.0, "db": 0.0})
    t = R.tunnel(NEST, [(45, 4, 20)], r=6.0)
    R.intents.append(("gate", dict(id="gate_exit", kind="exit", need=0, tunnel=t, dist=9.0)))
    asc = R.chamber(NEST, 26, 34, 22, amp=(3.0, 1.5, 0.5), name="The Ascent")
    L["finish"].append({"pos": v3(asc.world_point(0.25 * asc.r[0], 0.0, asc.floor_y + 2.0)), "r": 7.0})
    R.light(asc.world_point(0.2 * asc.r[0], 0.0, asc.floor_y), [1.0, 0.95, 0.85], 3.0, 60.0, lift=30.0)
    R.light(asc.world_point(0.2 * asc.r[0], 0.0, asc.floor_y), [1.0, 0.9, 0.7], 1.2, 30.0, lift=6.0)
    R.text(asc.arrival, 8.0, "Light, far above. Take it home.")

    # ghosts and tour stops inside the caves
    for ch in R.chambers:
        eye = ch.arrival + np.array([0, 0, 0])
        B.tour(eye, [ch.c[0], ch.floor_y + 4, ch.c[2]], ch.name)
    # a sparse walk of the whole descent for the debug camera
    st = L["stations"]
    for k in range(0, len(st), 9):
        p = np.array(st[k]["pos"])
        cxx, czz = rift.center(p[1])
        L["tour"].append({"pos": v3(p + np.array([0, 1.8, 0])), "look": v3([float(cxx), p[1] - 40.0, float(czz)]), "label": "%s %d m" % (BIOMES[st[k]["biome"]], -p[1])})

    for k in range(4, len(st), 14):
        p = np.array(st[k]["pos"])
        a_ = rift.bearing(p)
        eye = p - B.out_dir(a_) * 34.0 + np.array([0, 11.0, 0]) + np.array([-math.sin(a_), 0, math.cos(a_)]) * 16.0
        L["tour"].append({"pos": v3(eye), "look": v3(p + np.array([0, -4.0, 0])), "label": "fly %s %d m" % (BIOMES[st[k]["biome"]], -p[1]), "air": True})

    for k in range(9, len(st), 45):
        p = np.array(st[k]["pos"])
        a_ = rift.bearing(p)
        L["tour"].append({"pos": v3(p + np.array([0, 1.8, 0])), "look": v3(p + np.array([0, 16.0, 0]) - B.out_dir(a_) * 9.0), "label": "up %s %d m" % (BIOMES[st[k]["biome"]], -p[1])})
    seen_ = {}
    for k in range(1, len(B.shelves), 2):
        S_ = B.shelves[k]
        if len(S_["pts"]) < 3 or S_["length"] < 12:
            continue
        seen_[S_["biome"]] = seen_.get(S_["biome"], 0) + 1
        if seen_[S_["biome"]] > 6:
            continue
        p0_ = np.array(S_["pts"][0])
        p1_ = np.array(S_["pts"][-1])
        L["tour"].append({"pos": v3(p0_ + np.array([0, 1.8, 0])), "look": v3(p1_ + np.array([0, 0.3, 0])), "label": "along %s %d m" % (BIOMES[S_["biome"]], -p0_[1])})

    align_strata(B)
    # every other centipede belongs to the stratum it was woken in, and stays there
    for c_ in L["centipedes"]:
        if c_.get("follower") or "trigger" not in c_:
            continue
        yy_ = c_["trigger"][0][1]
        for (t_, b_, bi_) in rift.strata:
            if t_ >= yy_ > b_:
                c_["territory"] = [t_, b_]
                if bi_ in (OSSUARY, CRYSTAL, FOUNDRY, BURROWS, NEST) or int(c_["id"][-1]) % 2 == 1:
                    c_["skin"] = "pale"

    # weather that sits in the world (the falling and rising kind follows the camera in game)
    for k_, sp_ in enumerate(L["spars"]):
        pa_, pb_ = np.array(sp_["a"]), np.array(sp_["b"])
        mid_ = 0.5 * (pa_ + pb_)
        tdir = (pb_ - pa_) / np.linalg.norm(pb_ - pa_)
        side_ = np.cross(np.array([0, 1.0, 0]), tdir)
        side_ = side_ / np.linalg.norm(side_)
        L["tour"].append({"pos": v3(mid_ + side_ * 15.0 - np.array([0, 4.0, 0])), "look": v3(mid_ + tdir * 6.0), "label": "spar %d side" % (k_ + 1), "air": True})
        L["tour"].append({"pos": v3(pa_ + tdir * 45.0 + side_ * 2.0 - np.array([0, 9.0, 0])), "look": v3(pa_ + tdir * 60.0 + np.array([0, 3.0, 0])), "label": "spar %d under" % (k_ + 1), "air": True})
        L["tour"].append({"pos": v3(pa_ + tdir * 40.0 + np.array([0, 1.8, 0])), "look": v3(pa_ + tdir * 90.0 + np.array([0, 1.0, 0])), "label": "spar %d deck" % (k_ + 1)})
    for k_, (hp_, ha_, hb_) in enumerate(getattr(B, "husk_marks", [])[:14]):
        if ha_ is None:
            eye_ = np.array(hp_) + np.array([0, 9.0, 0]) + np.array([14.0, 0, 6.0])
        else:
            eye_ = np.array(hp_) - B.out_dir(ha_) * 7.0 + np.array([0, 3.0, 0])
        L["tour"].append({"pos": v3(eye_), "look": v3(np.array(hp_) + np.array([0, 1.2, 0])), "label": "husk %d %s" % (k_ + 1, BIOMES[hb_]), "air": True})
    L["mist"] = []
    for k_, s_ in enumerate(getattr(B, "shelves", [])):
        mid_ = s_["pts"][len(s_["pts"]) // 2]
        if s_["biome"] == FUNGAL and k_ % 2 == 0:
            L["mist"].append({"pos": v3(mid_ + np.array([0, 2.5, 0])), "size": [min(s_["length"], 34.0), 8.0, 18.0], "density": 0.05, "color": [0.25, 0.8, 0.45]})
        elif s_["biome"] == CRYSTAL and k_ % 3 == 0:
            L["mist"].append({"pos": v3(mid_ + np.array([0, 1.0, 0])), "size": [min(s_["length"], 30.0), 4.0, 16.0], "density": 0.03, "color": [0.5, 0.7, 1.0]})
        elif s_["biome"] == OSSUARY and k_ % 4 == 0:
            L["mist"].append({"pos": v3(mid_ + np.array([0, 2.0, 0])), "size": [min(s_["length"], 30.0), 6.0, 16.0], "density": 0.035, "color": [0.75, 0.7, 0.55]})
        elif s_["biome"] == FOUNDRY and k_ % 3 == 0:
            L["mist"].append({"pos": v3(mid_ + np.array([0, 2.5, 0])), "size": [min(s_["length"], 30.0), 7.0, 16.0], "density": 0.04, "color": [0.55, 0.22, 0.08]})
    for st_ in L["stations"]:
        if st_["kind"] == "foothold" and st_["biome"] == DROWNED:
            L["mist"].append({"pos": v3(np.array(st_["pos"]) + np.array([0, 1.5, 0])), "size": [20.0, 7.0, 20.0], "density": 0.06, "color": [0.55, 0.7, 0.8]})

    L["lanterns"] = []
    hard_routes(B)
    megastructures(B)
    L["lanterns"] += L.pop("lanterns_extra", [])
    yy = -90.0
    k = 0
    while yy > LAKE_Y + 50:
        bi = int(rift.biome_at(np.array([yy]))[0])
        for j in range(3):
            aa = k * 2.399963 + j * 2.0944
            q = B.spot(aa, yy + rng.uniform(-12, 12), 9.0)
            q = B.spot(aa, q[1], 17.0)
            if B.in_terrace(q, 6.0) or LID[1] - 4.0 < q[1] < LID[0] + 4.0:          # v48: not inside the Lid's plug
                continue
            L["lights"].append({"pos": v3(q), "color": GLOW[bi], "energy": 0.62, "range": 85.0})
            L["lanterns"].append({"pos": v3(B.spot(aa, q[1], 2.0)), "color": GLOW[bi], "s": round(rng.uniform(3.0, 4.6), 2)})
        yy -= 46.0
        k += 1
    # v48: every foothold, hanging platform and Short Way ledge gets its guide lamp (the every-other
    # pattern stays for balconies and terraces). The dot is hung from the wall surface at its own
    # height: 3 m toward the wall, but never closer than 1.2 m to the first rock on that bearing,
    # so noise outcrops can no longer swallow it (a fixed 3 m push buried a third of them).
    for i_, st_ in enumerate(L["stations"]):
        if i_ % 2 != 0 and st_["kind"] not in ("foothold", "platform", "hard"):
            continue
        p_ = np.array(st_["pos"])
        a_ = rift.bearing(p_)
        y_ = float(p_[1]) + 2.6
        cxx_, czz_ = rift.center(y_)
        d_ = float(math.hypot(p_[0] - float(cxx_), p_[2] - float(czz_)))
        inset_ = rift.wall_r(a_, y_) - d_
        if inset_ >= 1.2:
            q_ = rift.point(a_, y_, max(inset_ - 3.0, 1.2))
        else:
            q_ = p_ + np.array([0, 2.6, 0])          # already at the rock face: hang it right over the stand point
        L["lanterns"].append({"pos": v3(q_), "color": GLOW[st_["biome"]], "s": 1.4})
    # the HUD and fog switch a little before each stratum's first balcony
    for st_ in L["strata"]:
        st_["top"] += 8.0
        st_["bottom"] += 8.0
    L["strata"][0]["top"] = 70.0

    R.solids = B.solids
    R.moves = B.moves
    R.rift = rift
    return R
