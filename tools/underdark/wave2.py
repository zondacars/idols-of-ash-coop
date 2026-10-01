"""THE UNDERDARK, wave 2 (ZondaCoopSync 5.1): DRY GULCH, the weird-west ghost town.

The Drowned Galleries end at THE SPILLWAY: a balcony, then a steep drain through the rock (the way the
lake left) that comes out on the dry bed of that lake. The bed is a slab of mud and stone that seals
the rift wall to wall, like the Lid, and a ghost mining town stands on it in the dark. The only way on
is THE ADIT, a mine tunnel in the far wall that winds down under the bed and comes out over the
Sunken Village.

Everything below the town is the same route as before, built from the same random numbers, only 90 m
lower: the rift gets a 90 m tall vertical section at the town's depth (rift_gap), the strata, the lava
lake and the rift's foot move down with it. All new content draws from its own random stream, so the
old stream (and with it every later choice) is untouched.

The town's buildings, boardwalks and props are not cave geometry: they are written to L["town"] and
built at runtime by town.gd (wood, collision, signs, interiors)."""
import math
import random
import numpy as np

from world import v3, godot_yaw_facing, A, X, DROWNED, VILLAGE
from sdf_rift import _rift_e

DRYGULCH = 12
GAP = 90.0                  # how much lower everything under the town sits
DISH = 2.5                  # the middle of the lake bed sits this much lower than where the tunnels open
PLUG_THICK = 22.0
SPILL_R = 3.2
ADIT_R = 3.4
TOWN_SEED = 51051


def _smooth(x):
    # 0 inside 62% of the radius, 1 past 85%: the gentle shore of the lake bed
    k = np.clip((np.asarray(x, dtype=np.float64) - 0.62) / 0.23, 0.0, 1.0)
    return k * k * (3.0 - 2.0 * k)


def bed_y(rift, y_top, p):
    """The lake bed's height (no noise) at world point p."""
    cx, cz = rift.center(y_top)
    R = float(rift.radius(y_top))
    d = math.hypot(p[0] - float(cx), p[2] - float(cz))
    return y_top - DISH * (1.0 - float(_smooth(d / max(R, 1.0))))


class TownPlugSolid:
    """The dry lake bed: a slab from wall to wall with a flat top (the town stands on it), the shore
    rising a little toward the walls. It reaches only 6 m into the wall, so the mine can pass close by."""
    kind = "plug"

    def __init__(self, rift, y_top, y_bot):
        self.rift = rift
        self.y_top = y_top
        self.y_bot = y_bot
        self.look = DRYGULCH

    def aabb(self):
        lo, hi = self.rift.aabb()
        return np.array([lo[0], self.y_bot - 6, lo[2]]), np.array([hi[0], self.y_top + 10, hi[2]])

    def sdf(self, P, n0, n1, n2, ctx):
        e, d, cx, cz = _rift_e(P, n0, n1, n2, ctx)
        R = np.asarray(self.rift.radius(P[:, 1]), dtype=np.float64)
        top = self.y_top - DISH * (1.0 - _smooth(d / np.maximum(R, 1.0))) + 0.25 * n1
        bot = self.y_bot - 2.5 * n1
        s_y = np.maximum(P[:, 1] - top, bot - P[:, 1])
        return np.maximum(s_y, e - 6.0)


