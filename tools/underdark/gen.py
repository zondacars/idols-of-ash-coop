"""Build THE UNDERDARK: cave mesh (glb) + layout (json) + validation report + previews."""
import json
import math
import os
import struct
import sys
import time
from multiprocessing import Pool

import numpy as np
from skimage.measure import marching_cubes

import sdf
from sdf import Field, Perlin3
import rift_world as world
from rift_world import v3, hdir, godot_yaw_facing
import tubes

VOX = 2.5
BS = 40
OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
SKY_Y = 64.0

_FIELD = None


def _init(field):
    global _FIELD
    _FIELD = field


def mesh_block(args):
    bi, origin, n = args
    F = _FIELD
    ax = [origin[k] + VOX * np.arange(n[k] + 1) for k in range(3)]
    lo = np.array([ax[0][0], ax[1][0], ax[2][0]])
    hi = np.array([ax[0][-1], ax[1][-1], ax[2][-1]])
    idx = F.prims_for_box(lo - 1, hi + 1)
    if not idx:
        return bi, None
    if F.rift is not None and len(idx) == 1 and F.prims[idx[0]] is F.rift and not F.solids_for_box(lo - 1, hi + 1):
        # only the abyss touches this block: skip it when it is plainly all rock or all air
        g = [np.linspace(lo[k], hi[k], 7) for k in range(3)]
        GX, GY, GZ = np.meshgrid(g[0], g[1], g[2], indexing="ij")
        GP = np.stack([GX.ravel(), GY.ravel(), GZ.ravel()], axis=1)
        m0, m1, m2 = sdf.noise_fields(GP)
        ge = F.rift.sdf(GP, m0, m1, m2)
        if ge.min() > 40.0 or ge.max() < -40.0:
            return bi, None
    X, Y, Z = np.meshgrid(ax[0], ax[1], ax[2], indexing="ij")
    P = np.stack([X.ravel(), Y.ravel(), Z.ravel()], axis=1)
    f, owner = F.eval(P, idx, want_owner=True)
    if f.min() > 0 or f.max() < 0:
        return bi, None
    vol = f.reshape(X.shape)
    try:
        verts, faces, _, _ = marching_cubes(vol, 0.0, spacing=(VOX, VOX, VOX), allow_degenerate=False)
    except (ValueError, RuntimeError):
        return bi, None
    if len(faces) == 0:
        return bi, None
    verts = verts + lo
    g = F.gradient(verts)
    gl = np.linalg.norm(g, axis=1, keepdims=True)
    nrm = -g / np.maximum(gl, 1e-9)
    nrm[gl[:, 0] < 1e-6] = (0.0, 1.0, 0.0)   # flat sky cap has no gradient
    probe = F.eval(verts + nrm * 2.5)
    ao = np.clip(0.35 + 0.65 * np.clip(-probe / 2.5, 0.0, 1.0), 0.35, 1.0)
    vi = np.clip(np.rint((verts - lo) / VOX).astype(np.int64), 0, np.array(X.shape) - 1)
    own = owner.reshape(X.shape)[vi[:, 0], vi[:, 1], vi[:, 2]]
    biomes = np.array([F.prims[o].biome if o >= 0 else 0 for o in own], dtype=np.int32)
    if F.rift is not None:
        ri = F.prims.index(F.rift)
        m_r = own == ri
        if m_r.any():
            biomes[m_r] = F.rift.biome_at(verts[m_r, 1])     # the rift's strata decide its look
    # some rock is not rock: bone, bark. Those solids carry their own look.
    sidx = [j for j in F.solids_for_box(lo - 1, hi + 1) if getattr(F.solids[j], "look", None) is not None]
    if sidx:
        m0, m1, m2 = sdf.noise_fields(verts)
        ctx = {"rift": F.rift}
        for j in sidx:
            sd = F.solids[j].sdf(verts, m0, m1, m2, ctx)
            biomes[sd < 0.9] = F.solids[j].look
    tb = biomes[faces[:, 0]]
    fn = nrm[faces].mean(axis=1)
    floor = fn[:, 1] > 0.55
    groups = []
    for b in np.unique(tb):
        for fl in (False, True):
            m = (tb == b) & (floor == fl)
            if not m.any():
                continue
            sub = faces[m]
            used, inv = np.unique(sub.ravel(), return_inverse=True)
            groups.append(dict(biome=int(b), floor=fl, pos=verts[used].astype(np.float32),
                               nrm=nrm[used].astype(np.float32), ao=ao[used].astype(np.float32),
                               idx=inv.reshape(-1, 3).astype(np.uint32)))
    return bi, groups


# ------------------------------------------------------------------ solid meshes

_JIT = Perlin3(sdf.SEED + 9)


def slab_mesh(poly, top, bottom):
    """Extruded polygon, flat top. poly (N,2) world xz, counter-clockwise or not."""
    n = len(poly)
    cx, cz = poly.mean(axis=0)
    tris = []
    for i in range(n):
        a = poly[i]; b = poly[(i + 1) % n]
        tris.append([[cx, top, cz], [a[0], top, a[1]], [b[0], top, b[1]]])
        tris.append([[cx, bottom, cz], [b[0], bottom, b[1]], [a[0], bottom, a[1]]])
        tris.append([[a[0], top, a[1]], [a[0], bottom, a[1]], [b[0], bottom, b[1]]])
        tris.append([[a[0], top, a[1]], [b[0], bottom, b[1]], [b[0], top, b[1]]])
    return flat_shade(np.array(tris, dtype=np.float64), up_hint=np.array([cx, (top + bottom) / 2, cz]))


def column_mesh(x, z, bottom, top, radius, flat, sides=12, ring=2.5):
    ys = list(np.arange(bottom, top, ring)) + [top]
    rings = []
    for y in ys:
        ang = np.linspace(0, 2 * math.pi, sides, endpoint=False)
        px = x + np.cos(ang) * radius
        pz = z + np.sin(ang) * radius
        j = _JIT(px / 3.0, np.full(sides, y / 3.0), pz / 3.0)
        rr = radius * (1.0 + 0.28 * j)
        if flat and y >= top - 0.01:
            rr = radius * (1.0 + 0.1 * j)
        rings.append(np.stack([x + np.cos(ang) * rr, np.full(sides, y), z + np.sin(ang) * rr], axis=1))
    tris = []
    for k in range(len(rings) - 1):
        r0, r1 = rings[k], rings[k + 1]
        for i in range(sides):
            a, b = r0[i], r0[(i + 1) % sides]
            c, d = r1[i], r1[(i + 1) % sides]
            tris.append([a, b, d]); tris.append([a, d, c])
    topr = rings[-1]
    ctr = np.array([x, top, z])
    for i in range(sides):
        tris.append([ctr, topr[i], topr[(i + 1) % sides]])
    return flat_shade(np.array(tris, dtype=np.float64), axis=(x, z))


