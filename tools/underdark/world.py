"""The authored route of THE UNDERDARK: biomes, chambers, tunnels, shafts, chasms,
puzzles, traps and set pieces. Geometry intent is recorded first, then resolved
against the final field so every shelf, prop and trigger sits on real rock."""
import math
import random
import numpy as np

from sdf import Chamber, Tunnel, Shaft, Trench, Bowl, Field

BIOMES = ["THE MOUTH", "OSSUARY", "FUNGAL HOLLOW", "ROOTWORKS", "DROWNED GALLERIES",
          "SUNKEN VILLAGE", "CRYSTAL VEINS", "THE FOUNDRY", "THE NEST", "THE BURROWS"]
# the color of the ambient wall lights per biome
GLOW = [[1.0, 0.8, 0.55], [0.85, 0.8, 0.65], [0.4, 1.0, 0.6], [1.0, 0.6, 0.25], [0.5, 0.8, 0.85],
        [0.8, 0.75, 0.9], [0.5, 0.75, 1.0], [1.0, 0.45, 0.15], [1.0, 0.2, 0.15], [1.0, 0.72, 0.4]]
MOUTH, OSSUARY, FUNGAL, ROOTS, DROWNED, VILLAGE, CRYSTAL, FOUNDRY, NEST, BURROWS = range(10)

A = "res://Art/"
CORPSES = [A + "Corpse_0%d.glb" % i for i in range(1, 7)]
PLANTS_L = [A + "Plant_L_0%d.glb" % i for i in range(1, 7)]
PLANTS_S = [A + "Plant_S_0%d.glb" % i for i in range(1, 5)]
SFX = "res://sfx/soundsnap/"
BREATHS = [SFX + "monster_idle/306002-Creature-Oxbow-Breaths-Wet-Deep_1.wav",
           SFX + "monster_idle/306004-Creature-Oxbow-Breaths-Wet-Fast.wav",
           SFX + "monster_idle/306005-Creature-Oxbow-Breaths-Wet-Relaxed_1.wav"]
WHISPERS = [SFX + "1022742.audio-HUMAN_VOCAL_Female_4_Breath_Medium_01.wav",
            SFX + "463323-HUMAN_BREATH_Female-Deep_Opened_Mouth_Normal_Speed_Breath-B.wav"]
SNARLS = [SFX + "monster_attack/306010-Creature-Oxbow-Snarls-Breaths-Aggressive_1.wav",
          SFX + "monster_attack/306013-Creature-Oxbow-Snarls-Breaths-Aggressive_4.wav"]
WIND = SFX + "ambience/1238574.audio-DSGNDron-SMorph-Doom_Drones_2_-Horror_Winds_Far_Whistle_01.wav"


# wall dressing palette: (scene, scale range, weight). Scales follow the campaign's own
# median placements (Stone_01 1.6x, Stone_04 2.3x, Rock_01 4.2x ...).
DRESS_COMMON = [(A + "Stone_01.glb", (1.2, 3.4), 6), (A + "Stone_04.glb", (1.2, 3.2), 3), (A + "Stone_05.glb", (1.1, 3.0), 3),
                (A + "Stone_02.glb", (1.1, 2.4), 2), (A + "Stone_06.glb", (0.8, 1.3), 2), (A + "Rock_01.glb", (2.0, 4.0), 2),
                (A + "Stone_09.glb", (0.6, 1.0), 1), (A + "Rock_02.glb", (0.45, 0.7), 1)]
# shafts and tunnels only get small stones, so nothing bridges the drop or blocks the way
DRESS_SMALL = [(A + "Stone_01.glb", (1.0, 2.0), 6), (A + "Stone_04.glb", (0.9, 1.6), 3), (A + "Stone_05.glb", (0.9, 1.6), 3),
               (A + "Stone_02.glb", (0.9, 1.5), 2)]
DRESS_BY_BIOME = {
    3: DRESS_COMMON + [(A + "Roots.glb", (0.9, 1.8), 6)],
    5: DRESS_COMMON + [(A + "BlockoutMeshes/Arch2.glb", (1.2, 2.0), 2)],
    6: DRESS_COMMON + [(A + "Spikes_01.glb", (0.12, 0.22), 3)],
    8: DRESS_COMMON + [(A + "Spikes_01.glb", (0.1, 0.2), 4), (A + "Stone_02.glb", (1.5, 3.0), 2)],
}
RUBBLE = [(A + "Stone_01.glb", (0.9, 2.2), 5), (A + "Stone_04.glb", (0.9, 1.8), 2), (A + "Rock_01.glb", (1.2, 2.4), 2)]


def pick_weighted(rng, table):
    total = sum(t[2] for t in table)
    r = rng.uniform(0, total)
    for t in table:
        r -= t[2]
        if r <= 0:
            return t
    return table[-1]


def v3(p):
    return [round(float(p[0]), 3), round(float(p[1]), 3), round(float(p[2]), 3)]


def hdir(yaw):
    return np.array([math.cos(yaw), 0.0, math.sin(yaw)])


def side_dir(yaw):
    return np.array([-math.sin(yaw), 0.0, math.cos(yaw)])


def godot_yaw_facing(d):
    """rotation.y that makes a node's -Z axis point along d."""
    return math.atan2(-d[0], -d[2])


SCALE = 1.2   # every biome 20% bigger; tuned distances (shelves, pillars, bars, tube radius) stay fixed