def rift_gap(B, y_ins, dy):
    """Stretch the rift: everything under y_ins moves dy lower; the rift is a straight shaft between.
    Rift.center / radius read rift.gap (sdf_rift.py), so the field stays picklable for the meshers."""
    rift = B.rift
    rift.gap = (y_ins, dy)
    rift.y_bot -= dy
    new = []
    cut = False
    for (t, b, bi) in rift.strata:
        if b >= y_ins:
            new.append([t, b, bi])                        # wholly above
        elif t <= y_ins:
            if not cut:
                new.append([y_ins, y_ins - dy, DRYGULCH])
                cut = True
            new.append([t - dy, b - dy, bi])              # wholly below: moves down
        else:
            # the stratum the town cuts (the Sunken Village's top): the band above the cut goes to the
            # biome above (the Spillway is the Drowned's last balcony), then the town, then the rest
            if new:
                new[-1][1] = y_ins
            new.append([y_ins, y_ins - dy, DRYGULCH])
            new.append([y_ins - dy, b - dy, bi])
            cut = True
    rift.strata = [tuple(x) for x in new]
    B.L["strata"] = [{"top": t, "bottom": b, "biome": bi} for (t, b, bi) in rift.strata]


def _with_rng(B, rng2, fn):
    """Run fn with the builder's random stream swapped for rng2, so the old stream is untouched."""
    saved = (B.rng, B.R.rng, B.shelf_i)
    B.rng = rng2
    B.R.rng = rng2
    try:
        return fn()
    finally:
        B.rng, B.R.rng = saved[0], saved[1]
        B.shelf_i = saved[2]


def dry_gulch(B):
    """Build the Spillway, the lake bed, the town plan and the Adit. On return the builder stands at
    the Adit's mouth over the Sunken Village (B.a, B.y), with the old direction of travel."""
    import rift_world as RW
    rng2 = random.Random(TOWN_SEED)
    R, L, rift = B.R, B.L, B.rift
    y0 = B.y
    dirn0 = B.dirn
    rift_gap(B, y0 + 2.0, GAP)
    lake0 = RW.LAKE_Y
    out = {}

    def build():
        # ---------------------------------------------------------------- THE SPILLWAY (squeeze 5)
        info = B.shelf(DROWNED, 34, lobe_p=17.0, p=13.0, label="THE SPILLWAY")
        R.text(info["pts"][1], 9.0, "A stone channel cut into the wall, worn smooth. The lake went out this way. It still smells of it.")
        a_in = 0.5 * (info["a0"] + info["a1"])
        B.enter_wall(a_in)
        # out into the rock, round, and back toward the rift, always down: the drain
        t1 = R.tunnel(DRYGULCH, [(12, 2.0, 0), (16, 8.0, 85), (18, 9.0, 0), (16, 8.0, 85), (10, 4.0, 10)],
                      r=SPILL_R, amp=(0.0, 0.6, 0.35))
        t2 = B.tunnel_to_rift(DRYGULCH, r=SPILL_R, slope=0.05)
        y_town = float(B.y)
        mouth = np.array(R.cursor, dtype=float)
        a_s = rift.bearing(mouth)
        out["spill"] = dict(t1=t1, t2=t2, mouth=mouth, a=a_s, y=y_town)
        import squeezes as SQ
        SQ.squeeze_passage(B, "the Spillway", "spillway", list(t1["points"]) + list(t2["points"]), y0 + 2.0, y_town + 16.0,
                           t1["points"][0], mouth)
        # ---------------------------------------------------------------- the lake bed
        B.solids.append(TownPlugSolid(rift, y_town - 0.15, y_town - PLUG_THICK))
        out["plug"] = (y_town, y_town - PLUG_THICK)
        town = plan_town(B, rng2, mouth, a_s, y_town)
        out["town"] = town
        # ---------------------------------------------------------------- THE ADIT (squeeze 6)
        a_far = a_s + math.pi
        B.y = y_town
        B.enter_wall(a_far)
        t3 = R.tunnel(DRYGULCH, [(14, 0.0, 0), (20, 6.0, 80), (22, 7.0, 0), (20, 6.0, 80), (22, 7.0, 0), (18, 6.0, 80), (12, 4.0, 15)],
                      r=ADIT_R, amp=(0.0, 0.5, 0.3))
        t4 = B.tunnel_to_rift(VILLAGE, r=4.6, slope=0.10)
        out["adit"] = dict(t3=t3, t4=t4)
        import squeezes as SQ
        SQ.squeeze_passage(B, "the Adit", "mine", list(t3["points"]) + list(t4["points"]), y_town - 4.0, float(B.y) - 2.0,
                           t3["points"][0], t4["points"][-1])
        return out

    res = _with_rng(B, rng2, build)
    town = res["town"]
    # the Adit's mouth is the old route's next start: step back so the balcony is under the mouth
    r_ = B.rw()
    B.a = B.a - dirn0 * (6.0 / r_)
    B.dirn = dirn0
    mouth2 = np.array(R.cursor, dtype=float)
    town["adit_exit"] = v3(mouth2)
    # the old route below goes on exactly where it did, as far under its old start as the Adit came
    # out: every old fixed depth (and the lava lake) moves down by that much (rift_world.sy)
    drop = float(y0 - B.y)
    RW.GAP_AT = (y0 + 2.0, drop)
    RW.LAKE_Y = lake0 - drop
    # the stations of the town walk, in route order (stand points the validators check)
    for (p, kind) in town["walk"]:
        B.station(np.array(p), kind, DRYGULCH, "DRY GULCH" if kind == "town_arrive" else "")
    B.checkpoint(np.array(town["walk"][0][0]), "DRY GULCH", DRYGULCH)
    L["town"] = town
    L["town_meta"] = {"gap": GAP, "route_drop": round(drop, 2), "gap_top": round(y0 + 2.0, 2), "plug": [round(res["plug"][0], 2), round(res["plug"][1], 2)],
                      "spill_mouth": v3(res["spill"]["mouth"]), "spill_bearing": round(res["spill"]["a"], 4)}
    return town