def flat_shade(tris, up_hint=None, axis=None):
    e1 = tris[:, 1] - tris[:, 0]
    e2 = tris[:, 2] - tris[:, 0]
    n = np.cross(e1, e2)
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-9)
    cen = tris.mean(axis=1)
    if axis is not None:
        out = cen - np.array([axis[0], 0, axis[1]]); out[:, 1] = 0
        cap = np.abs(n[:, 1]) > 0.95
        out[cap] = np.array([0, 1, 0])
    else:
        out = cen - up_hint
        vert = np.abs(n[:, 1]) > 0.95
        out[vert] = np.stack([np.zeros(vert.sum()), np.sign(cen[vert, 1] - up_hint[1]), np.zeros(vert.sum())], axis=1)
    flip = (n * out).sum(axis=1) < 0
    n[flip] *= -1
    tris[flip] = tris[flip][:, [0, 2, 1]]
    pos = tris.reshape(-1, 3).astype(np.float32)
    nrm = np.repeat(n, 3, axis=0).astype(np.float32)
    idx = np.arange(len(pos), dtype=np.uint32).reshape(-1, 3)
    ao = np.ones(len(pos), dtype=np.float32) * 0.85
    return dict(pos=pos, nrm=nrm, ao=ao, idx=idx)


# ------------------------------------------------------------------ glb

