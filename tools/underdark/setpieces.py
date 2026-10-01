"""THE SPAN FALLS and THE CHANDELIER COMES DOWN (ZondaCoopSync 5.1, big-batch contract 3.7 / 3.8).

The Ossuary bridge and the Lid's hanging spikes stop being cave rock: each falling piece is cut out of
the field (the same solid, clipped, so the surface is the one players already know) and meshed on its
own into setpieces.glb; what stays (the bridge's stubs, the spikes' stumps) stays in the cave. The
runtime (maps/underdark/setpieces.gd) builds every piece with collision and plays the fall.

Run from gen.py after resolve (it needs the final field) and before meshing (it edits the field).
Writes L["span"], L["chandelier"], the Miners' Pegs (footholds + stations appended at the END of
L["stations"], so no old station index moves) and setpieces.glb."""
import math
import os
import random
import numpy as np
from skimage.measure import marching_cubes

import sdf
from sdf_rift import ShelfSolid
from world import v3, GLOW, OSSUARY

SPEED = 6.5          # slabs fall back toward you this fast (m/s)
FIRST = 2.0
GAP_PAUSE = 3.0
NEAR_STUB = 20.5
FAR_STUB = 24.0
NEAR_SLABS = 11
FAR_SLABS = 10
FAR_GAP_SLAB = 11.0
SHELF_III = None     # found from the terraces


class Clip:
    """A solid cut to a range along an axis: keep where lo <= (P - origin) . axis <= hi."""
    kind = "clip"

    def __init__(self, solid, origin, axis, lo, hi, look=None):
        self.solid = solid
        self.o = np.array(origin, dtype=np.float64)
        self.ax = np.array(axis, dtype=np.float64) / np.linalg.norm(axis)
        self.lo = lo
        self.hi = hi
        self.look = getattr(solid, "look", None) if look is None else look

    def aabb(self):
        return self.solid.aabb()

    def sdf(self, P, n0, n1, n2, ctx):
        s = self.solid.sdf(P, n0, n1, n2, ctx)
        t = (P - self.o) @ self.ax
        return np.maximum(s, np.maximum(self.lo - t, t - self.hi))


def _mesh_solid(solid, lo, hi, vox, biome, rift):
    """Mesh one solid on its own (marching cubes on -sdf): world vertices, a wall and a floor group."""
    lo = np.floor(np.asarray(lo, dtype=np.float64) / vox) * vox - vox * 2
    hi = np.ceil(np.asarray(hi, dtype=np.float64) / vox) * vox + vox * 2
    n = np.ceil((hi - lo) / vox).astype(int) + 1
    ax = [lo[k] + vox * np.arange(n[k]) for k in range(3)]
    X, Y, Z = np.meshgrid(ax[0], ax[1], ax[2], indexing="ij")
    P = np.stack([X.ravel(), Y.ravel(), Z.ravel()], axis=1)
    out = np.empty(len(P))
    ch = 400000
    for i in range(0, len(P), ch):
        Q = P[i:i + ch]
        m0, m1, m2 = sdf.noise_fields(Q)
        out[i:i + ch] = solid.sdf(Q, m0, m1, m2, {"rift": rift})
    vol = out.reshape(X.shape)
    if vol.min() > 0:
        return None
    verts, faces, _, _ = marching_cubes(vol, 0.0, spacing=(vox, vox, vox), allow_degenerate=False)
    verts = verts + lo
    # normals: the solid's own gradient (outward = increasing sdf)
    h = 0.25
    def f(Q):
        m0, m1, m2 = sdf.noise_fields(Q)
        return solid.sdf(Q, m0, m1, m2, {"rift": rift})
    g = np.stack([f(verts + [h, 0, 0]) - f(verts - [h, 0, 0]), f(verts + [0, h, 0]) - f(verts - [0, h, 0]),
                  f(verts + [0, 0, h]) - f(verts - [0, 0, h])], axis=1)
    nrm = g / np.maximum(np.linalg.norm(g, axis=1, keepdims=True), 1e-9)
    # marching cubes on the sdf winds the faces for "inside = negative": flip so they face out
    faces = faces[:, [0, 2, 1]]
    fn = nrm[faces].mean(axis=1)
    prims = []
    for fl in (False, True):
        m = (fn[:, 1] > 0.55) == fl
        if not m.any():
            continue
        sub = faces[m]
        used, inv = np.unique(sub.ravel(), return_inverse=True)
        prims.append(dict(pos=verts[used].astype(np.float32), nrm=nrm[used].astype(np.float32),
                          ao=np.full(len(used), 0.85, dtype=np.float32), idx=inv.reshape(-1, 3).astype(np.uint32),
                          mat=biome * 2 + (1 if fl else 0)))
    return prims