# ==================================================================== the town plan

KINDS = [
    # (kind, sign, w, d, storeys, enterable)
    ("saloon", "SALOON", 16.0, 18.0, 2, True),
    ("hotel", "HOTEL", 15.0, 16.0, 2, True),
    ("bank", "BANK", 11.0, 13.0, 1, True),
    ("jail", "SHERIFF  JAIL", 12.0, 13.0, 1, True),
    ("store", "GENERAL STORE", 14.0, 15.0, 1, True),
    ("undertaker", "UNDERTAKER", 10.0, 13.0, 1, True),
    ("assay", "ASSAY OFFICE", 10.0, 12.0, 1, False),
    ("barber", "BARBER", 9.0, 11.0, 1, False),
    ("telegraph", "TELEGRAPH", 9.0, 11.0, 1, False),
    ("livery", "LIVERY STABLE", 16.0, 16.0, 1, True),
    ("smith", "BLACKSMITH", 13.0, 12.0, 1, False),
    ("boarding", "ROOMS", 13.0, 14.0, 2, False),
    ("feed", "FEED  GRAIN", 12.0, 13.0, 1, False),
    ("doctor", "DOCTOR", 9.0, 12.0, 1, False),
    ("guns", "GUNSMITH", 9.0, 11.0, 1, False),
    ("post", "POST OFFICE", 10.0, 11.0, 1, False),
    ("news", "THE GULCH GAZETTE", 11.0, 12.0, 1, False),
    ("house", "", 10.0, 11.0, 1, False),
    ("house", "", 9.0, 10.0, 1, False),
    ("house", "", 11.0, 12.0, 2, False),
]

STREET_HALF = 9.0           # half the width of the main street
WALK_W = 3.2                # boardwalk depth
WALK_H = 0.55               # boardwalk height over the street
PLAZA_HALF = 16.0           # the cross street / plaza, along the main street
TOWN_HALF = 112.0           # the main street runs -TOWN_HALF .. +TOWN_HALF


def _yaw_from_dir(d):
    # Godot yaw so a node's -Z faces direction d (x, z)
    return round(float(math.atan2(-d[0], -d[1])), 4)


