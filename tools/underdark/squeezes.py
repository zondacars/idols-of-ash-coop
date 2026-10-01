"""THE SQUEEZES (ZondaCoopSync 5.1, owner plan 2026-09-30: "a squeeze at each big biome change",
"different flavor for sure").

Where the old route steps from one biome's last balcony down to the next biome's first one in the
open rift, a crawl tube now runs through the rock between the two: a small room cut into the wall at
the end of the balcony above, the tube, a small room behind the first ledge below, a short passage out
onto that ledge. The old balconies and everything else stay exactly where they were (own random
stream, builder restored). Each one is a part boundary (L["squeezes"], layer true): the big ones stay
behind (underdark.gd, owner decision 7A)."""
import math
import random
import numpy as np

from world import v3
from wave2 import _with_rng

SQUEEZE_SEED = 51077
TILT = {"the Vent": 0.5}       # radians the tube leaves its top room turned toward the bottom one (a clean mouth)
FLAVOR = {
    # name: (biome of the tube's look, tube radius, shape, decor, the text at its mouth)
    "the Throat": (0, 1.45, "chimney", {"bones": 7.0},
                   "A crack in the wall, taller than it is wide. Cold air comes up it from below. It goes down."),
    "the Culvert": (4, 1.6, "pipe", {},
                    "A round pipe of fitted stone, half full of black water. The galleries drained this way once."),
    "the Crypt Gap": (5, 1.35, "crawl", {"bones": 4.5},
                      "Under the last houses, a gap between the coffins they lowered into the rock. You will have to crawl over them."),
    "the Vent": (7, 1.55, "chimney", {},
                 "Hot air breathes out of this hole in steady sighs. It smells of iron. Something is burning far below."),
}