def write_glb(path, nodes, material_names):
    binbuf = bytearray()
    views, accs, meshes, gnodes = [], [], [], []

    def add_view(data, target):
        while len(binbuf) % 4:
            binbuf.append(0)
        off = len(binbuf)
        binbuf.extend(data)
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(data), "target": target})
        return len(views) - 1

    def add_acc(arr, comp, typ, target, normalized=False, minmax=False):
        v = add_view(arr.tobytes(), target)
        a = {"bufferView": v, "componentType": comp, "count": int(len(arr)), "type": typ}
        if normalized:
            a["normalized"] = True
        if minmax:
            a["min"] = [float(x) for x in arr.min(axis=0)]
            a["max"] = [float(x) for x in arr.max(axis=0)]
        accs.append(a)
        return len(accs) - 1

    for name, prims in nodes:
        gp = []
        for pr in prims:
            # 1 cm positions and 1/48 normal steps: invisible in game, compresses far better
            pos = np.ascontiguousarray(np.round(pr["pos"].astype(np.float64) * 100.0) / 100.0, dtype=np.float32)
            nq = np.round(pr["nrm"].astype(np.float64) * 48.0) / 48.0
            nq /= np.maximum(np.linalg.norm(nq, axis=1, keepdims=True), 1e-9)
            nrm = np.ascontiguousarray(nq, dtype=np.float32)
            c = np.clip(pr["ao"] * 255.0, 0, 255).astype(np.uint8)
            col = np.ascontiguousarray(np.stack([c, c, c, np.full_like(c, 255)], axis=1))
            ia = add_acc(pos, 5126, "VEC3", 34962, minmax=True)
            na = add_acc(nrm, 5126, "VEC3", 34962)
            ca = add_acc(col, 5121, "VEC4", 34962, normalized=True)
            idx = pr["idx"].ravel()
            if pos.shape[0] < 65536:
                xa = add_acc(np.ascontiguousarray(idx.astype(np.uint16)), 5123, "SCALAR", 34963)
            else:
                xa = add_acc(np.ascontiguousarray(idx.astype(np.uint32)), 5125, "SCALAR", 34963)
            gp.append({"attributes": {"POSITION": ia, "NORMAL": na, "COLOR_0": ca}, "indices": xa,
                       "material": pr["mat"], "mode": 4})
        meshes.append({"name": name, "primitives": gp})
        gnodes.append({"name": name, "mesh": len(meshes) - 1})
    mats = [{"name": m, "doubleSided": True,
             "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0.0, "roughnessFactor": 1.0}}
            for m in material_names]
    while len(binbuf) % 4:
        binbuf.append(0)
    doc = {"asset": {"version": "2.0", "generator": "zonda-underdark"}, "scene": 0,
           "scenes": [{"nodes": list(range(len(gnodes)))}], "nodes": gnodes, "meshes": meshes,
           "materials": mats, "accessors": accs, "bufferViews": views,
           "buffers": [{"byteLength": len(binbuf)}]}
    js = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    while len(js) % 4:
        js += b" "
    total = 12 + 8 + len(js) + 8 + len(binbuf)
    with open(path, "wb") as fh:
        fh.write(struct.pack("<4sII", b"glTF", 2, total))
        fh.write(struct.pack("<I4s", len(js), b"JSON"))
        fh.write(js)
        fh.write(struct.pack("<I4s", len(binbuf), b"BIN\x00"))
        fh.write(binbuf)


# ------------------------------------------------------------------ resolve intents

def polar_slab(center_xz, dirv, r_in, r_out, half_t, rng, jitter=0.6):
    tang = np.array([-dirv[2], dirv[0]])
    rad = np.array([dirv[0], dirv[2]])
    pts = []
    inner = [(-half_t, r_in), (-half_t * 0.5, r_in - jitter), (0, r_in - jitter * 1.3), (half_t * 0.5, r_in - jitter), (half_t, r_in)]
    for (t, r) in inner:
        pts.append(center_xz + rad * (r + rng.uniform(-0.25, 0.25)) + tang * (t + rng.uniform(-0.2, 0.2)))
    pts.append(center_xz + rad * r_out + tang * half_t)
    pts.append(center_xz + rad * r_out - tang * half_t)
    poly = np.array(pts)
    # make the polygon star-shaped around its centroid (order by angle)
    c = poly.mean(axis=0)
    ang = np.arctan2(poly[:, 1] - c[1], poly[:, 0] - c[0])
    return poly[np.argsort(ang)]


def resolve(R, F, report):
    import random
    rng = random.Random(sdf.SEED + 77)
    L = R.L
    plinth_tops = {}
    crystals = []
    L["crystals"] = crystals
    L["slabs_meta"] = []

    def floor_at(x, z, y_from, drop=40.0):
        return F.floor_below(x, z, y_from, drop)

    def headroom(x, z, y, h=1.9):
        v = F.eval(np.array([[x, y + 0.5, z], [x, y + h * 0.5, z], [x, y + h, z]]))
        return bool(np.all(v < 0))

    def add_slab(biome, poly, top, bottom, tag):
        R.slabs.append(dict(biome=biome, poly=poly, top=top, bottom=bottom))
        L["slabs_meta"].append({"tag": tag, "top": round(top, 2), "center": v3([poly[:, 0].mean(), top, poly[:, 1].mean()])})

    order = ["plinth"]  # plinths first so kilns and plates can find their tops
    intents = sorted(R.intents, key=lambda it: 0 if it[0] in order else 1)
    for kind, a in intents:
        if kind == "shaft_shelf":
            S = a["S"]
            placed = False
            for tryi in range(4):
                y = a["y"] - 1.5 * tryi
                d = hdir(a["ang"])
                rw = F.ray_to_rock([S[0], y + 0.6, S[2]], d, 40.0, 0.2)
                if rw is None:
                    rw = a["R"]
                protrude = 7.0 if a.get("big") else (5.6 if a.get("wide") else 4.4)
                inner_r = max(rw - protrude, 1.2)
                cxz = np.array([S[0], S[2]])
                probe = cxz + np.array([d[0], d[2]]) * (inner_r + 1.2)
                if not headroom(probe[0], probe[1], y):
                    continue
                half_t = 4.6 if a.get("big") else (4.2 if a.get("wide") else 2.8)
                poly = polar_slab(cxz, d, inner_r, rw + 3.6, half_t, rng)
                add_slab(a["biome"], poly, y, y - 1.8, "shelf")
                if a.get("big"):
                    L["embers"].append({"pos": v3([probe[0], y + 1.3, probe[1]])})
                    L["lights"].append({"pos": v3([probe[0], y + 2.0, probe[1]]), "color": [1.0, 0.6, 0.3], "energy": 0.7, "range": 14.0})
                if a["ice"]:
                    L["ice"].append({"pos": v3([probe[0], y + 0.8, probe[1]]), "r": 3.2, "dir": v3(-d)})
                placed = True
                break
            if not placed:
                report["warnings"].append("shaft shelf skipped at y=%.1f" % a["y"])
        elif kind == "shaft_crumble":
            S = a["S"]
            d = hdir(a["ang"])
            rw = F.ray_to_rock([S[0], a["y"] + 0.6, S[2]], d, 40.0, 0.2)
            if rw is None:
                continue
            c = np.array([S[0], a["y"] - 0.5, S[2]]) + d * (rw - 1.9)
            L["crumbles"].append({"id": R.next_id("cr"), "pos": v3(c), "yaw": round(rng.uniform(0, 6.28), 3), "scale": 0.6})
        elif kind == "wall_light":
            S = a["S"]
            d = hdir(a["ang"])
            rw = F.ray_to_rock([S[0], a["y"], S[2]], d, 40.0, 0.3) or 8.0
            p = np.array([S[0], a["y"], S[2]]) + d * (rw - 1.5)
            L["lights"].append({"pos": v3(p), "color": a["color"], "energy": 0.9, "range": 20.0})
        elif kind == "trench_step":
            ch = a["ch"]
            d = ch.d; s = ch.s
            base = a["tc"] + d * (-a["half_w"]) + s * a["lz"]
            cxz = np.array([base[0], base[2]])
            poly = polar_slab(cxz, -d, -3.0, 3.8, 2.4, rng, jitter=0.3)
            add_slab(ch.biome, poly, a["top"], a["top"] - 1.6, "step")
        elif kind == "spike_bed":
            fy = floor_at(a["x"], a["z"], a["y_from"])
            if fy is None:
                continue
            for k in range(3):
                L["props"].append({"scene": world.A + "Spikes_01.glb", "pos": v3([a["x"] + rng.uniform(-1.6, 1.6), fy - 0.3, a["z"] + rng.uniform(-1.6, 1.6)]),
                                   "rot": [0.0, round(rng.uniform(0, 6.28), 3), 0.0], "scale": round(rng.uniform(0.05, 0.08), 3), "box": None, "vis": 200.0})
            L["spikes"].append({"pos": v3([a["x"], fy + 1.2, a["z"]]), "r": 3.2, "push": a["push"]})
        elif kind == "prop":
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
            L["props"].append(ent)
        elif kind == "light":
            p = a["pos"]
            y = p[1]
            if a["snap"]:
                fy = floor_at(p[0], p[2], p[1] + 6.0)
                if fy is None:
                    continue
                y = fy
            L["lights"].append({"pos": v3([p[0], y + a["lift"], p[2]]), "color": a["color"], "energy": a["energy"], "range": a["range"]})
        elif kind == "fire":
            p = a["pos"]
            fy = floor_at(p[0], p[2], p[1] + 6.0)
            if fy is None:
                continue
            L["fires"].append({"pos": v3([p[0], fy, p[2]]), "scale": a["scale"], "beacon": bool(a.get("beacon", False))})
            if a["light"] and not a.get("beacon"):
                L["lights"].append({"pos": v3([p[0], fy + 1.6, p[2]]), "color": [1.0, 0.58, 0.25], "energy": a["energy"], "range": a["range"]})
        elif kind == "ember":
            p = a["pos"]
            fy = floor_at(p[0], p[2], p[1] + 6.0)
            if fy is None:
                continue
            L["embers"].append({"pos": v3([p[0], fy + 1.3, p[2]])})
        elif kind == "checkpoint":
            fy = floor_at(a["x"], a["z"], a["y"] + 6.0)
            if fy is None:
                report["errors"].append("checkpoint %d has no floor" % a["id"])
                continue
            L["checkpoints"].append({"id": a["id"], "pos": v3([a["x"], fy + 1.2, a["z"]]), "r": 7.0,
                                     "label": a["label"], "biome": a["biome"]})
            L["fires"].append({"pos": v3([a["x"] + 2.5, fy, a["z"] + 1.0]), "scale": 0.45})
        elif kind == "stalactite":
            p = a["pos"]
            up = F.ray_to_rock(p, [0, 1, 0], 60.0, 0.3)
            if up is None or up < 6:
                continue
            L["props"].append({"scene": world.A + "Spikes_01.glb", "pos": v3([p[0], p[1] + up + 1.2, p[2]]),
                               "rot": [round(math.pi, 4), round(a["yaw"], 3), 0.0], "scale": round(a["scale"], 3), "box": None, "vis": 260.0})
        elif kind == "plinth":
            ch = a["ch"]
            wdir = math.cos(a["ang"]) * ch.d + math.sin(a["ang"]) * ch.s
            top = ch.floor_y + a["height"]
            origin = np.array([ch.c[0], top + 0.8, ch.c[2]])
            rw = F.ray_to_rock(origin, wdir, 90.0, 0.2)
            if rw is None:
                report["errors"].append("plinth %s found no wall" % a["key"])
                continue
            cxz = np.array([ch.c[0], ch.c[2]])
            poly = polar_slab(cxz, wdir, rw - 5.2, rw + 3.8, 3.3, rng, jitter=0.4)
            add_slab(ch.biome, poly, top, top - 2.0, "plinth")
            tc = cxz + np.array([wdir[0], wdir[2]]) * (rw - 2.8)
            if not headroom(tc[0], tc[1], top, 2.6):
                report["warnings"].append("plinth %s has low headroom" % a["key"])
            plinth_tops[a["key"]] = np.array([tc[0], top, tc[1]])
        elif kind in ("kiln", "plate"):
            if a["plinth"] is not None:
                if a["plinth"] not in plinth_tops:
                    report["errors"].append("%s %d lost its plinth" % (kind, a["idx"]))
                    continue
                p = plinth_tops[a["plinth"]]
            else:
                fy = floor_at(a["x"], a["z"], a["y"])
                if fy is None:
                    report["errors"].append("%s %d has no floor" % (kind, a["idx"]))
                    continue
                p = np.array([a["x"], fy, a["z"]])
            L[kind + "s"].append({"gate": a["gate"], "idx": a["idx"], "pos": v3(p)})
        elif kind == "gate":
            t = a["tunnel"]
            pts = t["points"]
            want = a["dist"] + 7.0
            acc = 0.0
            A_ = pts[0]; dirv = hdir(0)
            for i in range(len(pts) - 1):
                seg = pts[i + 1] - pts[i]
                ln = np.linalg.norm(seg)
                if acc + ln >= want:
                    A_ = pts[i] + seg * ((want - acc) / ln)
                    dirv = seg / ln
                    break
                acc += ln
            r = t["r"]
            floor = A_[1] - 0.55 * r
            h = 0.55 * r + r + 5.0
            flat = np.array([dirv[0], 0, dirv[2]])
            flat /= np.linalg.norm(flat)
            L["gates"].append({"id": a["id"], "kind": a["kind"], "need": a["need"],
                               "pos": v3([A_[0], floor + h * 0.5 - 1.0, A_[2]]), "yaw": round(godot_yaw_facing(flat), 4),
                               "w": round(2 * r + 6.0, 2), "h": round(h, 2), "floor": round(floor, 2),
                               "front": v3(np.array([A_[0], floor + 1.5, A_[2]]) - flat * 4.0)})
        elif kind == "dying_lights":
            lights = []
            for p in a["points"]:
                fy = floor_at(p[0] + 1.6, p[2] + 1.6, p[1] + 1.0)
                if fy is None:
                    continue
                lights.append(v3([p[0] + 1.6, fy, p[2] + 1.6]))
            if lights:
                L["dying_lights"].append({"id": a["id"], "trigger": [lights[0], 5.0], "lights": lights})
        elif kind == "fragment_on_roof":
            L["fragments"].append({"id": a["id"], "pos": v3([a["x"], a["y"] + 1.0, a["z"]])})
        elif kind == "hanging_tower":
            p = a["pos"]
            up = F.ray_to_rock(p, [0, 1, 0], 90.0, 0.3)
            if up is None:
                continue
            L["props"].append({"scene": a["scene"], "pos": v3([p[0], p[1] + up - 11.0, p[2]]),
                               "rot": [round(math.pi, 4), round(a["yaw"], 3), 0.0], "scale": 0.8, "box": None, "vis": 400.0})
        elif kind == "crystal":
            p = a["pos"]
            fy = floor_at(p[0], p[2], p[1] + 6.0)
            if fy is None:
                continue
            crystals.append({"pos": v3([p[0], fy, p[2]]), "s": round(a["s"], 2), "yaw": round(rng.uniform(0, 6.28), 3),
                             "tilt": round(rng.uniform(-0.3, 0.3), 3)})
        elif kind == "dropper":
            fy = floor_at(a["x"], a["z"], a["ceiling_from"] + 2.0)
            up = F.ray_to_rock([a["x"], a["ceiling_from"], a["z"]], [0, 1, 0], 80.0, 0.3)
            if fy is None or up is None:
                continue
            ceil = a["ceiling_from"] + up
            if ceil - fy < (16.0 if a["kind"] == "tower" else 6.0):
                report["warnings"].append("dropper %s skipped, ceiling too low" % a["kind"])
                continue
            hang_off = {"icicle": 0.5, "boulder": 3.5, "tower": 9.0}[a["kind"]]
            trip_r = {"icicle": 3.4, "boulder": 4.2, "tower": 7.0}[a["kind"]]
            L["droppers"].append({"id": R.next_id("dr"), "kind": a["kind"], "hang": v3([a["x"], ceil - hang_off, a["z"]]),
                                  "floor": round(fy, 2), "trip": [v3([a["x"], fy + 1.0, a["z"]]), trip_r]})
        elif kind == "dress":
            ch = a["ch"]
            wdir = math.cos(a["ang"]) * ch.d + math.sin(a["ang"]) * ch.s
            y = ch.floor_y + 1.5 + a["hf"] * (ch.r[1] * 1.15)
            origin = np.array([ch.c[0], y, ch.c[2]])
            rw = F.ray_to_rock(origin, wdir, 120.0, 0.3)
            if rw is None:
                continue
            hit = origin + wdir * rw
            # keep doorways clear: no rocks near where players enter or leave the room
            doors = [ch.arrival, ch.exit] + [pl["start"] for pl in R.tube_plans if pl["ch"] is ch]
            if hit[1] < ch.floor_y + 9.0 and any(math.hypot(hit[0] - dd[0], hit[2] - dd[2]) < 11.0 for dd in doors):
                continue
            L["dress"].append({"scene": a["scene"], "hit": v3(hit), "n": v3(-wdir), "embed": round(a["embed"], 2),
                               "scale": round(a["scale"], 2), "yaw": round(rng.uniform(0, 6.28), 3),
                               "tilt": round(rng.uniform(-0.5, 0.5), 3), "roll": round(rng.uniform(-0.5, 0.5), 3)})
        elif kind == "rubble":
            ch = a["ch"]
            for _try in range(6):
                lx = rng.uniform(-0.85, 0.85) * ch.r[0]
                lz = rng.uniform(-0.85, 0.85) * ch.r[2]
                e = (lx / ch.r[0]) ** 2 + (lz / ch.r[2]) ** 2
                if e < 0.12 or e > 0.8:
                    continue
                p = ch.world_point(lx, lz, ch.floor_y + 4.0)
                if any(math.hypot(p[0] - dd[0], p[2] - dd[2]) < 9.0 for dd in (ch.arrival, ch.exit)):
                    continue
                fy = floor_at(p[0], p[2], p[1], 12.0)
                if fy is None:
                    continue
                L["dress"].append({"scene": a["scene"], "hit": v3([p[0], fy, p[2]]), "n": [0.0, 1.0, 0.0], "embed": 0.35, "up": True,
                                   "scale": round(a["scale"], 2), "yaw": round(rng.uniform(0, 6.28), 3),
                                   "tilt": round(rng.uniform(-0.25, 0.25), 3), "roll": round(rng.uniform(-0.25, 0.25), 3)})
                break
        elif kind == "tunnel_dress":
            t = a["t"]
            axis = t.a + (t.b - t.a) * a["f"]
            fwd = (t.b - t.a) / max(np.linalg.norm(t.b - t.a), 0.1)
            side = np.cross(fwd, np.array([0, 1, 0]))
            if np.linalg.norm(side) < 0.1:
                continue
            side /= np.linalg.norm(side)
            ang = a["side"]  # radians from straight up, +/- 1.7 covers the ceiling and both walls
            wdir = np.array([0, 1.0, 0]) * math.cos(ang) + side * math.sin(ang)
            rw = F.ray_to_rock(axis, wdir, 30.0, 0.25)
            if rw is None:
                continue
            hit = axis + wdir * rw
            L["dress"].append({"scene": a["scene"], "hit": v3(hit), "n": v3(-wdir), "embed": 0.6,
                               "scale": round(a["scale"], 2), "yaw": round(rng.uniform(0, 6.28), 3),
                               "tilt": round(rng.uniform(-0.6, 0.6), 3), "roll": round(rng.uniform(-0.6, 0.6), 3)})
        elif kind == "shaft_dress":
            S = a["S"]
            d = hdir(a["ang"])
            rw = F.ray_to_rock([S[0], a["y"], S[2]], d, 40.0, 0.25)
            if rw is None:
                continue
            hit = np.array([S[0], a["y"], S[2]]) + d * rw
            L["dress"].append({"scene": a["scene"], "hit": v3(hit), "n": v3(-d), "embed": 0.62,
                               "scale": round(a["scale"], 2), "yaw": round(rng.uniform(0, 6.28), 3),
                               "tilt": round(rng.uniform(-0.6, 0.6), 3), "roll": round(rng.uniform(-0.6, 0.6), 3)})
        elif kind == "vent":
            fy = floor_at(a["x"], a["z"], a["y"])
            if fy is None:
                continue
            L["vents"].append({"pos": v3([a["x"], fy, a["z"]]), "period": round(rng.uniform(5.5, 9.0), 2), "phase": round(rng.uniform(0, 9), 2)})
        elif kind == "bell" and "hang" in a:
            L["bells"].append({"id": R.next_id("bell"), "pos": v3([a["x"], a["hang"], a["z"]]),
                               "floor": round(a["y"], 2), "ceiling": round(a["ceiling"], 2), "scale": a["scale"]})
            L["lights"].append({"pos": v3([a["x"], a["hang"] + 1.0, a["z"]]), "color": [1.0, 0.75, 0.4], "energy": 1.3, "range": 26.0})
        elif kind == "wall_crumble":
            rf = R.rift
            c = rf.point(a["a"], a["y"], 1.9)
            L["crumbles"].append({"id": R.next_id("cr"), "pos": v3(c - np.array([0, 0.5, 0])), "yaw": round(rng.uniform(0, 6.28), 3), "scale": 0.6})
        elif kind == "bell":
            fy = floor_at(a["x"], a["z"], a["y"] + 6.0, 70.0)
            up = F.ray_to_rock([a["x"], (fy if fy is not None else a["y"]) + 2.0, a["z"]], [0, 1, 0], 120.0, 0.3)
            if fy is None or up is None:
                report["errors"].append("bell at %s has no floor or ceiling" % v3([a["x"], a["y"], a["z"]]))
                continue
            ceil = fy + 2.0 + up
            hang = min(ceil - 2.0, fy + 13.0)
            L["bells"].append({"id": R.next_id("bell"), "pos": v3([a["x"], hang, a["z"]]),
                               "floor": round(fy, 2), "ceiling": round(ceil, 2), "scale": a["scale"]})
            L["lights"].append({"pos": v3([a["x"], hang + 1.0, a["z"]]), "color": [1.0, 0.75, 0.4], "energy": 1.1, "range": 22.0})
        elif kind == "ghost":
            p = a["pos"]
            fy = floor_at(p[0], p[2], p[1] + 5.0, 14.0)
            if fy is None or not headroom(p[0], p[2], fy, 2.0):
                continue
            L["ghosts"].append({"pos": v3([p[0], fy, p[2]]), "yaw": round(godot_yaw_facing(np.array(a["face"])) + math.pi, 4)})
            if len(L["ghosts"]) in (2, 9, 20, 33):
                fc = np.array(a["face"], dtype=float)
                eye = np.array([p[0], fy + 1.8, p[2]]) - fc * 3.0
                L["tour"].append({"pos": v3(eye), "look": v3([p[0], fy + 1.5, p[2]]), "label": "ghost close %d" % len(L["ghosts"])})
        elif kind == "altar":
            fy = floor_at(a["x"], a["z"], a["y"])
            if fy is None:
                report["errors"].append("altar has no floor")
                continue
            L["altar"].append({"pos": v3([a["x"], fy, a["z"]])})
        elif kind == "bar":
            p = a["pos"]
            d = hdir(a["yaw"])
            s = np.array([-d[2], 0, d[0]])
            chains = []
            for side in (-1, 1):
                q = p + s * side * (a["length"] * 0.5 - 0.8)
                up = F.ray_to_rock(q + np.array([0, 0.6, 0]), [0, 1, 0], 60.0, 0.3)
                chains.append(round(float(q[1] + 0.6 + (up if up is not None else 20.0)), 2))
            L["bars"].append({"idx": a["idx"], "pos": v3(p), "yaw": round(godot_yaw_facing(s), 4), "length": a["length"],
                              "width": a["width"], "thick": a["thick"], "chain_top": chains, "lava_y": round(a["lava_y"], 2),
                              "sink": bool(a.get("sink", False))})
        else:
            report["errors"].append("unknown intent " + kind)
    resolve_tubes(R, F, report, rng)


def resolve_tubes(R, F, report, rng):
    """Find each tube's real wall crossings, build its mesh, its collar, its decor."""
    L = R.L
    R.tube_meshes = []
    R.mouth_zones = []
    for plan in R.tube_plans:
        pts = plan["pts"].copy()
        rs = plan["rs"].copy()
        d0 = plan["wdir"]
        rw = F.ray_to_rock(plan["start"], d0, 40.0, 0.2)
        if rw is None:
            report["errors"].append("tube %s: no wall found at its mouth" % plan["name"])
            continue
        A = plan["start"] + d0 * rw
        pts[0] = A - d0 * 1.8
        R.mouth_zones.append((A, d0, rs[0] + 1.4, 9.0))
        R.tube_meshes.append(("collar", tubes.collar_mesh(A, d0, rs[0] - 0.15, 6.5, 4.5), BURROWS_MAT(R)))
        cap_end = True
        if plan["true_route"]:
            # the end sits inside the next chamber: walk back to its wall
            last = pts[-1]
            dend = pts[-1] - pts[-2]
            dend /= max(np.linalg.norm(dend), 1e-6)
            back = F.ray_to_rock(last, -dend, 40.0, 0.2)
            if back is None:
                report["errors"].append("tube %s: end is not inside a chamber" % plan["name"])
            else:
                Ae = last - dend * back
                pts[-1] = Ae + dend * 1.8
                R.mouth_zones.append((Ae, dend, rs[-1] + 1.4, 9.0))
                R.tube_meshes.append(("collar", tubes.collar_mesh(Ae, dend, rs[-1] - 0.15, 6.5, 4.5), BURROWS_MAT(R)))
                cap_end = False
        mesh, spts, srs, T = tubes.tube_mesh(pts, rs, cap_end=cap_end)
        R.tube_meshes.append(("tube", mesh, BURROWS_MAT(R)))
        total = tubes.path_length(spts)
        dec = plan["decor"]
        # decor along the path
        s = 6.0
        while dec.get("candles") and s < total - 4:
            p, t, _ = tubes.along(spts, s)
            side = np.cross(t, np.array([0, 1.0, 0]))
            if np.linalg.norm(side) > 0.1:
                side /= np.linalg.norm(side)
                r_here = float(np.interp(s, np.cumsum(np.concatenate([[0], np.linalg.norm(spts[1:] - spts[:-1], axis=1)])), srs))
                lp = p + side * (r_here * 0.55) * rng.choice([-1, 1]) + np.array([0, -0.55 * r_here + 0.35, 0])
                L["lights"].append({"pos": v3(lp), "color": [1.0, 0.72, 0.4], "energy": 0.32, "range": 6.5})
                L["fires"].append({"pos": v3(lp - np.array([0, 0.3, 0])), "scale": 0.08})
            s += dec["candles"]
        for (ts, text) in dec.get("texts", []):
            p, t, _ = tubes.along(spts, min(ts, total - 2))
            L["texts"].append({"pos": v3(p), "r": 3.0, "text": text})
        for sa in dec.get("ambience", []):
            p, t, _ = tubes.along(spts, min(sa, total - 2))
            L["ambience"].append({"pos": v3(p), "sounds": world.BREATHS + world.WHISPERS, "min": 7.0, "max": 16.0, "range": 18.0, "db": -3.0})
        if dec.get("end_corpse"):
            p, t, _ = tubes.along(spts, total - 2.5)
            fl = p[1] - 0.55 * srs[-1]
            n = int(dec.get("end_corpses", 1))
            for k in range(n):
                off = np.array([rng.uniform(-0.8, 0.8), 0, rng.uniform(-0.8, 0.8)]) if n > 1 else np.zeros(3)
                L["props"].append({"scene": rng.choice(world.CORPSES), "pos": v3([p[0] + off[0], fl, p[2] + off[2]]),
                                   "rot": [0.0, round(rng.uniform(0, 6.28), 3), 0.0], "scale": 0.9, "box": None, "vis": 120.0})
            if dec.get("end_ember"):
                L["embers"].append({"pos": v3([p[0], fl + 1.1, p[2]])})
            L["lights"].append({"pos": v3([p[0], fl + 0.9, p[2]]), "color": [1.0, 0.55, 0.3], "energy": 0.25, "range": 5.0})
        if dec.get("end_text"):
            p, t, _ = tubes.along(spts, total - 4.0)
            L["texts"].append({"pos": v3(p), "r": 3.0, "text": dec["end_text"]})
        # biome zones so the fog, music and HUD know you are in the burrows
        s = 0.0
        while s < total:
            p, t, _ = tubes.along(spts, s)
            L["zones"].append({"name": plan["name"], "biome": world.BURROWS, "center": v3(p), "radius": 14.0,
                               "floor": round(float(p[1]) - 1.0, 2), "top": round(float(p[1]) + 2.0, 2)})
            s += 22.0
        if plan["true_route"]:
            for ts in (18.0, 58.0, 96.0):
                p, t, _ = tubes.along(spts, min(ts, total - 3))
                L["tour"].append({"pos": v3(p + np.array([0, 0.2, 0])), "look": v3(p + t * 6.0), "label": "burrows %d m" % int(ts)})
        report.setdefault("tubes", []).append({"name": plan["name"], "length_m": round(total, 1), "min_r": round(float(srs.min()), 2)})


def BURROWS_MAT(R):
    return world.BURROWS * 2


# ------------------------------------------------------------------ validation

def _station_floor(F, p):
    fy = None
    for up in (4.5, 3.0, 2.0):                            # an overhang may hang low over a ledge: start under it
        fy = F.floor_below(p[0], p[2], p[1] + up, up + 4.5)   # a root or span arriving may sit a little higher
        if fy is not None and fy - p[1] <= 3.6 and (p[1] + up) - fy > 1.9:
            break
    ok = not (fy is None or fy - p[1] > 3.6 or p[1] - fy > 1.6)
    return ok, fy


def repair_stations(R, F, report):
    """No place the route says you stand may be missing its rock. Where the field left a
    station floorless (wall noise eating a small foothold), lay a slab under it."""
    if getattr(R, "rift", None) is None:
        return
    n = 0
    for s_ in R.L.get("stations", []):
        if s_["kind"] in ("platform", "gantry"):
            continue
        p = s_["pos"]
        ok, fy = _station_floor(F, p)
        if ok:
            continue
        top = p[1] - 0.05
        rad = 2.6
        poly = np.array([[p[0] + rad * math.cos(2 * math.pi * k / 10), p[2] + rad * math.sin(2 * math.pi * k / 10)] for k in range(10)])
        R.slabs.append(dict(biome=int(s_["biome"]), poly=poly, top=top, bottom=top - 2.0))
        R.L["slabs_meta"].append({"tag": "repair", "top": round(top, 2), "center": v3([p[0], top, p[2]])})
        s_["repaired"] = True
        n += 1
        report["warnings"].append("repair slab under %s station at %s" % (s_["kind"], v3(p)))
    report["stations_repaired"] = n
    print("stations repaired with a slab: %d" % n)


def validate_rift(R, F, report):
    """Every place the player must stand exists, and every step between them is within a rope."""
    L = R.L
    st = L.get("stations", [])
    bad_floor = 0
    for s_ in st:
        p = s_["pos"]
        if s_["kind"] in ("platform", "gantry") or s_.get("repaired"):
            continue
        ok, fy = _station_floor(F, p)
        if not ok:
            bad_floor += 1
            if bad_floor <= 8:
                report["errors"].append("no floor where expected at %s (%s)" % (p, s_["kind"]))
    drops = [m["dy"] for m in R.moves if m["type"] == "drop"]
    gaps = [m["gap"] for m in R.moves if m["type"] in ("swing", "hop") and "gap" in m]
    hops = [m["dy"] for m in R.moves if m["type"] == "hop"]
    report["stations"] = len(st)
    report["stations_without_floor"] = bad_floor
    report["drops"] = {"count": len(drops), "max": max(drops), "median": float(np.median(drops)), "hard": sum(1 for m in R.moves if m.get("hard"))}
    report["swing_gaps_max"] = max(gaps) if gaps else 0
    report["hop_dy_max"] = max(hops) if hops else 0
    if max(drops) > 23.6:
        report["errors"].append("a drop of %.1f m is longer than the rope allows" % max(drops))
    if gaps and max(gaps) > 12.5:
        report["errors"].append("a gap of %.1f m is too wide to throw across" % max(gaps))
    spans = [m for m in R.moves if m["type"] in ("span", "spar")]
    report["spans"] = [(m["type"], m["length"], m["drop"]) for m in spans]
    report["walk_m"] = round(sum(s2["length"] for s2 in []) , 0)


def validate(R, F, report, lo, hi):
    if getattr(R, "rift", None) is not None:
        validate_rift(R, F, report)
        bars = sorted(R.L["bars"], key=lambda b: b["idx"])
        report["bar_count"] = len(bars)
        pts_ = [(b["idx"], np.array(b["pos"])) for b in bars]
        gaps_ = [float(np.linalg.norm(b_[1] - a_[1])) for a_, b_ in zip(pts_, pts_[1:])]
        report["bar_gaps"] = [round(g, 1) for g in gaps_]
        if gaps_ and (min(gaps_) < 25.0 or max(gaps_) > 29.0):
            report["errors"].append("bar spacing %.1f to %.1f m is outside 25 to 29 m" % (min(gaps_), max(gaps_)))
        return
    # 1) the air must be one connected region
    from scipy import ndimage
    step = 3.0
    xs = np.arange(lo[0], hi[0], step)
    ys = np.arange(lo[1], min(hi[1], SKY_Y - 2), step)
    zs = np.arange(lo[2], hi[2], step)
    air = np.zeros((len(xs), len(ys), len(zs)), dtype=bool)
    for ix, x in enumerate(xs):
        Y, Z = np.meshgrid(ys, zs, indexing="ij")
        P = np.stack([np.full(Y.size, x), Y.ravel(), Z.ravel()], axis=1)
        idx = F.prims_for_box(np.array([x - 1, ys[0], zs[0]]), np.array([x + 1, ys[-1], zs[-1]]))
        if not idx:
            continue
        air[ix] = (F.eval(P, idx) < 0.0).reshape(len(ys), len(zs))
    lab, n = ndimage.label(air)
    sizes = ndimage.sum(air, lab, range(1, n + 1))
    main = int(np.argmax(sizes)) + 1
    report["air_components"] = int(n)
    report["air_component_sizes_top5"] = sorted([int(v) for v in sizes], reverse=True)[:5]

    def label_at(p):
        i = int(round((p[0] - lo[0]) / step)); j = int(round((p[1] + 2.0 - lo[1]) / step)); k = int(round((p[2] - lo[2]) / step))
        for dj in (0, 1, -1, 2):
            jj = j + dj
            if 0 <= i < lab.shape[0] and 0 <= jj < lab.shape[1] and 0 <= k < lab.shape[2] and lab[i, jj, k] > 0:
                return int(lab[i, jj, k])
        return 0

    # hand-meshed tubes join air regions the field does not know about
    linked = {main}
    changed = True
    while changed:
        changed = False
        for plan in getattr(R, "tube_plans", []):
            if not plan["true_route"]:
                continue
            a = label_at(plan["start"]); b = label_at(plan["pts"][-1])
            if a in linked and b and b not in linked:
                linked.add(b); changed = True
            if b in linked and a and a not in linked:
                linked.add(a); changed = True
    report["air_components_linked_by_tubes"] = len(linked)

    def in_main(p):
        return label_at(p) in linked

    for ch in R.chambers:
        p = [ch.c[0], ch.floor_y + 3.0, ch.c[2]]
        if not in_main(p):
            report["errors"].append("chamber %s is not connected to the main cave" % ch.name)
    for key in ("checkpoints", "kilns", "plates", "fragments", "altar"):
        for e in R.L[key]:
            if not in_main(e["pos"]):
                report["errors"].append("%s at %s not connected" % (key, e["pos"]))

    # 2) tunnels must be walkable: probe the floor every 2.5 m along each tunnel
    worst = 0.0
    for p, g in zip(R.prims, R.groups):
        if p.kind != "tunnel" or getattr(p, "phantom", False):
            continue
        ln = np.linalg.norm(p.b - p.a)
        prev = None
        for t in np.arange(0.0, 1.0001, 2.5 / max(ln, 1)):
            q = p.a + (p.b - p.a) * t
            fy = F.floor_below(q[0], q[2], q[1], 20.0)
            if fy is None:
                report["errors"].append("tunnel floor missing near %s" % v3(q))
                break
            if prev is not None:
                horiz = math.hypot(q[0] - prev[0], q[2] - prev[2])
                if horiz > 0.5:
                    worst = max(worst, abs(fy - prev[1]) / horiz)
            prev = (q[0], fy, q[2])
    report["worst_tunnel_slope_deg"] = round(math.degrees(math.atan(worst)), 1)

    # 3) shafts: no gap between usable ledges bigger than the rope can handle
    ys_by_shaft = {}
    for m in R.L["slabs_meta"]:
        if m["tag"] == "shelf":
            ys_by_shaft.setdefault(round(m["center"][0] / 30) * 1000 + round(m["center"][2] / 30), []).append(m["top"])
    report["shelf_count"] = sum(1 for m in R.L["slabs_meta"] if m["tag"] == "shelf")

    # 4) monkey bars gaps
    bars = sorted(R.L["bars"], key=lambda b: b["idx"])
    gaps = []
    for a_, b_ in zip(bars, bars[1:]):
        gaps.append(round(math.dist(a_["pos"], b_["pos"]), 1))
    report["bar_gaps"] = gaps


def main():
    t0 = time.time()
    os.makedirs(OUT, exist_ok=True)
    R = world.build(sdf.SEED)
    report = {"errors": [], "warnings": []}
    F = Field([p for p in R.prims if not getattr(p, "phantom", False)], SKY_Y, solids=getattr(R, "solids", ()))
    lo = np.min([b[0] for b in F.boxes], axis=0) - 6
    hi = np.max([b[1] for b in F.boxes], axis=0) + 6
    hi[1] = min(hi[1], SKY_Y + 6)
    lo = np.floor(lo / VOX) * VOX
    report["bounds_lo"] = v3(lo); report["bounds_hi"] = v3(hi)
    report["chambers"] = len(R.chambers)
    print("route built: %d prims, %d chambers, bounds %s .. %s (%.1fs)" % (len(R.prims), len(R.chambers), v3(lo), v3(hi), time.time() - t0))

    resolve(R, F, report)
    print("intents resolved (%.1fs)" % (time.time() - t0))
    repair_stations(R, F, report)

    dims = np.ceil((hi - lo) / VOX).astype(int)
    jobs = []
    for i in range(0, dims[0], BS):
        for j in range(0, dims[1], BS):
            for k in range(0, dims[2], BS):
                n = [min(BS, dims[0] - i), min(BS, dims[1] - j), min(BS, dims[2] - k)]
                origin = lo + VOX * np.array([i, j, k])
                blo, bhi = origin, origin + VOX * np.array(n)
                if F.prims_for_box(blo - 1, bhi + 1):
                    jobs.append((len(jobs), origin, n))
    print("meshing %d blocks..." % len(jobs))
    with Pool(max(1, os.cpu_count() - 4), initializer=_init, initargs=(F,)) as pool:
        results = pool.map(mesh_block, jobs, chunksize=1)
    print("meshed (%.1fs)" % (time.time() - t0))

    nb = max(len(world.BIOMES), 12)
    mat_names = []
    for b in range(nb):
        mat_names += ["B%d_W" % b, "B%d_F" % b]
    nodes = []
    tri_total = 0
    vert_total = 0
    zones = getattr(R, "mouth_zones", [])
    for bi, groups in results:
        if not groups:
            continue
        prims = []
        for g in groups:
            g["mat"] = g["biome"] * 2 + (1 if g["floor"] else 0)
            if zones:
                pos = g["pos"].astype(np.float64)
                bad = np.zeros(len(pos), dtype=bool)
                for (A, d, rad, ln) in zones:
                    q = pos - A
                    t = q @ d
                    perp = np.linalg.norm(q - np.outer(t, d), axis=1)
                    bad |= (np.abs(t) < ln * 0.5) & (perp < rad)
                if bad.any():
                    keep = ~bad[g["idx"]].any(axis=1)
                    g["idx"] = g["idx"][keep]
                    if len(g["idx"]) == 0:
                        continue
            prims.append(g)
            tri_total += len(g["idx"]); vert_total += len(g["pos"])
        if prims:
            nodes.append(("cave_%03d" % bi, prims))
    for i, (kind, m, mat) in enumerate(getattr(R, "tube_meshes", [])):
        m["mat"] = mat
        nodes.append(("%s_%03d" % (kind, i), [m]))
        tri_total += len(m["idx"])
    for i, s in enumerate(R.slabs):
        m = slab_mesh(s["poly"], s["top"], s["bottom"])
        m["mat"] = s["biome"] * 2
        nodes.append(("slab_%03d" % i, [m]))
        tri_total += len(m["idx"])
    for i, c in enumerate(R.columns):
        m = column_mesh(c["x"], c["z"], c["bottom"], c["top"], c["radius"], c["flat"])
        m["mat"] = c["biome"] * 2
        nodes.append(("col_%03d" % i, [m]))
        tri_total += len(m["idx"])
    glb = os.path.join(OUT, "underdark.glb")
    write_glb(glb, nodes, mat_names)
    report["triangles"] = int(tri_total)
    report["cave_vertices"] = int(vert_total)
    report["glb_mb"] = round(os.path.getsize(glb) / 1e6, 2)
    print("glb written: %s tris, %.1f MB (%.1fs)" % (tri_total, report["glb_mb"], time.time() - t0))

    validate(R, F, report, lo, hi)
    L = R.L
    L.pop("slabs_meta", None)
    counts = {k: len(v) for k, v in L.items() if isinstance(v, list)}
    report["counts"] = counts
    min_y = min(z["floor"] for z in L["zones"])
    report["deepest_floor"] = min_y
    report["max_horizontal"] = round(max(math.hypot(z["center"][0], z["center"][2]) for z in L["zones"]), 1)
    path_len = 0.0
    for a_, b_ in zip(L["zones"], L["zones"][1:]):
        path_len += math.dist(a_["center"], b_["center"])
    report["route_length_m"] = round(path_len, 0)
    with open(os.path.join(OUT, "layout.json"), "w", encoding="utf-8") as fh:
        json.dump(L, fh, separators=(",", ":"))
    with open(os.path.join(OUT, "report.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=1)
    print(json.dumps(report, indent=1))

    # preview: top and side views of the cave vertices by biome
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    pal = ["#c8b89a", "#e8e0c8", "#5fd68a", "#8b5a2b", "#4a8f9a", "#9a9aa8", "#8fc0ff", "#ff6a2a", "#b0203a", "#6b5a3a", "#ffffff", "#5a3a1a"]
    fig, axs = plt.subplots(1, 2, figsize=(22, 11))
    for bi, groups in results:
        if not groups:
            continue
        for g in groups:
            pts = g["pos"][:: 7]
            axs[0].scatter(pts[:, 0], pts[:, 2], s=0.05, c=pal[g["biome"]])
            axs[1].scatter(pts[:, 0], pts[:, 1], s=0.05, c=pal[g["biome"]])
    for z in L["zones"]:
        axs[0].annotate(z["name"], (z["center"][0], z["center"][2]), fontsize=7)
        axs[1].annotate(z["name"], (z["center"][0], z["floor"]), fontsize=7)
    axs[0].set_title("top (x, z)"); axs[1].set_title("side (x, y)")
    for ax in axs:
        ax.set_aspect("equal")
    plt.tight_layout()
    plt.savefig(os.path.join(OUT, "preview.png"), dpi=90)
    print("done in %.1fs" % (time.time() - t0))


if __name__ == "__main__":
    main()