def plan_town(B, rng, mouth, a_s, y_t):
    rift = B.rift
    cx, cz = rift.center(y_t)
    c = np.array([float(cx), y_t, float(cz)])
    Rr = float(rift.radius(y_t))
    u = np.array([float(c[0] - mouth[0]), 0.0, float(c[2] - mouth[2])])
    u /= max(np.linalg.norm(u), 1e-6)
    v = np.array([-u[2], 0.0, u[0]])

    def P(s, t, h=0.0):
        q = c + u * s + v * t
        return [round(float(q[0]), 3), round(float(bed_y(rift, y_t, q) + h), 3), round(float(q[2]), 3)]

    buildings = []
    walks = []
    slots = []
    for side in (1.0, -1.0):
        s = -TOWN_HALF + rng.uniform(0.0, 4.0)
        while s < TOWN_HALF - 6.0:
            if -PLAZA_HALF - 2.0 < s + 6.0 and s < PLAZA_HALF + 2.0:
                s = PLAZA_HALF + 2.0 + rng.uniform(0.0, 2.0)
                continue
            slots.append([side, s])
            s += 13.0 + rng.uniform(3.0, 7.0)
    # the big ones go next to the plaza, the houses at the ends
    slots.sort(key=lambda q: abs(q[1]))
    kinds = list(KINDS)
    while len(kinds) < len(slots):
        kinds.append(("house", "", rng.uniform(9.0, 11.0), rng.uniform(10.0, 12.0), 1, False))
    for i, (side, s) in enumerate(slots):
        kind, sign, w, d, st, enter = kinds[i]
        w = min(w, 16.0)
        # this slot's run along the street, never over the plaza or past the street's end
        s_mid = s + w * 0.5
        if s_mid + w * 0.5 > TOWN_HALF or (abs(s_mid) < PLAZA_HALF + w * 0.5 + 1.0):
            continue
        t_front = side * (STREET_HALF + WALK_W)
        t_mid = t_front + side * d * 0.5
        storey_h = 4.2
        h = storey_h * st
        front = (-v * side)[[0, 2]]
        b = {"id": "bld%d" % (len(buildings) + 1), "kind": kind, "sign": sign, "pos": P(s_mid, t_mid),
             "yaw": _yaw_from_dir(front), "w": round(w, 2), "d": round(d, 2), "h": round(h, 2), "storeys": st,
             "front_h": round(h + rng.uniform(1.6, 3.2), 2), "porch": True, "balcony": kind in ("saloon", "hotel"),
             "open": bool(enter), "lean": round(rng.uniform(-0.035, 0.035), 3) if not enter else 0.0,
             "tint": round(rng.uniform(0.75, 1.1), 3), "lamp": kind in ("saloon", "hotel", "jail") or rng.random() < 0.25}
        buildings.append(b)
        walks.append({"a": P(s_mid - w * 0.5 - 0.5, side * (STREET_HALF + WALK_W * 0.5), WALK_H),
                      "b": P(s_mid + w * 0.5 + 0.5, side * (STREET_HALF + WALK_W * 0.5), WALK_H),
                      "w": WALK_W, "h": WALK_H, "yaw": _yaw_from_dir(u[[0, 2]])})
    # the church at the north end of the cross street, the chapel yard round it
    ch = {"id": "church", "kind": "church", "sign": "", "pos": P(0.0, 62.0), "yaw": _yaw_from_dir((-v)[[0, 2]]),
          "w": 13.0, "d": 22.0, "h": 7.5, "storeys": 1, "front_h": 0.0, "porch": False, "balcony": False,
          "open": True, "lean": 0.0, "tint": 0.85, "lamp": True, "steeple": 16.0, "foundation": 1.3}
    buildings.append(ch)
    props = []
    R = B.R

    def prop(rel, s, t, yaw=None, scale=1.0, h=0.0, col="box", dim=0.34):
        # a CC0 western piece (ext/west/), through the map's normal prop path (snapped to the bed)
        q = np.array(P(s, t, h), dtype=float)
        R.xprop(X + "west/" + rel, q, yaw=rng.uniform(0, 6.283) if yaw is None else yaw, scale=scale, col=col, dim=dim,
                snap=(h == 0.0), vis=260.0)
        props.append(rel)

    # the water tower over the plaza, troughs and hitching rails along the street
    prop("WaterTower.glb", 10.0, -27.0, scale=2.1, col="hull")
    for k in range(10):
        s_ = rng.uniform(-TOWN_HALF + 8, TOWN_HALF - 8)
        if abs(s_) < PLAZA_HALF + 3:
            continue
        side = rng.choice([-1.0, 1.0])
        prop(rng.choice(["Barrier.glb", "Fence.glb"]), s_, side * (STREET_HALF - 0.8), yaw=_yaw_from_dir(u[[0, 2]]), scale=1.3)
    # wagons and barrels in the street: the gunslinger's cover, on the sidewinder's sand
    for k in range(9):
        s_ = rng.uniform(-TOWN_HALF + 12, TOWN_HALF - 16)
        t_ = rng.uniform(-STREET_HALF + 2.5, STREET_HALF - 2.5)
        prop(rng.choice(["WesternCart.glb", "WesternCart_001.glb"]), s_, t_, yaw=_yaw_from_dir(u[[0, 2]]) + rng.uniform(-0.5, 0.5),
             scale=1.25, col="hull")
    for k in range(26):
        s_ = rng.uniform(-TOWN_HALF + 4, TOWN_HALF - 4)
        t_ = rng.choice([-1.0, 1.0]) * rng.uniform(STREET_HALF - 2.5, STREET_HALF - 0.6)
        prop(rng.choice(["WesternBarrel.glb", "WesternBarrel_water.glb", "WesternBarrel_hay.glb", "Crate.glb", "DestroyedCrate.glb"]),
             s_, t_, scale=rng.uniform(0.95, 1.2))
    for k in range(10):
        s_ = rng.uniform(-TOWN_HALF, TOWN_HALF)
        t_ = rng.choice([-1.0, 1.0]) * rng.uniform(40.0, 110.0)
        prop(rng.choice(["DeadTree.glb", "Cactus1.glb", "Cactus2.glb", "Stump.glb", "Log.glb"]), s_, t_, scale=rng.uniform(1.4, 2.4), col=None)
    for k in range(14):
        prop(rng.choice(["Paper1.glb", "Paper2.glb", "Paper3.glb"]), rng.uniform(-TOWN_HALF, TOWN_HALF),
             rng.choice([-1.0, 1.0]) * rng.uniform(2.0, STREET_HALF - 1.0), scale=1.0, col=None)
    # the boats the lake left behind, out on the flats
    boats = []
    for k in range(7):
        s_ = rng.uniform(-150.0, 150.0)
        t_ = rng.choice([-1.0, 1.0]) * rng.uniform(55.0, min(140.0, Rr - 40.0))
        if math.hypot(s_, t_) > Rr - 35.0:
            continue
        boats.append({"pos": P(s_, t_), "yaw": round(rng.uniform(0, 6.283), 3), "len": round(rng.uniform(6.0, 11.0), 2),
                      "roll": round(rng.uniform(-0.5, 0.5), 3), "upturned": rng.random() < 0.35})
    # the clock tower closes the far end of the street, the gallows the near end
    clock = {"pos": P(TOWN_HALF + 7.0, 0.0), "yaw": _yaw_from_dir((-u)[[0, 2]]), "h": 19.0, "w": 6.0}
    gallows = {"pos": P(-TOWN_HALF - 6.0, 0.0), "yaw": _yaw_from_dir(u[[0, 2]])}
    # where the marshal stands to draw: just in front of the clock tower, looking down the street
    marshal = P(TOWN_HALF - 2.0, 0.0, 0.0)
    walk = [(P(-Rr + 26.0, 0.0), "town_arrive"), (P(-TOWN_HALF - 14.0, 0.0), "town"), (P(-60.0, 0.0), "town"), (P(0.0, 0.0), "town"),
            (P(60.0, 0.0), "town"), (P(TOWN_HALF + 16.0, 6.0), "town"), (P(Rr - 26.0, 0.0), "town_adit")]
    lights = []
    for b in buildings:
        if b.get("lamp"):
            lights.append({"pos": [b["pos"][0], b["pos"][1] + 3.4, b["pos"][2]], "bld": b["id"]})
    town = {
        "name": "DRY GULCH", "center": P(0.0, 0.0), "floor": round(y_t - DISH, 3), "shore": round(y_t, 3), "radius": round(Rr, 2),
        "u": [round(float(u[0]), 5), 0.0, round(float(u[2]), 5)], "v": [round(float(v[0]), 5), 0.0, round(float(v[2]), 5)],
        "street": {"half_len": TOWN_HALF, "half_w": STREET_HALF, "walk_w": WALK_W, "walk_h": WALK_H, "plaza_half": PLAZA_HALF},
        "buildings": buildings, "boardwalks": walks, "props": props, "boats": boats,
        "clock": clock, "gallows": gallows, "marshal": marshal, "plaza": [P(0.0, 0.0), 22.0],
        "walk": walk, "lamps": lights,
        "sidewinder": {"home": P(-40.0, -60.0), "count": 1},
    }
    return town