def squeeze_side(B, name):
    """A crawl tube from the last balcony above (B.shelves[-1]) to where the next one will start
    (B.a, B.y, not built yet). Returns the L["squeezes"] entry, or None (it did not fit: a warning)."""
    from sdf import Tunnel
    R, L, rift = B.R, B.L, B.rift
    biome, r0, shape, decor, text = FLAVOR[name]
    rng2 = random.Random(SQUEEZE_SEED + sum(ord(ch) for ch in name))
    S = B.shelves[-1]
    a_A, y_A, dirn = float(S["a1"]), float(S["y"]), int(S["dirn"])
    a_B, y_B = float(B.a), float(B.y)
    saved = dict(a=B.a, y=B.y, dirn=B.dirn, cursor=np.array(R.cursor, dtype=float), heading=R.heading, landing=R.landing,
                 group=R.group, n_prims=len(R.prims), n_ch=len(R.chambers), n_tp=len(R.tube_plans), n_int=len(R.intents),
                 lens={k: len(v) for k, v in L.items() if isinstance(v, list)}, extra=set(R.extra_allow),
                 n_zones=len(L.get("zones", [])))
    out = {}

    def build():
        # the room at the top: 4 m back from the balcony's far end, cut into the wall
        rA = float(rift.wall_r(a_A, y_A))
        a_in = a_A - dirn * (4.0 / rA)
        B.y = y_A
        B.enter_wall(a_in)
        R.tunnel(biome, [(5.0, 0.0, 0.0)], r=3.3, amp=(0.0, 0.5, 0.3))
        ch1 = R.chamber(biome, 7.0, 4.2, 7.0, amp=(1.4, 0.9, 0.3), name=name + ", the way in", lights=False)
        # the room at the bottom: 15 m into the rock behind where the next balcony starts
        rB = float(rift.wall_r(a_B, y_B))
        cxB, czB = rift.center(y_B)
        out_dir = np.array([math.cos(a_B), 0.0, math.sin(a_B)])
        back = np.array([float(cxB), y_B, float(czB)]) + out_dir * (rB + 17.0)
        R.cursor = back.copy()
        R.heading = math.atan2(-out_dir[2], -out_dir[0])          # facing the rift
        R.landing = None
        R.extra_allow = set(R.extra_allow) | {R.group}
        ch2 = R.chamber(biome, 7.0, 4.2, 7.0, amp=(1.4, 0.9, 0.3), name=name + ", the way out", lights=False)
        # the tube between them: out of ch1 toward ch2, kept inside the rock, in the squeeze's own shape
        start = np.array([ch1.c[0], ch1.floor_y + 0.55 * r0 + 0.25, ch1.c[2]])
        endp = np.array([ch2.c[0], ch2.floor_y + 0.55 * r0 + 0.25, ch2.c[2]])
        d = endp - start
        flat = np.array([d[0], 0.0, d[2]])
        L2 = float(np.linalg.norm(flat))
        u = flat / max(L2, 1e-6)
        side = np.array([-u[2], 0.0, u[0]])
        # "deeper into the rock" is away from the rift axis
        mid = 0.5 * (start + endp)
        cxm, czm = rift.center(mid[1])
        deep = np.array([mid[0] - float(cxm), 0.0, mid[2] - float(czm)])
        deep /= max(np.linalg.norm(deep), 1e-6)
        if side @ deep < 0:
            side = -side
        drop = float(start[1] - endp[1])
        c1x, c1z = rift.center(start[1])
        deep1 = np.array([start[0] - float(c1x), 0.0, start[2] - float(c1z)])
        deep1 /= max(np.linalg.norm(deep1), 1e-6)
        c2x, c2z = rift.center(endp[1])
        deep2 = np.array([endp[0] - float(c2x), 0.0, endp[2] - float(c2z)])
        deep2 /= max(np.linalg.norm(deep2), 1e-6)
        tilt = TILT.get(name, 0.0)                                 # turn the departure toward ch2 a little where needed
        dep = deep1 * math.cos(tilt) + u * math.sin(tilt)
        dep /= max(np.linalg.norm(dep), 1e-6)
        wl = start + dep * 9.0                                     # leave ch1 level, through its deep wall
        way = [start, wl]
        rs = [r0 + 0.25, r0]
        if shape == "chimney":
            # a short crawl, then a crack that drops most of the way, then a crawl out
            a1 = wl + side * 6.0 + u * (L2 * 0.25)
            a2 = a1 + np.array([0.0, -drop * 0.7, 0.0])
            a3 = a2 + u * (L2 * 0.3) - side * 3.0 + np.array([0.0, -drop * 0.15, 0.0])
            way += [a1, a2, a3]
            rs += [r0, r0 + 0.15, r0]
        elif shape == "pipe":
            # dead straight and round, a steady fall
            for k in (0.33, 0.66):
                way.append(wl + (endp - wl) * k + side * 5.0 * math.sin(math.pi * k))
                rs.append(r0)
        else:
            # "crawl": low, wide, winding
            for k in (0.25, 0.5, 0.75):
                way.append(wl + (endp - wl) * k + side * (7.0 if k == 0.5 else 3.5))
                rs.append(r0 + 0.1)
        way.append(endp + deep2 * 9.0)                            # come into ch2 through its deep wall
        way.append(endp)
        rs += [r0, r0 + 0.25]
        pts = np.array(way, dtype=float)
        # the tube must stay in rock: check it against every prim that is not one of its own rooms
        own = {ch1.group, ch2.group, R.group, R.group - 1, R.group - 2, R.group - 3}
        samples = []
        for i in range(len(pts) - 1):
            a, b = pts[i], pts[i + 1]
            n = max(2, int(np.linalg.norm(b - a) / 2.0))
            for k in range(n):
                samples.append(a + (b - a) * (k / n))
        for q, g in zip(R.prims, R.groups):
            if g in own or getattr(q, "phantom", False) or q.kind == "rift":
                continue
            for sp in samples[2:-2]:
                if q.kind in ("tunnel", "shaft"):
                    ba = q.b - q.a
                    t = np.clip(((sp - q.a) @ ba) / max(ba @ ba, 1e-6), 0.0, 1.0)
                    if np.linalg.norm(sp - (q.a + t * ba)) < q.r + 4.0:
                        raise RuntimeError("tube blocked by a tunnel")
                elif q.kind == "chamber":
                    lq = q.local(sp[None, :])[0]
                    if np.linalg.norm(lq / (q.r + 4.0)) < 1.0:
                        raise RuntimeError("tube blocked by chamber %s" % q.name)
        # and 6 m clear of the rift's open air (a tube is a mesh in rock: it must not poke out)
        from sdf import noise_fields
        S2 = np.array(samples[2:-2])
        if len(S2):
            m0, m1, m2 = noise_fields(S2)
            e = rift.e(S2, m0, m1, m2)[0]
            if float(e.min()) < 5.0:
                raise RuntimeError("tube comes within %.1f m of the open rift" % float(e.min()))
        g = R.group + 1
        R.group = g
        for i in range(len(pts) - 1):
            a, b = pts[i], pts[i + 1]
            if np.linalg.norm(b - a) < 0.5:
                continue
            t = Tunnel(biome, a, b, 4.0, amp=(0, 0, 0))
            t.phantom = True
            R.prims.append(t)
            R.groups.append(g)
        wdir = pts[1] - pts[0]
        wdir = wdir / max(np.linalg.norm(wdir), 1e-6)
        dec = dict(decor)
        dec["texts"] = []
        plan = dict(ch=ch1, start=pts[0], wdir=wdir, pts=pts, rs=np.array(rs, dtype=float), end_yaw=math.atan2(u[2], u[0]),
                    true_route=True, name=name, decor=dec, group=g, biome=biome, squeeze=True, shape=shape)
        R.tube_plans.append(plan)
        # the way out onto the next balcony: from ch2 straight out of the wall at the balcony's start
        exit_out = np.array([float(cxB), y_B, float(czB)]) + out_dir * (rB - 3.0)
        a_pt = np.array([ch2.c[0], ch2.floor_y + 0.55 * 3.4, ch2.c[2]])
        b_pt = np.array([exit_out[0], y_B + 0.55 * 3.4, exit_out[2]])
        t2 = Tunnel(biome, a_pt, b_pt, 3.4, amp=(0.0, 0.5, 0.3))
        R.group += 1
        R.prims.append(t2)
        R.groups.append(R.group)
        R.text(np.array([ch1.arrival[0], y_A, ch1.arrival[2]]), 6.0, text)
        out["entry"] = {"name": name, "pos": v3(0.5 * (pts[0] + pts[-1])), "top": round(y_A + 2.0, 2), "bottom": round(y_B - 2.0, 2),
                        "r": round(max(14.0, L2 * 0.6), 1), "layer": True, "open": False, "flavor": shape,
                        "path": [v3(p) for p in pts], "radius": r0, "mouth": v3(ch1.arrival), "exit": v3(exit_out),
                        "biome": biome}

    try:
        _with_rng(B, rng2, build)
    except RuntimeError as e:
        # it did not fit: put everything back as it was and leave a warning
        del R.prims[saved["n_prims"]:]
        del R.groups[saved["n_prims"]:]
        del R.chambers[saved["n_ch"]:]
        del R.tube_plans[saved["n_tp"]:]
        del R.intents[saved["n_int"]:]
        for k, n in saved["lens"].items():
            if isinstance(L.get(k), list):
                del L[k][n:]
        R.group = saved["group"]
        R.extra_allow = saved["extra"]
        L.setdefault("warnings_gen", []).append("squeeze %s not built: %s" % (name, e))
        print("squeeze %s not built: %s" % (name, e))
        out.clear()
    # the route goes on exactly where it was going
    B.a, B.y, B.dirn = saved["a"], saved["y"], saved["dirn"]
    R.cursor, R.heading, R.landing = saved["cursor"], saved["heading"], saved["landing"]
    if not out:
        return None
    L.setdefault("squeezes", []).append(out["entry"])
    P = np.array(out["entry"]["path"])
    print("squeeze %s: %d m drop, %.0f m of tube" % (name, round(y_A - y_B), float(np.sum(np.linalg.norm(np.diff(P, axis=0), axis=1)))))
    return out["entry"]


def squeeze_passage(B, name, flavor, points, top, bottom, mouth, exit_p):
    """A squeeze that is a passage the route already takes (the Kiln Gate, the Spillway, the Adit):
    only its L["squeezes"] entry (a part boundary) and its flavour for the runtime."""
    B.L.setdefault("squeezes", []).append({"name": name, "pos": v3(0.5 * (np.array(mouth) + np.array(exit_p))),
                                           "top": round(float(top), 2), "bottom": round(float(bottom), 2), "r": 30.0,
                                           "layer": True, "open": False, "flavor": flavor,
                                           "path": [v3(p) for p in points], "mouth": v3(mouth), "exit": v3(exit_p)})