class Route:
    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.prims = []
        self.groups = []          # group id per prim
        self.parent_of = {}       # side-cave group -> chamber group
        self.group = 0
        self.cursor = np.zeros(3)
        self.heading = 0.0
        self.landing = None
        self.last_chamber = None
        self.chambers = []        # (Chamber, group)
        self.intents = []         # deferred placement callbacks run against the final field
        self.slabs = []           # dicts: biome, poly (N,2), top, bottom
        self.columns = []         # dicts: biome, x, z, bottom, top, radius
        self.L = {k: [] for k in ["ghosts", "bells", "checkpoints", "props", "lights", "fires", "embers", "crumbles",
                                   "vents", "droppers", "spikes", "ice", "texts", "gates", "plates",
                                   "kilns", "fragments", "stalkers", "centipedes", "dying_lights",
                                   "ambience", "barriers", "tour", "zones", "altar", "bars", "lava", "dress", "finish"]}
        self.L["biomes"] = BIOMES
        self.ids = {}
        self.tube_plans = []
        self._feature_i = 0
        self._descent_style = 0
        self.extra_allow = set()   # tube groups the next chamber/tunnel may sit next to

    # ------------------------------------------------------------ bookkeeping

    def next_id(self, kind):
        self.ids[kind] = self.ids.get(kind, 0) + 1
        return "%s%d" % (kind, self.ids[kind])

    def _boxes_overlap(self, a, b, margin):
        return np.all(a[0] - margin <= b[1]) and np.all(a[1] + margin >= b[0])

    def _add(self, prims, allow_groups, margin=7.0):
        """Add prims as a new group if they stay clear of every unrelated group."""
        for p in prims:
            pb = p.aabb()
            for q, g in zip(self.prims, self.groups):
                if g in allow_groups or q.kind == "rift":
                    continue
                if self._boxes_overlap(pb, q.aabb(), margin):
                    return None
        self.group += 1
        for p in prims:
            self.prims.append(p)
            self.groups.append(self.group)
        return self.group

    def steer(self):
        """Past ~200 m out, bend the route so it circles the middle instead of wandering off.
        The target is the counter-clockwise tangent tilted inward, so the route curves
        around rather than reversing into itself. Turns are capped per call."""
        r = math.hypot(self.cursor[0], self.cursor[2])
        if r < 200:
            return
        to_center = math.atan2(-self.cursor[2], -self.cursor[0])
        inward = min(1.0, (r - 200) / 150.0)
        target = to_center - math.radians(90 - 50 * inward)
        diff = (target - self.heading + math.pi) % (2 * math.pi) - math.pi
        self.heading += max(-math.radians(40), min(math.radians(40), diff))

    # ------------------------------------------------------------ geometry

    def bowl(self, center, radius):
        b = Bowl(MOUTH, center, center[1], radius)
        self.group += 1
        self.prims.append(b)
        self.groups.append(self.group)
        self.bowl_prim = b
        self.bowl_group = self.group
        return b

    def chamber(self, biome, rx, ry, rz, amp=(5.0, 2.6, 0.7), name="", tries=14, lights=True):
        rx, ry, rz = rx * SCALE, ry * SCALE, rz * SCALE
        if self.landing is None:
            self.steer()
        base_heading = self.heading
        for attempt in range(tries):
            turn = 0.0 if attempt == 0 else math.radians(12 * ((attempt + 1) // 2)) * (1 if attempt % 2 else -1)
            yaw = base_heading + turn
            d = hdir(yaw)
            if self.landing is not None:
                S = self.landing
                cxz = S + d * (0.30 * rx)
                floor = S[1]
            else:
                cxz = self.cursor + d * (0.85 * rx)
                floor = self.cursor[1]
            c = np.array([cxz[0], floor + ry * 0.35, cxz[2]])
            ch = Chamber(biome, c, (rx, ry, rz), yaw, floor, amp=amp, name=name)
            allow = {self.group, self.group - 1, self.group - 2} | self.extra_allow
            g = self._add([ch], allow)
            if g is None:
                if self.landing is not None and attempt >= 6:
                    break
                continue
            ch.group = g
            ch.from_shaft = self.landing is not None
            ch.arrival = np.array(self.landing) if self.landing is not None else np.array(self.cursor)
            self.landing = None
            self.heading = yaw
            self.cursor = np.array([c[0], floor, c[2]]) + d * (0.85 * rx)
            ch.exit = np.array(self.cursor)
            self.last_chamber = ch
            self.chambers.append(ch)
            self.L["zones"].append({"name": name, "biome": biome, "center": v3([c[0], floor, c[2]]),
                                    "radius": round(max(rx, rz) + 6, 2), "floor": round(floor, 2),
                                    "top": round(c[1] + ry, 2)})
            perim = math.pi * (rx + rz)
            n_dress = int(perim / 9.0 * 1.4)
            table = DRESS_BY_BIOME.get(biome, DRESS_COMMON)
            # small rooms get small stones, sunk deeper, and no floor rubble: a 5 m block
            # in a 15 m room blocks the door
            small = min(rx, rz) < 20.0
            k = min(1.0, min(rx, rz) / 28.0)
            for i in range(n_dress):
                piece = pick_weighted(self.rng, table)
                hf = self.rng.choice([0.2, 0.35, 0.55, 0.8, 0.95]) if small else self.rng.choice([0.08, 0.2, 0.35, 0.55, 0.8, 0.95])
                self.intents.append(("dress", dict(ch=ch, ang=self.rng.uniform(0, 2 * math.pi), hf=hf,
                                                   scene=piece[0], scale=self.rng.uniform(*piece[1]) * k,
                                                   embed=self.rng.uniform(0.55, 0.7) if small else self.rng.uniform(0.4, 0.6))))
            if not small:
                for i in range(max(3, int(n_dress * 0.25))):
                    piece = pick_weighted(self.rng, RUBBLE)
                    self.intents.append(("rubble", dict(ch=ch, scene=piece[0], scale=self.rng.uniform(*piece[1]))))
            n_lights = max(4, int(max(rx, rz) / 7.0)) if lights else 0
            for i in range(n_lights):
                a = 2 * math.pi * (i + self.rng.uniform(0.1, 0.9)) / n_lights
                lx = math.cos(a) * rx * 0.78
                lz = math.sin(a) * rz * 0.78
                h = self.rng.uniform(4.0, min(9.0, ry * 0.6))
                self.L["lights"].append({"pos": v3(ch.world_point(lx, lz, floor + h)), "color": GLOW[biome],
                                         "energy": 1.2, "range": round(max(26.0, min(rx, rz) * 1.0), 1)})
            if lights:
                self.L["lights"].append({"pos": v3([c[0], floor + ry * 0.9, c[2]]), "color": GLOW[biome],
                                         "energy": 0.6, "range": round(max(rx, rz) * 1.3, 1)})
            return ch
        raise RuntimeError("could not place chamber %s near %s" % (name, self.cursor))

    def tunnel(self, biome, segs, r=5.5, amp=(0.0, 1.3, 0.5), tries=12):
        segs = [(l * SCALE, dr * SCALE, tn) for (l, dr, tn) in segs]
        self.steer()
        base_heading = self.heading
        start = np.array(self.cursor)
        for attempt in range(tries):
            bias = 0.0 if attempt == 0 else math.radians(10 * ((attempt + 1) // 2)) * (1 if attempt % 2 else -1)
            yaw = base_heading + bias
            prims = []
            d = hdir(yaw)
            p = start - d * 7.0
            p = np.array([p[0], start[1] + 0.55 * r, p[2]])
            pts = [p]
            for i, (length, drop, turn) in enumerate(segs):
                yaw += math.radians(turn)
                d = hdir(yaw)
                extra = 7.0 if i == 0 else 0.0
                q = p + d * (length + extra) + np.array([0, -drop, 0])
                prims.append(Tunnel(biome, p, q, r, amp=amp))
                p = q
                pts.append(p)
            # run a little further so the end caps open into the next chamber
            q = p + d * 7.0
            prims.append(Tunnel(biome, p, q, r, amp=amp))
            allow = {self.group, self.group - 1} | self.extra_allow
            g = self._add(prims, allow)
            if g is None:
                continue
            self.extra_allow = set()
            for t in prims:
                t.group = g
            self.heading = yaw
            end_floor = p[1] - 0.55 * r
            self.cursor = np.array([p[0], end_floor, p[2]])
            info = {"prims": prims, "points": pts, "r": r, "biome": biome, "group": g}
            self.last_tunnel = info
            table = DRESS_SMALL
            for tp in prims:
                ln = float(np.linalg.norm(tp.b - tp.a))
                k = 0.0
                while k < ln:
                    piece = pick_weighted(self.rng, table)
                    self.intents.append(("tunnel_dress", dict(t=tp, f=k / max(ln, 0.1), scene=piece[0],
                                                              scale=self.rng.uniform(piece[1][0], min(piece[1][1], 2.2)),
                                                              side=self.rng.uniform(-1.7, 1.7))))
                    k += self.rng.uniform(8.0, 13.0)
            return info
        raise RuntimeError("could not place tunnel near %s" % start)

    SHAFT_SPACING = {1: (10.0, 13.0), 3: (11.0, 14.0), 4: (12.0, 15.0), 5: (12.0, 15.0), 6: (13.0, 16.0), 7: (13.0, 16.0), 8: (14.0, 17.0)}

    def shaft(self, biome, drop, R=9.0, crumble_ratio=0.35, ice=False, spacing=None, glow=None, spiral=False, big_every=6):
        drop = drop * SCALE
        # Spacing widens with depth. The campaign's next hold on the way down is a median
        # 18.5 m away (75th percentile 28 m) on a 25 m rope; these shafts run 19 to 24 m.
        if spacing is None:
            spacing = self.SHAFT_SPACING.get(biome, (12.0, 15.0))
        ch = self.last_chamber
        d = hdir(self.heading)
        S = np.array([ch.c[0], ch.floor_y, ch.c[2]]) + d * (0.55 * ch.r[0])
        bottom_floor = ch.floor_y - drop
        sh = Shaft(biome, S[0], S[2], ch.floor_y + 2.0, bottom_floor + R + 1.0, R)
        g = self._add([sh], {self.group, self.group - 1})
        if g is None:
            raise RuntimeError("shaft blocked under %s" % ch.name)
        self.landing = np.array([S[0], bottom_floor, S[2]])
        # shelves spiral down the wall, each level has one solid shelf
        y = ch.floor_y - self.rng.uniform(*spacing)
        ang = self.rng.uniform(0, 2 * math.pi)
        levels = []
        while y > bottom_floor + 12.0:
            levels.append((y, ang))
            y -= self.rng.uniform(*spacing)
            ang += math.radians(self.rng.uniform(70, 125)) * self.rng.choice([1, -1])
        if spiral:
            # a staircase of ledges winding down the wall: walkable, no rope needed
            yy2 = ch.floor_y - 3.0
            ang2 = self.rng.uniform(0, 2 * math.pi)
            while yy2 > bottom_floor + 4.0:
                self.intents.append(("shaft_shelf", dict(biome=biome, S=S, y=yy2, ang=ang2, R=R, ice=False, big=False, wide=True)))
                if self.rng.random() < 0.25:
                    self.intents.append(("wall_light", dict(S=S, y=yy2 + 2.0, ang=ang2, color=glow or GLOW[biome])))
                yy2 -= self.rng.uniform(3.0, 4.0)
                ang2 += math.radians(self.rng.uniform(38, 52))
            self.L["tour"].append({"pos": v3(S + np.array([0, -drop * 0.5, 0])),
                                   "look": v3(S + np.array([0, -drop, 0])), "label": "%s spiral" % BIOMES[biome]})
            return {"S": S, "top": ch.floor_y, "bottom": bottom_floor, "R": R, "group": g}
        for li, (ly, la) in enumerate(levels):
            big = li % big_every == big_every - 1
            self.intents.append(("shaft_shelf", dict(biome=biome, S=S, y=ly, ang=la, R=R, ice=ice and not big, big=big)))
            if self.rng.random() < crumble_ratio:
                a2 = la + math.radians(self.rng.uniform(120, 220))
                y2 = ly + self.rng.uniform(-3.5, 3.5)
                self.intents.append(("shaft_crumble", dict(biome=biome, S=S, y=y2, ang=a2)))
        table = DRESS_SMALL
        yy = ch.floor_y - 6.0
        while yy > bottom_floor + 8.0:
            piece = pick_weighted(self.rng, table)
            self.intents.append(("shaft_dress", dict(S=S, y=yy, ang=self.rng.uniform(0, 2 * math.pi), scene=piece[0],
                                                     scale=self.rng.uniform(piece[1][0], min(piece[1][1], 2.4)))))
            yy -= self.rng.uniform(7.0, 11.0)
        if glow is None:
            glow = GLOW[biome]
        if glow is not None:
            yy = ch.floor_y - 10
            while yy > bottom_floor + 6:
                self.intents.append(("wall_light", dict(S=S, y=yy, ang=self.rng.uniform(0, 6.28), color=glow)))
                yy -= self.rng.uniform(14, 20)
        self.L["tour"].append({"pos": v3(S + np.array([0, -drop * 0.5, 0])), "look": v3(S + np.array([0, -drop, 0])),
                               "label": "%s shaft" % BIOMES[biome]})
        return {"S": S, "top": ch.floor_y, "bottom": bottom_floor, "R": R, "group": g}

    FEATURES = ["gap", "boulders", "dark", "gauntlet", "swing", "lore", "pit"]

    def feature(self, ch, kind, rng=None):
        """Give a room one thing to do, so no room is just empty floor."""
        rng = rng or self.rng
        if kind == "gap":
            self.chasm(ch, min(9.0, ch.r[0] * 0.3), 15.0, spacing=8.0, spikes=False)
            self.text(ch.arrival + ch.d * 6, 7.0, rng.choice([
                "The floor has split. The far side is close enough to reach.",
                "A crack running the length of the room.",
            ]))
        elif kind == "boulders":
            for i in range(3):
                p = ch.world_point(rng.uniform(-0.5, 0.6) * ch.r[0], rng.uniform(-0.5, 0.5) * ch.r[2], ch.floor_y)
                self.intents.append(("dropper", dict(kind="boulder", x=p[0], z=p[2], y_floor=ch.floor_y, ceiling_from=ch.floor_y + 3)))
            self.scatter_floor(ch, 5, lambda p: self.prop(A + "Stone_09.glb", p, yaw=rng.uniform(0, 6.28), scale=rng.uniform(0.4, 0.8)))
            self.text(ch.arrival + ch.d * 5, 6.0, "Loose rock overhead. Do not stand still.")
        elif kind == "dark":
            for i in range(2):
                self.L["ambience"].append({"pos": v3(ch.world_point(rng.uniform(-20, 20), rng.uniform(-20, 20), ch.floor_y + 3)),
                                           "sounds": BREATHS + WHISPERS, "min": 5.0, "max": 12.0, "range": 30.0, "db": 0.0})
            self.scatter_floor(ch, 6, lambda p: self.prop(rng.choice(CORPSES), p, yaw=rng.uniform(0, 6.28)))
            self.intents.append(("ember", dict(pos=ch.world_point(0.5 * ch.r[0], 0, ch.floor_y))))
            self.text(ch.arrival + ch.d * 4, 7.0, "No light in here at all. Something is breathing.")
        elif kind == "gauntlet":
            for i in range(3):
                p = ch.world_point(rng.uniform(-0.5, 0.6) * ch.r[0], rng.uniform(-0.45, 0.45) * ch.r[2], ch.floor_y)
                self.intents.append(("spike_bed", dict(x=p[0], z=p[2], y_from=ch.floor_y + 3, push=v3(ch.d))))
            for i in range(2):
                p = ch.world_point(rng.uniform(-0.4, 0.5) * ch.r[0], rng.uniform(-0.4, 0.4) * ch.r[2], ch.floor_y)
                self.intents.append(("dropper", dict(kind="icicle", x=p[0], z=p[2], y_floor=ch.floor_y, ceiling_from=ch.floor_y + 3)))
            self.text(ch.arrival + ch.d * 5, 6.0, "Spines underfoot, and more hanging above.")
        elif kind == "swing":
            self.chasm(ch, min(12.0, ch.r[0] * 0.42), 18.0, spacing=8.5)
            self.text(ch.arrival + ch.d * 5, 7.0, "Hook the pillar tops and keep your feet off the floor.")
        elif kind == "lore":
            c = ch.world_point(rng.uniform(-0.3, 0.3) * ch.r[0], rng.uniform(-0.3, 0.3) * ch.r[2], ch.floor_y)
            for i in range(5):
                q = c + np.array([rng.uniform(-4, 4), 0, rng.uniform(-4, 4)])
                self.prop(rng.choice(CORPSES), q, yaw=rng.uniform(0, 6.28))
            self.prop(A + "Tent.glb", c + np.array([5, 0, 2]), yaw=rng.uniform(0, 6.28))
            self.fire(c + np.array([1.5, 0, -1.0]), 0.5)
            self.intents.append(("ember", dict(pos=c + np.array([-2.0, 0, 1.5]))))
            self.text(c, 8.0, rng.choice([
                "A camp. They got this far, set the fire, and never packed it up.",
                "Five of them, around a fire that went out a long time ago.",
                "Someone slept here. The bedding still holds the shape of a body.",
            ]))
        elif kind == "pit":
            for i in range(4):
                p = ch.world_point(rng.uniform(-0.55, 0.6) * ch.r[0], rng.uniform(-0.5, 0.5) * ch.r[2], ch.floor_y)
                self.intents.append(("vent", dict(x=p[0], z=p[2], y=ch.floor_y + 3)))
            self.text(ch.arrival + ch.d * 5, 6.0, "Gas vents. They flare on their own time.")
        elif kind == "crystals":
            self.scatter_floor(ch, 14, lambda p: self.intents.append(("crystal", dict(pos=p, s=rng.uniform(1.0, 2.6)))))
        return ch

    def descent(self, biome, drop, R=10.0, crumble_ratio=0.35, ice=False, glow=None, seg=95.0):
        """A long descent broken into drops of about `seg` m (pre-scale), each followed by a
        horizontal gallery: landing room, a walk, and a ledge room for the next drop. The last
        drop lands in whatever chamber the caller places next."""
        n = max(1, int(round(drop / seg)))
        part = drop / n
        for i in range(n):
            # vary the descents: wide pit, narrow chimney, or a walkable spiral ramp
            style = self._descent_style % 3
            self._descent_style += 1
            if style == 0:
                self.shaft(biome, part, R=R * 1.35, crumble_ratio=crumble_ratio * 0.6, ice=ice, glow=glow,
                           spacing=(13.0, 17.0), big_every=4)
            elif style == 1:
                self.shaft(biome, part, R=R * 0.72, crumble_ratio=min(0.85, crumble_ratio + 0.3), ice=ice, glow=glow,
                           spacing=(8.0, 11.0))
            else:
                self.shaft(biome, part, R=R * 1.1, crumble_ratio=crumble_ratio, ice=ice, glow=glow, spiral=True)
            if i == n - 1:
                break
            dark = (self._feature_i % 7) == 2
            land = self.chamber(biome, self.rng.uniform(18, 24), self.rng.uniform(11, 14), self.rng.uniform(16, 22),
                                amp=(3.0, 2.0, 0.6), name="%s gallery %d" % (BIOMES[biome], i + 1), lights=not dark)
            self.L["tour"].append({"pos": v3(land.arrival + np.array([0, 1.8, 0])),
                                   "look": v3(land.exit + np.array([0, 2, 0])), "label": land.name})
            self.intents.append(("ember", dict(pos=land.arrival + land.d * 3 + land.s * 2)))
            if not dark:
                self.fire(land.arrival + land.d * 2 - land.s * 3, 0.4, energy=0.9, rng=16)
            self.feature(land, self.FEATURES[self._feature_i % len(self.FEATURES)])
            self._feature_i += 1
            turn = self.rng.choice([-1, 1]) * self.rng.uniform(35, 70)
            self.tunnel(biome, [(self.rng.uniform(45, 70), self.rng.uniform(2, 5), turn),
                                (self.rng.uniform(30, 50), self.rng.uniform(1, 4), -turn * 0.6)], r=5.2)
            ledge = self.chamber(biome, self.rng.uniform(22, 28), self.rng.uniform(13, 16), self.rng.uniform(18, 24),
                                 amp=(3.5, 2.0, 0.6), name="%s ledge %d" % (BIOMES[biome], i + 1))
            self.feature(ledge, self.FEATURES[self._feature_i % len(self.FEATURES)])
            self._feature_i += 1
            if biome == CRYSTAL:
                self.feature(ledge, "crystals")

    def chasm(self, ch, half_w, depth, spacing=8.0, spikes=True):
        half_w = half_w * SCALE
        d = ch.d
        tc = np.array([ch.c[0], ch.floor_y, ch.c[2]])
        half_l = ch.r[2] * 0.94 + 9.0
        tr = Trench(ch.biome, tc, ch.yaw, half_w, half_l, ch.floor_y - depth, ch.floor_y + 1.2)
        self.prims.append(tr)
        self.groups.append(ch.group)
        n = max(1, int(math.ceil(2 * half_w / spacing)) - 1)
        step = 2 * half_w / (n + 1)
        for i in range(n):
            lx = -half_w + step * (i + 1)
            lz = self.rng.uniform(-2.2, 2.2)
            p = tc + d * lx + ch.s * lz
            top = ch.floor_y - self.rng.uniform(0.2, 1.4)
            self.columns.append(dict(biome=ch.biome, x=p[0], z=p[2], bottom=ch.floor_y - depth - 3,
                                     top=top, radius=self.rng.uniform(2.4, 2.9), flat=True))
            self.L["lights"].append({"pos": v3([p[0], top + 2.0, p[2]]), "color": GLOW[ch.biome], "energy": 0.7, "range": 14.0})
        # decoy pillars off to the sides, lower and scattered
        for i in range(n):
            lx = self.rng.uniform(-half_w + 4, half_w - 4)
            lz = self.rng.choice([-1, 1]) * self.rng.uniform(9, ch.r[2] * 0.7)
            p = tc + d * lx + ch.s * lz
            self.columns.append(dict(biome=ch.biome, x=p[0], z=p[2], bottom=ch.floor_y - depth - 3,
                                     top=ch.floor_y - self.rng.uniform(4, 9), radius=self.rng.uniform(1.8, 2.6), flat=True))
        # climb-back stairs on the near wall
        k = 1
        while True:
            top = ch.floor_y - depth + 4.2 * k
            if top > ch.floor_y - 3.0:
                break
            self.intents.append(("trench_step", dict(ch=ch, tc=tc, half_w=half_w, top=top, lz=(k % 2) * 5.0 - 2.5)))
            k += 1
        if spikes:
            for i in range(4):
                lx = self.rng.uniform(-half_w + 3, half_w - 3)
                lz = self.rng.uniform(-10, 10)
                p = tc + d * lx + ch.s * lz
                self.intents.append(("spike_bed", dict(x=p[0], z=p[2], y_from=ch.floor_y - depth + 6, push=v3(-d))))
        return {"tc": tc, "half_w": half_w, "depth": depth}

    def side_cave(self, ch, side, length, rise, room=(13.0, 9.0, 13.0), lx_frac=0.0, r=4.8, turn=20.0):
        length = length * SCALE
        room = tuple(v * SCALE for v in room)
        s = ch.s * side
        yaw = math.atan2(s[2], s[0])
        start = np.array([ch.c[0], ch.floor_y, ch.c[2]]) + ch.d * (lx_frac * ch.r[0])
        lat = ch.wall_extent(math.pi / 2 * side, 0.5)
        start = start + s * (lat - 4.0)
        a = np.array([start[0], start[1] + 0.55 * r, start[2]]) - s * 6.0
        d1 = hdir(yaw)
        b = a + d1 * (length * 0.5 + 6.0) + np.array([0, rise * 0.5, 0])
        yaw2 = yaw + math.radians(turn)
        d2 = hdir(yaw2)
        c_ = b + d2 * (length * 0.5) + np.array([0, rise * 0.5, 0])
        t1 = Tunnel(ch.biome, a, b, r)
        t2 = Tunnel(ch.biome, b, c_, r)
        rfloor = c_[1] - 0.55 * r
        rc = c_ + d2 * (room[0] * 0.8)
        rm = Chamber(ch.biome, [rc[0], rfloor + room[1] * 0.35, rc[2]], room, yaw2, rfloor, amp=(1.5, 1.2, 0.5))
        g = self._add([t1, t2, rm], {ch.group, self.group})
        if g is None:
            return None
        self.parent_of[g] = ch.group
        return {"room": rm, "floor": rfloor, "center": np.array([rc[0], rfloor, rc[2]]), "dir": d2}

    def tube(self, ch, local_angle, segs, r0=1.5, true_route=False, name="", decor=None):
        segs = [(l * SCALE, tn, dr, r) for (l, tn, dr, r) in segs]
        if decor:
            decor = dict(decor)
            decor["texts"] = [(t * SCALE, tx) for (t, tx) in decor.get("texts", [])]
            decor["ambience"] = [a * SCALE for a in decor.get("ambience", [])]
        """Plan a tight tube leaving chamber `ch` through its wall at `local_angle`.
        Geometry is resolved in gen.py once the wall position is known. Registers
        phantom prims so nothing else gets placed through it."""
        wdir = math.cos(local_angle) * ch.d + math.sin(local_angle) * ch.s
        yaw = math.atan2(wdir[2], wdir[0])
        lat = ch.wall_extent(local_angle, 1.0)
        start = np.array([ch.c[0], ch.floor_y + 0.55 * r0 + 0.25, ch.c[2]]) + wdir * (lat - 6.0)
        from tubes import plan_waypoints
        pts, rs, end_yaw = plan_waypoints(start, yaw, segs, r0)
        prims = []
        for i in range(len(pts) - 1):
            a, b = pts[i], pts[i + 1]
            if np.linalg.norm(b - a) < 0.5:
                continue
            t = Tunnel(BURROWS, a, b, 4.0, amp=(0, 0, 0))
            t.phantom = True
            prims.append(t)
        # boxes are too coarse for a thin tube next to a small room: test the real path
        # against the real shapes of everything that is not this room or its neighbours
        allow = {self.group, self.group - 1, ch.group, ch.group - 1}
        samples = []
        for i in range(len(pts) - 1):
            a, b = pts[i], pts[i + 1]
            n = max(2, int(np.linalg.norm(b - a) / 2.0))
            for k in range(n):
                samples.append(a + (b - a) * (k / n))
        samples.append(pts[-1])
        for q, g in zip(self.prims, self.groups):
            if g in allow or getattr(q, "phantom", False):
                continue
            for sp in samples:
                if q.kind in ("tunnel", "shaft"):
                    ba = q.b - q.a
                    t = np.clip(((sp - q.a) @ ba) / max(ba @ ba, 1e-6), 0.0, 1.0)
                    if np.linalg.norm(sp - (q.a + t * ba)) < q.r + 5.0:
                        raise RuntimeError("tube %s blocked by %s" % (name, q.kind))
                elif q.kind == "chamber":
                    lq = q.local(sp[None, :])[0]
                    if np.linalg.norm(lq / (q.r + 5.0)) < 1.0:
                        raise RuntimeError("tube %s blocked by chamber %s" % (name, q.name))
        self.group += 1
        g = self.group
        self.extra_allow.add(g)
        for t in prims:
            self.prims.append(t)
            self.groups.append(g)
        plan = dict(ch=ch, start=start, wdir=wdir, pts=pts, rs=rs, end_yaw=end_yaw, true_route=true_route,
                    name=name, decor=decor or {}, group=g)
        self.tube_plans.append(plan)
        if true_route:
            end = pts[-1]
            self.cursor = np.array([end[0], end[1] - 0.55 * rs[-1], end[2]])
            self.heading = end_yaw
            self.last_tube = plan
        return plan

    # ------------------------------------------------------------ placement intents

    def prop(self, scene, pos, yaw=0.0, scale=1.0, rot_x=0.0, box=None, snap=True, vis=320.0):
        self.intents.append(("prop", dict(scene=scene, pos=np.array(pos, dtype=float), yaw=yaw,
                                          scale=scale, rot_x=rot_x, box=box, snap=snap, vis=vis)))

    def light(self, pos, color, energy=1.0, rng=22.0, snap=False, lift=2.0):
        self.intents.append(("light", dict(pos=np.array(pos, dtype=float), color=color, energy=energy,
                                           range=rng, snap=snap, lift=lift)))

    def fire(self, pos, scale=0.6, light=True, energy=1.3, rng=20.0, beacon=False):
        self.intents.append(("fire", dict(pos=np.array(pos, dtype=float), scale=scale, light=light,
                                          energy=energy, range=rng, beacon=beacon)))

    def bell(self, ch, lx_frac=0.0, lz_frac=0.0, scale=2.2):
        """A hanging bell. Hook it and every centipede comes to the sound."""
        p = ch.world_point(lx_frac * ch.r[0], lz_frac * ch.r[2], ch.floor_y)
        self.intents.append(("bell", dict(x=float(p[0]), z=float(p[2]), y=ch.floor_y, scale=scale)))

    def text(self, pos, r, text):
        self.L["texts"].append({"pos": v3(np.array(pos) + np.array([0, 1.5, 0])), "r": r, "text": text})

    def checkpoint(self, ch, label):
        cid = len(self.L["checkpoints"])
        p = ch.arrival + (ch.d * 5.0 if not ch.from_shaft else np.zeros(3))
        self.intents.append(("checkpoint", dict(id=cid, x=p[0], z=p[2], y=ch.floor_y, label=label, biome=ch.biome)))
        return cid

    def scatter_floor(self, ch, n, fn, min_r=0.15, max_r=0.8, avoid=None):
        for i in range(n):
            for _ in range(8):
                lx = self.rng.uniform(-max_r, max_r) * ch.r[0]
                lz = self.rng.uniform(-max_r, max_r) * ch.r[2]
                if (lx / ch.r[0]) ** 2 + (lz / ch.r[2]) ** 2 > max_r ** 2:
                    continue
                if (lx / ch.r[0]) ** 2 + (lz / ch.r[2]) ** 2 < min_r ** 2:
                    continue
                if avoid is not None and abs(lx) < avoid:
                    continue
                p = ch.world_point(lx, lz, ch.floor_y)
                fn(p)
                break

    def ceiling_spikes(self, ch, n):
        for i in range(n):
            lx = self.rng.uniform(-0.6, 0.6) * ch.r[0]
            lz = self.rng.uniform(-0.6, 0.6) * ch.r[2]
            p = ch.world_point(lx, lz, ch.floor_y + 3.0)
            self.intents.append(("stalactite", dict(pos=p, scale=self.rng.uniform(0.09, 0.2), yaw=self.rng.uniform(0, 6.28))))

    def plinth(self, ch, local_angle, height):
        """A solid shelf on the chamber wall with its top `height` above the floor."""
        key = self.next_id("pl")
        self.intents.append(("plinth", dict(ch=ch, ang=local_angle, height=height, key=key)))
        return key


# ================================================================ the route

def build(seed):
    R = Route(seed)
    rng = R.rng
    L = R.L

    # ---------------------------------------------------------- 0 THE MOUTH
    bowl = R.bowl((0.0, 0.0, 0.0), 58.0)
    L["start"] = {"pos": v3([-30.0, 2.6, 6.0]), "yaw": godot_yaw_facing(np.array([1.0, 0.0, 0.0]))}
    R.prop(A + "Tent.glb", [-36, 0, 12], yaw=0.6)
    R.prop(A + "Tent.glb", [-40, 0, 2], yaw=-0.3)
    R.fire([-31, 0, 1], 0.8, energy=1.8, rng=28)
    R.intents.append(("ember", dict(pos=np.array([-28.0, 0, 11.0]))))
    for p in ([-20, 0, 20], [-8, 0, -26], [18, 0, 30]):
        R.prop(rng.choice(CORPSES), p, yaw=rng.uniform(0, 6.28))
    R.text([-30, 0, 6], 9.0, "A long way down. She said the idol is at the bottom. You believed her.")
    R.text([38, 0, 0], 8.0, "The mouth of it. Sand shelves rumble before they go. Stone holds.")
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
    R.fire(m1.world_point(-8, 6, m1.floor_y), 0.7)
    R.scatter_floor(m1, 5, lambda p: R.prop(rng.choice(CORPSES), p, yaw=rng.uniform(0, 6.28)))
    R.ceiling_spikes(m1, 6)
    R.feature(m1, "lore")
    R.text(m1.arrival, 8.0, "Below the hall, the floor is gone.")
    R.light(m1.world_point(0, 0, m1.floor_y), [0.9, 0.75, 0.6], 0.6, 30, lift=10)
    R.descent(OSSUARY, 180, R=10.0, crumble_ratio=0.45)

    # ---------------------------------------------------------- 1 OSSUARY
    o1 = R.chamber(OSSUARY, 38, 17, 30, name="Bone Hall")
    R.checkpoint(o1, BIOMES[OSSUARY])
    R.fire(o1.arrival + o1.d * 4 + o1.s * 3, 0.55, energy=0.9, rng=16)
    R.intents.append(("ember", dict(pos=o1.arrival + o1.d * 3 - o1.s * 3)))
    R.scatter_floor(o1, 22, lambda p: R.prop(rng.choice(CORPSES), p, yaw=rng.uniform(0, 6.28), scale=rng.uniform(0.8, 1.1)))
    R.ceiling_spikes(o1, 10)
    R.text(o1.arrival, 9.0, "Someone laid them here. Rows of them. You do not look at the faces.")
    dead_end = R.side_cave(o1, -1, 38, 2.0, room=(11, 8, 11), r=4.2)
    if dead_end:
        for i in range(9):
            q = dead_end["center"] + np.array([rng.uniform(-6, 6), 0, rng.uniform(-6, 6)])
            R.prop(rng.choice(CORPSES), q, yaw=rng.uniform(0, 6.28))
        L["ambience"].append({"pos": v3(dead_end["center"] + np.array([0, 2, 0])), "sounds": BREATHS, "min": 6.0, "max": 14.0, "range": 26.0, "db": -2.0})
        R.text(dead_end["center"], 6.0, "A dead end. The breathing is closer here.")
    R.light(o1.world_point(0, 0, o1.floor_y), [0.85, 0.8, 0.65], 0.35, 28, lift=9)
    t = R.tunnel(OSSUARY, [(45, 5, 0), (40, 6, 50), (45, 7, -60), (40, 5, 30)], r=4.3, amp=(0.0, 1.1, 0.45))
    torches = []
    pts = t["points"]
    for i in range(6):
        seg = min(i // 2, len(pts) - 2)
        f = (i % 2) * 0.5 + 0.25
        p = pts[seg] + (pts[seg + 1] - pts[seg]) * f
        torches.append(p)
    did = R.next_id("dl")
    R.intents.append(("dying_lights", dict(id=did, points=torches, r=4.3)))
    for i in range(len(pts) - 1):
        mid = (pts[i] + pts[i + 1]) * 0.5
        L["ambience"].append({"pos": v3(mid), "sounds": BREATHS + WHISPERS, "min": 18.0, "max": 40.0, "range": 30.0, "db": -6.0})
    o2 = R.chamber(OSSUARY, 30, 20, 30, name="Ossuary Well")
    R.scatter_floor(o2, 12, lambda p: R.prop(rng.choice(CORPSES), p, yaw=rng.uniform(0, 6.28)))
    R.text(o2.arrival, 8.0, "Something pale is coiled in the dark. It does not move while you watch it.")
    R.bell(o2, lx_frac=-0.45, lz_frac=0.15, scale=2.4)
    R.text(o2.world_point(-0.45 * o2.r[0], 0.15 * o2.r[2] + 7, o2.floor_y), 7.0,
           "A bell, hung from the roof by the old miners. Throw your hook at it. Anything hunting will come to the sound instead of to you.")
    R.ceiling_spikes(o2, 6)
    stalk1_home = o2.world_point(-4, 12, o2.floor_y + 6)
    z1 = [[v3([o2.c[0], o2.floor_y, o2.c[2]]), 40.0]]
    R.descent(OSSUARY, 200, R=10.0, crumble_ratio=0.75)
    o3a = R.chamber(OSSUARY, 26, 15, 24, name="Ossuary Landing")
    R.feature(o3a, "dark")
    R.scatter_floor(o3a, 6, lambda p: R.prop(rng.choice(CORPSES), p, yaw=rng.uniform(0, 6.28)))
    z1.append([v3([o3a.c[0], o3a.floor_y, o3a.c[2]]), 34.0])
    t = R.tunnel(OSSUARY, [(55, 9, -20)], r=4.6)
    z1.append([v3((t["points"][0] + t["points"][-1]) * 0.5), 34.0])
    o3 = R.chamber(OSSUARY, 48, 22, 36, name="Ossuary Chasm")
    R.chasm(o3, 15.0, 22.0, spacing=9.5)
    z1.append([v3([o3.c[0], o3.floor_y, o3.c[2]]), 56.0])
    R.scatter_floor(o3, 8, lambda p: R.prop(rng.choice(CORPSES), p, yaw=rng.uniform(0, 6.28)), min_r=0.45)
    R.text(o3.arrival, 8.0, "Hook the pillars and swing. Stairs on the near wall, if you fall.")
    R.light(o3.world_point(0, 0, o3.floor_y - 18), [0.9, 0.3, 0.2], 1.0, 26)
    L["stalkers"].append({"id": "stalker1", "home": v3(stalk1_home), "zone": z1, "speed": 26.0})

    # ---------------------------------------------------------- 9 THE BURROWS
    # A small room with three holes barely wider than your shoulders. Two go nowhere.
    t = R.tunnel(OSSUARY, [(32, 5, 15)], r=4.4)
    bm = R.chamber(BURROWS, 15, 8, 13, amp=(1.6, 1.0, 0.4), name="Burrow Mouth")
    R.checkpoint(bm, "THE BURROWS")
    R.text(bm.arrival, 7.0, "Three holes, low in the wall. One goes through. You will have to crawl.")
    R.scatter_floor(bm, 4, lambda p: R.prop(rng.choice(CORPSES), p, yaw=rng.uniform(0, 6.28)), min_r=0.3)
    L["ambience"].append({"pos": v3([bm.c[0], bm.floor_y + 2, bm.c[2]]), "sounds": WHISPERS, "min": 9.0, "max": 20.0, "range": 24.0, "db": -4.0})
    # the real way: 110 m, two vertical holes, two pinch points
    R.tube(bm, 0.0, [(14, 0, 0, 1.55), (10, -35, 1, 1.4), (9, 45, 2, 1.25), (0, 0, 7, 1.3), (11, -50, 1, 1.5),
                     (14, 30, 2, 1.28), (0, 0, 8, 1.3), (12, -40, 1, 1.6), (10, 25, 1, 1.25), (14, 10, 2, 1.7)],
           r0=1.55, true_route=True, name="the way through",
           decor=dict(candles=13.0, texts=[(6.0, "Barely wider than your shoulders. You go in on your hands and knees."),
                                           (52.0, "It narrows. Breathe out and push."),
                                           (86.0, "You hear the others breathing. Or something is."),],
                      ambience=[30.0, 70.0]))
    # dead end A: bends away and ends at a body with an ember
    R.tube(bm, math.radians(100), [(10, 0, 0, 1.5), (12, -55, 2, 1.35), (9, -40, 1, 1.25), (5, 0, 0, 1.6)],
           r0=1.5, name="dead end A", decor=dict(end_corpse=True, end_ember=True, end_text="It ends. Someone got this far and stopped. Back out, feet first."))
    # dead end B: a drop into a pocket full of bones, no way on
    R.tube(bm, math.radians(-118), [(14, 0, 1, 1.5), (0, 0, 6, 1.3), (10, -60, 1, 1.3), (8, 30, 0, 2.2)],
           r0=1.5, name="dead end B", decor=dict(end_corpse=True, end_corpses=4, end_text="A pocket of bones. No way on. The hole you dropped through is above you."))
    br = R.chamber(BURROWS, 13, 9, 12, amp=(1.6, 1.0, 0.4), name="Breathing Room")
    R.text(br.arrival, 6.0, "You can stand. Your knees are bleeding. Ahead, green light.")
    R.feature(br, "lore")
    R.intents.append(("ember", dict(pos=br.arrival + br.d * 4 + br.s * 2)))
    R.fire(br.arrival + br.d * 3 - br.s * 3, 0.4, energy=0.8, rng=14)

    # ---------------------------------------------------------- 2 FUNGAL HOLLOW
    t = R.tunnel(FUNGAL, [(45, 10, 15), (30, 8, -10)], r=5.5)
    R.light(t["points"][1], [0.4, 1.0, 0.7], 0.9, 20)
    f1 = R.chamber(FUNGAL, 60, 30, 48, name="Fungal Hollow")
    R.checkpoint(f1, BIOMES[FUNGAL])
    R.fire(f1.arrival + f1.d * 4 + f1.s * 3, 0.55, energy=0.8)
    R.intents.append(("ember", dict(pos=f1.arrival + f1.d * 3 - f1.s * 3)))
    R.text(f1.arrival, 10.0, "The light down here grows. Three pieces of the idol were hidden in the deep. The foundry door wants all three.")
    R.scatter_floor(f1, 70, lambda p: R.prop(rng.choice(PLANTS_L), p, yaw=rng.uniform(0, 6.28), scale=rng.uniform(2.5, 6.0)), min_r=0.1, max_r=0.9)
    R.scatter_floor(f1, 60, lambda p: R.prop(rng.choice(PLANTS_S), p, yaw=rng.uniform(0, 6.28), scale=rng.uniform(3.0, 7.0)), min_r=0.1, max_r=0.9)
    for i in range(10):
        lx = rng.uniform(-0.75, 0.75) * f1.r[0]
        lz = rng.uniform(-0.75, 0.75) * f1.r[2]
        R.light(f1.world_point(lx, lz, f1.floor_y), rng.choice([[0.3, 1.0, 0.6], [0.4, 0.8, 1.0], [0.7, 1.0, 0.3]]), 0.9, 16, snap=True, lift=1.2)
    for i in range(6):
        cp = f1.world_point(rng.uniform(-0.6, 0.6) * f1.r[0], rng.uniform(-0.6, 0.6) * f1.r[2], 0)
        R.columns.append(dict(biome=FUNGAL, x=float(cp[0]), z=float(cp[2]), bottom=f1.floor_y - 2,
                              top=f1.c[1] + f1.r[1] + 6, radius=rng.uniform(1.4, 2.4), flat=False))
    frag1 = R.side_cave(f1, 1, 52, 7.0, room=(14, 9, 14))
    if frag1 is None:
        raise RuntimeError("fragment 1 cave blocked")
    L["fragments"].append({"id": "frag1", "pos": v3(frag1["center"] + np.array([0, 1.4, 0]))})
    R.light(frag1["center"], [0.6, 0.9, 1.0], 1.2, 18, lift=3)
    R.text(frag1["center"] - frag1["dir"] * 8, 6.0, "Something glints in the moss.")
    t = R.tunnel(FUNGAL, [(50, 6, 20)], r=5.5)
    f2 = R.chamber(FUNGAL, 42, 26, 40, name="Kiln Hall")
    R.text(f2.arrival, 9.0, "Four kilns, cold. Light them all.")
    gate_k = "gate_kilns"
    kiln_spots = [("floor", -0.2, 0.55), ("floor", 0.25, -0.6), ("wall", math.radians(100), 7.5), ("wall", math.radians(-95), 9.0)]
    for idx, spot in enumerate(kiln_spots):
        if spot[0] == "floor":
            p = f2.world_point(spot[1] * f2.r[0], spot[2] * f2.r[2], f2.floor_y)
            R.intents.append(("kiln", dict(gate=gate_k, idx=idx, x=p[0], z=p[2], y=f2.floor_y + 4, plinth=None)))
        else:
            key = R.plinth(f2, spot[1], spot[2])
            R.intents.append(("kiln", dict(gate=gate_k, idx=idx, plinth=key)))
    R.scatter_floor(f2, 30, lambda p: R.prop(rng.choice(PLANTS_L), p, yaw=rng.uniform(0, 6.28), scale=rng.uniform(2.5, 5.0)), min_r=0.2)
    t = R.tunnel(FUNGAL, [(55, 10, -20)], r=5.5)
    R.intents.append(("gate", dict(id=gate_k, kind="kilns", need=4, tunnel=t, dist=12.0)))
    f3 = R.chamber(FUNGAL, 34, 20, 30, name="Spore Drop")
    R.feature(f3, "swing")
    R.scatter_floor(f3, 20, lambda p: R.prop(rng.choice(PLANTS_L), p, yaw=rng.uniform(0, 6.28), scale=rng.uniform(2.5, 5.0)))
    R.descent(ROOTS, 260, R=12.5, crumble_ratio=0.3, glow=[0.4, 1.0, 0.6])

    # ---------------------------------------------------------- 3 ROOTWORKS
    r0 = R.chamber(ROOTS, 30, 16, 28, name="Root Landing")
    R.checkpoint(r0, BIOMES[ROOTS])
    R.fire(r0.arrival + r0.d * 4 + r0.s * 3, 0.6)
    R.intents.append(("ember", dict(pos=r0.arrival + r0.d * 3 - r0.s * 3)))
    R.text(r0.arrival, 8.0, "Roots of something that should not be this deep.")
    t = R.tunnel(ROOTS, [(55, 8, 10)], r=6.0)
    r1 = R.chamber(ROOTS, 72, 34, 40, name="Root Chasm")
    R.chasm(r1, 22.0, 28.0, spacing=11.0)
    for i in range(14):
        lx = rng.uniform(-0.8, 0.8) * r1.r[0]
        lz = rng.choice([-1, 1]) * rng.uniform(0.3, 0.75) * r1.r[2]
        p = r1.world_point(lx, lz, 0)
        R.columns.append(dict(biome=ROOTS, x=p[0], z=p[2], bottom=r1.floor_y - 30, top=r1.c[1] + r1.r[1] + 8,
                              radius=rng.uniform(0.9, 1.8), flat=False))
    R.text(r1.arrival, 9.0, "The ground is gone. Only the roots hold.")
    R.light(r1.world_point(0, 0, r1.floor_y - 24), [0.9, 0.55, 0.2], 1.2, 30)
    t = R.tunnel(ROOTS, [(60, 12, 30)], r=6.0)
    r2 = R.chamber(ROOTS, 40, 22, 34, name="Root Nest")
    cen1 = R.next_id("cen")
    L["centipedes"].append({"id": cen1, "trigger": [v3(r2.arrival), 12.0],
                            "spawn": [v3(r2.world_point(0.86 * r2.r[0], 0, r2.floor_y + 5))]})
    R.text(r2.arrival, 8.0, "The roots are moving. No. Something is moving through them.")
    R.descent(DROWNED, 230, R=11.0, crumble_ratio=0.55)

    # ---------------------------------------------------------- 4 DROWNED GALLERIES
    d0 = R.chamber(DROWNED, 34, 18, 30, name="Drowned Landing")
    R.checkpoint(d0, BIOMES[DROWNED])
    R.fire(d0.arrival + d0.d * 4 + d0.s * 3, 0.55)
    R.intents.append(("ember", dict(pos=d0.arrival + d0.d * 3 - d0.s * 3)))
    R.text(d0.arrival, 8.0, "The water left. The mist stayed.")
    t = R.tunnel(DROWNED, [(45, 6, -15)], r=5.5)
    d2 = R.chamber(DROWNED, 44, 22, 44, name="Plate Hall")
    gate_p = "gate_plates"
    R.text(d2.arrival, 9.0, "Four plates. Everyone stands on one. Alone, the door will not wait for you.")
    plate_spots = [("floor", 0.0, 0.0), ("floor", 0.35, 0.62), ("wall", math.radians(-110), 6.5), ("wall", math.radians(115), 8.0)]
    for idx, spot in enumerate(plate_spots):
        if spot[0] == "floor":
            p = d2.world_point(spot[1] * d2.r[0], spot[2] * d2.r[2], d2.floor_y)
            R.intents.append(("plate", dict(gate=gate_p, idx=idx, x=p[0], z=p[2], y=d2.floor_y + 4, plinth=None)))
        else:
            key = R.plinth(d2, spot[1], spot[2])
            R.intents.append(("plate", dict(gate=gate_p, idx=idx, plinth=key)))
    zd = [[v3([d2.c[0], d2.floor_y, d2.c[2]]), 50.0]]
    t = R.tunnel(DROWNED, [(50, 8, 25)], r=5.5)
    R.intents.append(("gate", dict(id=gate_p, kind="plates", need=0, tunnel=t, dist=10.0)))
    zd.append([v3((t["points"][0] + t["points"][-1]) * 0.5), 34.0])
    d3 = R.chamber(DROWNED, 50, 22, 38, name="Mist Chasm")
    R.chasm(d3, 16.0, 24.0, spacing=11.5)
    zd.append([v3([d3.c[0], d3.floor_y, d3.c[2]]), 58.0])
    R.text(d3.arrival, 8.0, "You cannot see the bottom. Good.")
    cen_d = R.next_id("cen")
    L["centipedes"].append({"id": cen_d, "trigger": [v3(d3.arrival), 12.0],
                            "spawn": [v3(d3.world_point(0.85 * d3.r[0], 0.2 * d3.r[2], d3.floor_y + 4))]})
    L["stalkers"].append({"id": "stalker2", "home": v3(d3.world_point(0.7 * d3.r[0], 10, d3.floor_y + 6)), "zone": zd, "speed": 30.0})
    for i in range(3):
        L["ambience"].append({"pos": v3(d3.world_point(rng.uniform(-30, 30), rng.uniform(-20, 20), d3.floor_y - 10)),
                              "sounds": BREATHS, "min": 10.0, "max": 25.0, "range": 40.0, "db": 0.0})
    t = R.tunnel(DROWNED, [(50, 14, -30)], r=5.5)
    d4 = R.chamber(DROWNED, 30, 18, 28, name="Drowned Drop")
    R.feature(d4, "gauntlet")
    R.descent(VILLAGE, 240, R=12.0, crumble_ratio=0.4)

    # ---------------------------------------------------------- 5 SUNKEN VILLAGE
    v1 = R.chamber(VILLAGE, 84, 46, 70, amp=(6.0, 3.0, 0.8), name="Sunken Village")
    R.checkpoint(v1, BIOMES[VILLAGE])
    R.fire(v1.arrival + v1.d * 5 + v1.s * 3, 0.7)
    R.intents.append(("ember", dict(pos=v1.arrival + v1.d * 4 - v1.s * 4)))
    R.text(v1.arrival, 10.0, "A whole village fell into the dark. Some of it is still falling.")
    houses = [(-0.05, 0.35, 1.0), (0.2, -0.4, 0.9), (0.45, 0.3, 1.1), (-0.35, -0.45, 0.8), (0.05, -0.05, 0.75), (0.6, -0.15, 0.95), (-0.25, 0.1, 0.85)]
    frag_house = 4
    for i, (hx, hz, sc) in enumerate(houses):
        p = v1.world_point(hx * v1.r[0], hz * v1.r[2], v1.floor_y)
        R.prop(A + "Village_Building.glb", p, yaw=rng.uniform(0, 6.28), scale=sc, box=[5.6, 7.05, 5.6])
        R.light(p + np.array([0, 5 * sc, 0]), [1.0, 0.6, 0.25], 0.9, 16)
        if i == frag_house:
            R.intents.append(("fragment_on_roof", dict(id="frag2", x=p[0], z=p[2], y=v1.floor_y + 14.11 * sc)))
            R.text(p + v1.d * 12, 7.0, "Something glints on that roof.")
    for i in range(10):
        p = v1.world_point(rng.uniform(-0.7, 0.7) * v1.r[0], rng.uniform(-0.7, 0.7) * v1.r[2], v1.floor_y)
        R.prop(A + "Village_Structure_0%d.glb" % rng.randint(1, 4), p, yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.0, 1.6))
    for i in range(2):
        lx = rng.uniform(-0.55, 0.55) * v1.r[0]
        lz = rng.uniform(-0.55, 0.55) * v1.r[2]
        R.intents.append(("hanging_tower", dict(pos=v1.world_point(lx, lz, v1.floor_y + 10), scene=A + "Ghost_Tower_0%d.glb" % rng.randint(1, 3), yaw=rng.uniform(0, 6.28))))
    tp = v1.world_point(0.32 * v1.r[0], -0.1 * v1.r[2], v1.floor_y)
    R.intents.append(("dropper", dict(kind="tower", x=tp[0], z=tp[2], y_floor=v1.floor_y, ceiling_from=v1.floor_y + 3)))
    R.scatter_floor(v1, 14, lambda p: R.prop(rng.choice(CORPSES), p, yaw=rng.uniform(0, 6.28)), min_r=0.2)
    t = R.tunnel(VILLAGE, [(40, 8, 30), (35, 8, 10)], r=5.5)
    amb = R.next_id("cen")
    mid = t["points"][1]
    L["centipedes"].append({"id": amb, "trigger": [v3(mid + np.array([0, -2, 0])), 7.0],
                            "spawn": [v3(t["points"][0] + np.array([0, 2.5, 0]))]})
    R.text(mid, 6.0, "Did the wall just breathe?")
    v2 = R.chamber(VILLAGE, 36, 20, 32, name="Village Well")
    R.feature(v2, "boulders")
    R.prop(A + "WaterWheel.glb", v2.world_point(-6, 10, v2.floor_y), yaw=rng.uniform(0, 6.28), scale=1.2)
    R.descent(CRYSTAL, 250, R=11.5, crumble_ratio=0.3, ice=True, glow=[0.5, 0.75, 1.0])

    # ---------------------------------------------------------- 6 CRYSTAL VEINS
    x0 = R.chamber(CRYSTAL, 32, 18, 30, name="Crystal Landing")
    R.checkpoint(x0, BIOMES[CRYSTAL])
    R.fire(x0.arrival + x0.d * 4 + x0.s * 3, 0.55)
    R.intents.append(("ember", dict(pos=x0.arrival + x0.d * 3 - x0.s * 3)))
    R.text(x0.arrival, 8.0, "Cold light. The ice shelves tilt toward the pit. Keep moving, or hook in.")
    R.scatter_floor(x0, 14, lambda p: R.intents.append(("crystal", dict(pos=p, s=rng.uniform(1.0, 2.6)))))
    t = R.tunnel(CRYSTAL, [(50, 10, 0), (50, 12, 35), (40, 8, -20)], r=5.5)
    for i in range(len(t["points"]) - 1):
        a_, b_ = t["points"][i], t["points"][i + 1]
        for f in (0.35, 0.75):
            p = a_ + (b_ - a_) * f
            R.intents.append(("dropper", dict(kind="icicle", x=p[0], z=p[2], y_floor=p[1] - 0.55 * 5.5, ceiling_from=p[1])))
        R.intents.append(("crystal", dict(pos=a_ + (b_ - a_) * 0.5 + side_dir(0) * 0, s=1.4)))
    x2 = R.chamber(CRYSTAL, 46, 22, 36, name="Crystal Chasm")
    R.chasm(x2, 14.0, 22.0, spacing=12.5)
    R.scatter_floor(x2, 16, lambda p: R.intents.append(("crystal", dict(pos=p, s=rng.uniform(1.0, 2.4)))), min_r=0.45)
    cen_x = R.next_id("cen")
    L["centipedes"].append({"id": cen_x, "trigger": [v3(x2.arrival + x2.d * 10), 11.0],
                            "spawn": [v3(x2.world_point(-0.85 * x2.r[0], -0.3 * x2.r[2], x2.floor_y + 4))]})
    frag3 = R.side_cave(x2, -1, 46, 5.0, room=(13, 9, 13), lx_frac=0.62)
    if frag3 is None:
        frag3 = R.side_cave(x2, 1, 46, 5.0, room=(13, 9, 13), lx_frac=0.62)
    if frag3 is None:
        raise RuntimeError("fragment 3 cave blocked")
    L["fragments"].append({"id": "frag3", "pos": v3(frag3["center"] + np.array([0, 1.4, 0]))})
    R.light(frag3["center"], [0.6, 0.9, 1.0], 1.2, 18, lift=3)
    for i in range(5):
        R.intents.append(("crystal", dict(pos=frag3["center"] + np.array([rng.uniform(-7, 7), 0, rng.uniform(-7, 7)]), s=rng.uniform(1.2, 2.6))))
    R.text(x2.arrival, 8.0, "Across the chasm, a side passage glows.")
    t = R.tunnel(CRYSTAL, [(50, 10, 20)], r=5.5)
    x3 = R.chamber(CRYSTAL, 34, 20, 30, name="Crystal Drop")
    R.feature(x3, "gap")
    R.scatter_floor(x3, 10, lambda p: R.intents.append(("crystal", dict(pos=p, s=rng.uniform(1.0, 2.2)))))
    R.descent(FOUNDRY, 230, R=11.0, crumble_ratio=0.35, ice=True)

    # ---------------------------------------------------------- 7 THE FOUNDRY
    k0 = R.chamber(FOUNDRY, 40, 22, 34, name="Foundry")
    R.checkpoint(k0, BIOMES[FOUNDRY])
    R.fire(k0.arrival + k0.d * 4 + k0.s * 3, 0.6)
    R.intents.append(("ember", dict(pos=k0.arrival + k0.d * 3 - k0.s * 3)))
    R.text(k0.arrival, 9.0, "The kilns still burn. The door ahead wears the mark of the idol.")
    for i in range(6):
        p = k0.world_point(rng.uniform(-0.6, 0.6) * k0.r[0], rng.choice([-1, 1]) * rng.uniform(0.35, 0.65) * k0.r[2], k0.floor_y)
        R.prop(rng.choice([A + "Ancient_Kiln.glb", A + "Broken_Kiln.glb"]), p, yaw=rng.uniform(0, 6.28), scale=rng.uniform(1.0, 1.6))
        R.light(p, [1.0, 0.45, 0.15], 1.4, 18, lift=3)
    R.prop(A + "Ancient_Kiln_Deco.glb", k0.world_point(0.1 * k0.r[0], 0, k0.floor_y), yaw=0.0, scale=1.0)
    for i in range(5):
        p = k0.world_point(rng.uniform(-0.5, 0.7) * k0.r[0], rng.uniform(-0.5, 0.5) * k0.r[2], k0.floor_y)
        R.intents.append(("vent", dict(x=p[0], z=p[2], y=k0.floor_y + 3)))
    t = R.tunnel(FOUNDRY, [(40, 6, 0), (25, 4, 15)], r=5.5)
    R.intents.append(("gate", dict(id="gate_idol", kind="idol", need=3, tunnel=t, dist=12.0)))
    k2 = R.chamber(FOUNDRY, 44, 24, 38, name="Slag Hall")
    for i in range(6):
        p = k2.world_point(rng.uniform(-0.6, 0.7) * k2.r[0], rng.uniform(-0.55, 0.55) * k2.r[2], k2.floor_y)
        R.intents.append(("vent", dict(x=p[0], z=p[2], y=k2.floor_y + 3)))
    for i in range(3):
        p = k2.world_point(rng.uniform(-0.4, 0.6) * k2.r[0], rng.uniform(-0.4, 0.4) * k2.r[2], k2.floor_y)
        R.intents.append(("dropper", dict(kind="boulder", x=p[0], z=p[2], y_floor=k2.floor_y, ceiling_from=k2.floor_y + 3)))
    R.light(k2.world_point(0, 0, k2.floor_y), [1.0, 0.4, 0.12], 1.6, 40, lift=8)
    t = R.tunnel(FOUNDRY, [(40, 6, -15)], r=6.0)

    # THE CRUCIBLE: giant monkey bars over a lava pit. Swing, let go, throw again.
    cr = R.chamber(FOUNDRY, 80, 28, 30, amp=(3.0, 1.8, 0.6), name="The Crucible")
    R.checkpoint(cr, "THE CRUCIBLE")
    R.intents.append(("ember", dict(pos=cr.arrival + cr.d * 3 - cr.s * 3)))
    R.text(cr.arrival, 9.0, "No floor. Only the bars and the heat. Swing, let go at the top, throw again. Not every bar holds your weight.")
    lava_half = 56.0
    lava_depth = 14.0
    tc = np.array([cr.c[0], cr.floor_y, cr.c[2]])
    tr = Trench(FOUNDRY, tc, cr.yaw, lava_half, cr.r[2] * 0.94 + 9.0, cr.floor_y - lava_depth, cr.floor_y + 1.2, amp=(0.0, 0.8, 0.3))
    R.prims.append(tr)
    R.groups.append(cr.group)
    L["lava"].append({"center": v3(tc + np.array([0, -lava_depth + 1.5, 0])), "yaw": cr.yaw,
                      "half_w": lava_half + 2.0, "half_l": cr.r[2] * 0.94 + 9.0, "kill_top": round(-lava_depth + 5.0, 2)})
    gaps = [8.0, 8.0, 8.0, 8.0, 9.0, 9.0, 9.0, 9.0, 10.0, 10.0, 10.0]
    lx = -lava_half + 6.0
    heights = [13.0, 13.5, 12.5, 14.0, 13.0, 14.5, 12.5, 14.0, 15.0, 13.0, 14.5, 13.5]
    for i in range(12):
        p = tc + cr.d * lx + cr.s * rng.uniform(-1.0, 1.0)
        top = cr.floor_y + heights[i]
        R.intents.append(("bar", dict(idx=i, pos=np.array([p[0], top, p[2]]), yaw=cr.yaw, length=12.0,
                                      width=2.6, thick=0.8, lava_y=cr.floor_y - lava_depth + 1.5, sink=(i == 6))))
        if i < len(gaps):
            lx += gaps[i]
    far_edge = lx + 7.0
    R.text(tc + cr.d * (lava_half + 6.0), 7.0, "You made it across. Your hands are shaking.")
    for k in range(8):
        f = -lava_half + k * (2 * lava_half / 7.0)
        for side in (-1, 1):
            q = tc + cr.d * f + cr.s * side * (cr.r[2] * 0.55)
            R.light(q + np.array([0, -lava_depth + 3, 0]), [1.0, 0.42, 0.1], 2.2, 34)
    t = R.tunnel(FOUNDRY, [(48, 6, -40)], r=6.0)
    k3 = R.chamber(FOUNDRY, 32, 18, 28, name="Crucible Exit")
    R.checkpoint(k3, "PAST THE CRUCIBLE")
    R.fire(k3.arrival + k3.d * 4 + k3.s * 3, 0.6)
    R.descent(NEST, 200, R=11.0, crumble_ratio=0.5)

    # ---------------------------------------------------------- 8 THE NEST
    n0 = R.chamber(NEST, 30, 16, 26, name="Nest Landing")
    R.checkpoint(n0, BIOMES[NEST])
    R.fire(n0.arrival + n0.d * 4 + n0.s * 3, 0.6)
    R.intents.append(("ember", dict(pos=n0.arrival + n0.d * 3 - n0.s * 3)))
    R.intents.append(("ember", dict(pos=n0.arrival + n0.d * 3 + n0.s * 5)))
    R.text(n0.arrival, 8.0, "This is where they come from.")
    t = R.tunnel(NEST, [(50, 10, -10)], r=6.5)
    nest_tunnel = t
    n1 = R.chamber(NEST, 70, 40, 66, amp=(6.0, 3.0, 0.8), name="The Nest")
    cen = R.next_id("cen")
    L["centipedes"].append({"id": cen, "trigger": [v3(n1.arrival + n1.d * 14), 10.0],
                            "spawn": [v3(nest_tunnel["points"][0] + np.array([0, 2.5, 0]))]})
    cen2 = R.next_id("cen")
    L["centipedes"].append({"id": cen2, "on": "idol",
                            "spawn": [v3(n1.world_point(0.2 * n1.r[0], 0.86 * n1.r[2], n1.floor_y + 5)),
                                      v3(n1.world_point(0.3 * n1.r[0], -0.86 * n1.r[2], n1.floor_y + 5)),
                                      v3(n1.world_point(-0.6 * n1.r[0], 0.5 * n1.r[2], n1.floor_y + 5))]})
    for i in range(3):
        bp = n1.world_point(rng.uniform(0.45, 0.8) * n1.r[0], rng.uniform(-0.35, 0.35) * n1.r[2], n1.floor_y)
        R.intents.append(("dropper", dict(kind="boulder", x=bp[0], z=bp[2], y_floor=n1.floor_y, ceiling_from=n1.floor_y + 3)))
    R.scatter_floor(n1, 30, lambda p: R.prop(rng.choice(CORPSES), p, yaw=rng.uniform(0, 6.28)), min_r=0.15, avoid=None)
    for i in range(10):
        p = n1.world_point(rng.uniform(-0.6, 0.6) * n1.r[0], rng.choice([-1, 1]) * rng.uniform(0.3, 0.7) * n1.r[2], n1.floor_y)
        R.prop(A + "Spikes_01.glb", p, yaw=rng.uniform(0, 6.28), scale=rng.uniform(0.08, 0.16))
    R.ceiling_spikes(n1, 16)
    for i in range(8):
        R.light(n1.world_point(rng.uniform(-0.7, 0.7) * n1.r[0], rng.uniform(-0.7, 0.7) * n1.r[2], n1.floor_y), [1.0, 0.15, 0.1], 1.0, 22, snap=True, lift=2)
    altar = n1.world_point(0.72 * n1.r[0], 0, n1.floor_y)
    R.intents.append(("altar", dict(x=altar[0], z=altar[2], y=n1.floor_y + 4)))
    R.text(n1.arrival, 10.0, "At the far end, on the altar, it waits. Like she said.")
    R.bell(n1, lx_frac=-0.35, lz_frac=0.45, scale=3.0)
    for i in range(4):
        L["ambience"].append({"pos": v3(n1.world_point(rng.uniform(-50, 50), rng.uniform(-40, 40), n1.floor_y + 8)),
                              "sounds": SNARLS + BREATHS, "min": 8.0, "max": 20.0, "range": 50.0, "db": 0.0})
    t = R.tunnel(NEST, [(45, 4, 20)], r=6.0)
    R.intents.append(("gate", dict(id="gate_exit", kind="exit", need=0, tunnel=t, dist=9.0)))
    asc = R.chamber(NEST, 26, 34, 22, amp=(3.0, 1.5, 0.5), name="The Ascent")
    L["finish"].append({"pos": v3(asc.world_point(0.25 * asc.r[0], 0.0, asc.floor_y + 2.0)), "r": 7.0})
    R.light(asc.world_point(0.2 * asc.r[0], 0.0, asc.floor_y), [1.0, 0.95, 0.85], 3.0, 60.0, lift=30.0)
    R.light(asc.world_point(0.2 * asc.r[0], 0.0, asc.floor_y), [1.0, 0.9, 0.7], 1.2, 30.0, lift=6.0)
    R.text(asc.arrival, 8.0, "Light, far above. Take it home.")

    # the ones who came before: a ghost stands where the way continues, in every room
    # that has an onward exit. They fade when you come close.
    for i, ch in enumerate(R.chambers[:-1]):
        nxt = R.chambers[i + 1]
        if nxt.from_shaft:
            # the way on is down: stand at the lip of the hole, looking into it
            hole = np.array([ch.c[0], ch.floor_y, ch.c[2]]) + hdir(math.atan2(ch.d[2], ch.d[0])) * (0.55 * ch.r[0])
            away = hole - np.array([ch.c[0], ch.floor_y, ch.c[2]])
            n = away / max(np.linalg.norm(away), 1e-6)
            spot = hole - n * (ch.r[0] * 0.2 + 6.0)
            R.intents.append(("ghost", dict(pos=spot, face=n)))
        else:
            R.intents.append(("ghost", dict(pos=ch.exit - ch.d * 5.0, face=ch.d)))

    # tour stops for the debug camera: every chamber from its arrival point
    for ch in R.chambers:
        eye = ch.arrival + np.array([0, 1.8, 0]) - ch.d * (0 if ch.from_shaft else 2)
        L["tour"].append({"pos": v3(eye), "look": v3([ch.c[0], ch.floor_y + 4, ch.c[2]]) if not ch.from_shaft else v3(ch.exit + np.array([0, 3, 0])),
                          "label": ch.name})
    return R