# ==================================================================== wave 2 riders (spec 0: L.rift, L.hearths)

ROMAN = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"]


def rift_riders(B):
    """L["rift"]: the axis and radius every 10 m (rift.gd use_layout) and every great shelf, so the
    runtime never falls back to its wave 1 table (whose layout fingerprint no longer matches)."""
    L, rift = B.L, B.rift
    samples = []
    y = 70.0
    while y > rift.y_bot:
        cx, cz = rift.center(y)
        samples.append([round(y, 2), round(float(cx), 3), round(float(cz), 3), round(float(rift.radius(y)), 3)])
        y -= 10.0
    terr = []
    for i, t in enumerate(B.terraces):
        terr.append({"name": t.get("name") or "THE SHELF %s" % ROMAN[min(i, len(ROMAN) - 1)], "y_top": round(float(t["y_top"]), 3),
                     "bottom": round(float(t["y_top"] - t["thick"] * 1.4), 3), "a_mid": round(float(t["a_mid"]), 6), "k": 0.2,
                     "thick": round(float(t["thick"]), 4), "R": round(float(t["solid"].R), 3)})
    L["rift"] = {"samples": samples, "terraces": terr}


def place_hearths(R, F, report):
    """THE FALSE HEARTH goes live (spec 3.5): 2 spots in the Sunken Village and 2 in the Crystal Veins,
    10-26 m off the walked line, on floor that holds 6 m round (no drop over 2 m), under a ceiling
    12-34 m up that is a chimney the maw can hang in (hearth.gd H1: 8 up rays on a 2.5 m ring meet
    it). Natural ceilings first; where a biome has too few, an overhang of rock is grown out of the
    wall 18 m over a good camp (a new ShelfSolid added to the field before meshing)."""
    from sdf_rift import ShelfSolid
    L = R.L
    rift = R.rift
    st = [s_ for s_ in L["stations"] if s_["kind"] != "hard"]
    stp = np.array([s_["pos"] for s_ in st], dtype=float)
    avoid = [np.array(f["pos"], dtype=float) for f in L.get("fires", [])]
    avoid += [np.array(c.get("pos", [0, 0, 0]), dtype=float) for c in L.get("checkpoints", []) if "pos" in c]

    def ring_floor(c, fy):
        for a2 in np.linspace(0, 2 * math.pi, 8, endpoint=False):
            rq = c + np.array([math.cos(a2) * 6.0, 0.0, math.sin(a2) * 6.0])
            fr = F.floor_below(rq[0], rq[2], fy + 2.5, 5.0)
            if fr is None or fr < fy - 2.0 or fr > fy + 1.5:
                return False
        return True

    def chimney(c, fy):
        up = F.ray_to_rock([c[0], fy + 1.6, c[2]], [0, 1, 0], 40.0, 0.25)
        if up is None or not (12.0 <= up + 1.6 <= 34.0):
            return None
        ceil_c = fy + 1.6 + up
        for a3 in np.linspace(0, 2 * math.pi, 8, endpoint=False):
            rq = [c[0] + math.sin(a3) * 2.5, fy + 1.6, c[2] + math.cos(a3) * 2.5]
            u3 = F.ray_to_rock(rq, [0, 1, 0], 40.0, 0.25)
            if u3 is None or abs(fy + 1.6 + u3 - ceil_c) > 1.0:
                return None
        return ceil_c

    def cands_for(biome):
        out = []
        for s_ in st:
            if s_["biome"] != biome or s_["kind"] not in ("shelf", "terrace", "landing", "span"):
                continue
            p0 = np.array(s_["pos"], dtype=float)
            for ang in np.linspace(0, 2 * math.pi, 16, endpoint=False):
                for rad in (11.0, 14.0, 17.0, 20.0, 24.0):
                    q = p0 + np.array([math.cos(ang) * rad, 0.0, math.sin(ang) * rad])
                    fy = F.floor_below(q[0], q[2], p0[1] + 4.0, 10.0)
                    if fy is None or abs(fy - p0[1]) > 2.5:
                        continue
                    c = np.array([q[0], fy, q[2]])
                    dmin = float(np.min(np.linalg.norm(stp - c, axis=1)))
                    if dmin < 10.0 or dmin > 26.0:
                        continue
                    if any(np.linalg.norm(c - a) < 14.0 for a in avoid):
                        continue
                    if not ring_floor(c, fy):
                        continue
                    out.append((abs(dmin - 16.0), c, fy))
        out.sort(key=lambda e: e[0])
        return out

    picked = []
    for biome, want in ((5, 2), (6, 2)):
        got = 0
        cands = cands_for(biome)
        # natural chimneys first
        for (_, c, fy) in cands:
            if got >= want:
                break
            if any(np.linalg.norm(c - p) < 90.0 for p in picked):
                continue
            ceil = chimney(c, fy)
            if ceil is None:
                continue
            picked.append(c)
            got += 1
            L.setdefault("hearths", []).append({"id": "fh%d" % (len(L.get("hearths", [])) + 1), "pos": v3(c), "ceil": round(float(ceil), 2),
                                                "biome": biome, "yaw": 0.0})
        # then grown ones: an overhang 18 m over the camp, nothing of the route under or over it
        for (_, c, fy) in cands:
            if got >= want:
                break
            if any(np.linalg.norm(c - p) < 90.0 for p in picked):
                continue
            a_mid = rift.bearing(c)
            y_roof = fy + 18.0 + 7.5
            r_w = float(rift.wall_r(a_mid, y_roof - 0.5))
            cx, cz = rift.center(y_roof)
            dc = math.hypot(c[0] - float(cx), c[2] - float(cz))
            prot = r_w - dc + 7.0
            if prot < 8.0 or prot > 40.0:
                continue
            half = 9.0 / max(dc, 1.0)
            clash = False
            for sp in stp:
                ds = math.hypot(sp[0] - c[0], sp[2] - c[2])
                if ds < 16.0 and fy - 3.0 < sp[1] < y_roof + 14.0 and abs(sp[1] - fy) > 2.6:
                    clash = True
                    break
            if clash:
                continue
            roof = ShelfSolid(rift, y_roof, a_mid, half, prot, thick=8.0)          # thick: the mesh cells are 2.5 m
            F.solids.append(roof)
            F.solid_boxes.append(roof.aabb())
            R.solids.append(roof)
            ceil = chimney(c, fy)
            if ceil is None:
                F.solids.pop(); F.solid_boxes.pop(); R.solids.pop()
                continue
            picked.append(c)
            got += 1
            L.setdefault("hearths", []).append({"id": "fh%d" % (len(L.get("hearths", [])) + 1), "pos": v3(c), "ceil": round(float(ceil), 2),
                                                "biome": biome, "yaw": 0.0, "grown": True})
        report.setdefault("hearths", {})[str(biome)] = got
        if got < 1:
            report["warnings"].append("false hearth: no spot in biome %d" % biome)
    print("false hearths placed: %d (%s)" % (len(L.get("hearths", [])), ", ".join("%s%s" % (h["id"], "+roof" if h.get("grown") else "") for h in L.get("hearths", []))))