def _replace_solid(F, R, old, new_list):
    i = F.solids.index(old)
    F.solids[i:i + 1] = new_list
    F.solid_boxes[i:i + 1] = [s.aabb() for s in new_list]
    if old in R.solids:
        j = R.solids.index(old)
        R.solids[j:j + 1] = new_list


def build(R, F, report, out_dir, write_glb):
    L = R.L
    rift = R.rift
    nodes = []
    # ------------------------------------------------------------------ THE SPAN FALLS
    sp = getattr(R, "span_rec", None)
    if sp is not None and len(sp["beams"]) == 2:
        b0, b1 = sp["beams"]
        slabs = []
        # deck distance d from the near stub's edge: near half on b0 after its stub, far half on b1
        cuts0 = np.linspace(NEAR_STUB, b0.L, NEAR_SLABS + 1)
        far_end = b1.L - FAR_STUB
        cuts1 = list(np.linspace(0.0, far_end - FAR_GAP_SLAB, FAR_SLABS + 1)) + [far_end]
        keep = [Clip(b0, b0.a, b0.t, -1.0, NEAR_STUB)]
        keep1 = [Clip(b1, b1.a, b1.t, far_end, b1.L + 1.0)]
        _replace_solid(F, R, b0, keep)
        _replace_solid(F, R, b1, keep1)
        d_far0 = b0.L - NEAR_STUB + 10.0                    # the 10 m mid gap
        for (beam, cuts, half_i) in ((b0, cuts0, 0), (b1, cuts1, 1)):
            for i in range(len(cuts) - 1):
                t0, t1 = float(cuts[i]), float(cuts[i + 1])
                piece = Clip(beam, beam.a, beam.t, t0, t1)
                c = beam.a + beam.t * (0.5 * (t0 + t1))
                ext = np.array([beam.hw * 1.6 + 2.0, beam.thick * 1.6 + 2.0, beam.hw * 1.6 + 2.0])
                ends = np.array([beam.a + beam.t * t0, beam.a + beam.t * t1])
                lo = np.minimum(ends.min(axis=0) - ext, c - ext)
                hi = np.maximum(ends.max(axis=0) + ext, c + ext)
                prims = _mesh_solid(piece, lo, hi, 0.9, OSSUARY, rift)
                if not prims:
                    continue
                name = "sp%02d" % len(slabs)
                nodes.append((name, prims))
                if half_i == 0:
                    d0 = t0 - NEAR_STUB
                    drop_t = FIRST + d0 / SPEED
                else:
                    d0 = d_far0 + t0
                    is_gap = (i == len(cuts) - 2)
                    drop_t = FIRST if is_gap else FIRST + GAP_PAUSE + (d0 - 10.0) / SPEED
                # where it lands (or that it goes on into the dark): straight down from its centre
                fy = F.floor_below(c[0], c[2], c[1] - beam.thick - 3.0, 400.0)
                slabs.append({"node": name, "d0": round(float(d0), 2), "drop_t": round(float(drop_t), 3),
                              "c": v3(c), "axis": v3(beam.t), "half": [round(beam.hw + 0.5, 2), round(beam.thick * 0.5 + 0.8, 2), round(0.5 * (t1 - t0) + 0.3, 2)],
                              "top": round(float(beam.a[1] + beam.t[1] * 0.5 * (t0 + t1)), 2),
                              "lands": None if fy is None else round(float(fy), 2), "far_gap": bool(half_i == 1 and i == len(cuts) - 2)})
        # the Miners' Pegs: from the near side's quiet end down the wall to the shelf below (always there)
        st = L["stations"]
        near = sp["near_shelf"]
        y_top = float(near["y"])
        a_peg = float(near["a0"]) - near["dirn"] * (10.0 / float(rift.radius(y_top)))
        land_y = None
        for t_ in getattr(R, "terraces_info", []):
            if t_["y_top"] < y_top - 60.0 and t_["y_top"] > y_top - 200.0:
                land_y = float(t_["y_top"])
                break
        pegs = []
        if land_y is not None:
            n_drops = max(1, int(math.ceil((y_top - land_y) / 21.5)))
            dy = (y_top - land_y) / n_drops
            side = 1
            for k in range(1, n_drops):
                y = y_top - dy * k
                r = float(rift.radius(y))
                side = -side
                am = a_peg + side * (2.5 / r)
                F.solids.append(ShelfSolid(rift, y, am, 2.6 / r, 6.0, thick=3.4))
                F.solid_boxes.append(F.solids[-1].aabb())
                R.solids.append(F.solids[-1])
                q = rift.point(am, y, 3.0)
                pegs.append(v3(q))
                st.append({"pos": v3(q), "kind": "foothold", "biome": OSSUARY, "label": "THE MINERS' PEGS" if k == 1 else ""})
                L["lanterns"].append({"pos": v3(q + np.array([0, 2.4, 0])), "color": GLOW[OSSUARY], "s": 1.4})
                if k % 2 == 0:
                    L["lights"].append({"pos": v3(q + np.array([0, 3.0, 0])), "color": GLOW[OSSUARY], "energy": 0.7, "range": 18.0})
            top_q = rift.point(a_peg, y_top, 3.0)
            L["texts"].append({"pos": v3(top_q + np.array([0, 1.5, 0])), "r": 7.0,
                               "text": "Old iron pegs, hammered into the wall a rope apart. The miners' way down to the shelf, before they built the bridge."})
        L["span"] = {"slabs": slabs, "b0": [v3(b0.a), v3(b0.b)], "b1": [v3(b1.a), v3(b1.b)], "hw": b0.hw,
                     "near_stub": NEAR_STUB, "len0": round(b0.L, 2), "pegs": pegs, "land_y": land_y,
                     "end_t": round(max(s_["drop_t"] for s_ in slabs) + 9.0, 2) if slabs else 0.0}
        report["span"] = {"slabs": len(slabs), "pegs": len(pegs), "lands": sum(1 for s_ in slabs if s_["lands"] is not None)}
        print("span: %d slabs, %d pegs" % (len(slabs), len(pegs)))
    # ------------------------------------------------------------------ THE CHANDELIER COMES DOWN
    recs = getattr(R, "chand_rec", [])
    if recs:
        rng_ch = random.Random(sdf.SEED + 7331)
        stp = np.array([s_["pos"] for s_ in L["stations"]], dtype=float)
        cones = []
        order = sorted(recs, key=lambda r_: r_["ln"])
        t_crack = 3.0
        for idx, rec in enumerate(order):
            cone = rec["cone"]
            base = cone.base
            # it may only fall where nothing of the route stands under it (20 m clear)
            col = np.hypot(stp[:, 0] - base[0], stp[:, 2] - base[2])
            under = (stp[:, 1] < base[1]) & (stp[:, 1] > base[1] - 700.0)
            falls = not np.any((col < rec["r0"] + 20.0 + abs(rec["ln"]) * 0.05) & under)
            stump = Clip(cone, base, [0, -1, 0], -6.5, 8.0)
            piece = Clip(cone, base, [0, -1, 0], 8.0, rec["ln"] + 2.0)
            if falls:
                _replace_solid(F, R, cone, [stump])
                lo, hi = cone.aabb()
                prims = _mesh_solid(piece, lo, hi, 1.6 if rec["ln"] < 90 else 2.0, 2, rift)
                if not prims:
                    falls = False
                    _replace_solid(F, R, stump, [cone])
            name = "chand_%02d" % rec["k"]
            if falls:
                nodes.append((name, prims))
            tip = cone.tip()
            fy = F.floor_below(tip[0], tip[2], tip[1] - 2.0, 300.0)
            e = {"node": name if falls else "", "k": rec["k"], "base": v3(base), "tip": v3(tip), "len": round(rec["ln"], 1),
                 "falls": bool(falls), "lands": None if fy is None else round(float(fy), 2)}
            if falls:
                e["crack_t"] = round(t_crack, 2)
                e["drop_t"] = round(t_crack + 2.0, 2)
                t_crack += 4.2 + rng_ch.uniform(-0.8, 0.8)
            if rec["light"] is not None:
                rec["light"]["piece"] = name
            if rec["lantern"] is not None:
                rec["lantern"]["piece"] = name
            cones.append(e)
        cp4 = None
        for (kind, a) in R.intents:
            if kind == "checkpoint" and a.get("label") == "FUNGAL HOLLOW":
                cp4 = [a["x"], a["y"], a["z"]]
        L["chandelier"] = {"cones": cones, "trigger": {"pos": cp4, "r": 45.0, "delay": 6.0},
                           "end_t": round(max([c_.get("drop_t", 0.0) for c_ in cones] + [0.0]) + 9.0, 2)}
        report["chandelier"] = {"cones": len(cones), "falling": sum(1 for c_ in cones if c_["falls"])}
        print("chandelier: %d cones, %d fall" % (len(cones), sum(1 for c_ in cones if c_["falls"])))
    if nodes:
        names = []
        for b in range(13):
            names += ["B%d_W" % b, "B%d_F" % b]
        write_glb(os.path.join(out_dir, "setpieces.glb"), nodes, names)
        report["setpieces_mb"] = round(os.path.getsize(os.path.join(out_dir, "setpieces.glb")) / 1e6, 2)