def home_rooms(R, F, report):
    """v5.1 (the Shade home re-pick): how much walkable floor each possible Shade home has, so the
    runtime prefers roomy ones (on v5.0 five of eleven Shades lived in 6-65 m2 pockets and could only
    ambush someone passing close). A 1 m grid within 24 m of the station: a cell is floor with 2.5 m
    of air over it; cells join when their floors differ by 0.9 m or less; the room is the station's
    own connected patch, in m2. Only shelf and terrace stations of the three Shade biomes."""
    L = R.L
    out = {}
    rad = 24
    g = np.arange(-rad, rad + 1, 1.0)
    GX, GZ = np.meshgrid(g, g, indexing="ij")
    ys = np.arange(3.0, -4.01, -0.25)
    for i, s_ in enumerate(L["stations"]):
        if s_["biome"] not in (1, 2, 4) or s_["kind"] not in ("shelf", "terrace"):
            continue
        p = np.array(s_["pos"], dtype=float)
        n = GX.size
        P = np.empty((n * len(ys), 3))
        P[:, 0] = np.repeat(p[0] + GX.ravel(), len(ys))
        P[:, 2] = np.repeat(p[2] + GZ.ravel(), len(ys))
        P[:, 1] = np.tile(p[1] + ys, n)
        v = F.eval(P).reshape(n, len(ys))            # > 0 rock
        rock = v > 0.0
        fl = np.full(n, np.nan)
        for c in range(n):
            col = rock[c]
            for k in range(1, len(ys)):
                if col[k] and not col[k - 1]:
                    # air above for 2.5 m (10 samples) at least
                    top = max(0, k - 10)
                    if not col[top:k].any() and k >= 10:
                        fl[c] = p[1] + ys[k] + 0.125
                    break
        fl = fl.reshape(GX.shape)
        seen = np.zeros(GX.shape, dtype=bool)
        c0 = (rad, rad)
        if np.isnan(fl[c0]):
            # the station may sit just off its rock: start at the nearest floor cell
            idx = np.argwhere(~np.isnan(fl))
            if len(idx) == 0:
                out[str(i)] = 0
                continue
            d = np.hypot(idx[:, 0] - rad, idx[:, 1] - rad)
            c0 = tuple(idx[int(np.argmin(d))])
            if float(d.min()) > 4.0:
                out[str(i)] = 0
                continue
        stack = [c0]
        seen[c0] = True
        area = 0
        while stack:
            a, b = stack.pop()
            area += 1
            for da, db in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                na, nb = a + da, b + db
                if 0 <= na < fl.shape[0] and 0 <= nb < fl.shape[1] and not seen[na, nb] and not np.isnan(fl[na, nb]):
                    if abs(fl[na, nb] - fl[a, b]) <= 0.9:
                        seen[na, nb] = True
                        stack.append((na, nb))
        out[str(i)] = int(area)
    L["home_room"] = out
    report["home_room"] = {"stations": len(out), "under_80": sum(1 for v in out.values() if v < 80)}
    print("shade home rooms: %d stations measured, %d under 80 m2" % (len(out), report["home_room"]["under_80"]))
