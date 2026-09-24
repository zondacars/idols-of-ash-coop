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

    snap = report.setdefault("snap", {"inside_rock_retried": {}, "inside_rock_fallback": {}, "props_skipped": {}, "props_placed_low": {}})

    def _count(key, kind):
        snap[key][kind] = snap[key].get(kind, 0) + 1

    def floor_at(x, z, y_from, drop=40.0, kind="other", own_y=None):
        """v49 (#95): a probe that STARTS inside rock (a column, an overhang, a boulder) used to
        return its own start height, so the thing was buried there or silently skipped. Look again
        from 3.0 and 4.5 m lower (p.y+3 and p.y+1.5 for the usual p.y+6 start), the way the station
        probe does. If every start is in rock, fall back to the intent's own height (never None, so
        the rng draws that follow a placement stay the same) and count it."""
        fy = F.floor_below(x, z, y_from, drop)
        if fy is None or fy < y_from - 1e-6:
            return fy
        _count("inside_rock_retried", kind)
        for dn in (3.0, 4.5):
            fy2 = F.floor_below(x, z, y_from - dn, drop - dn)
            if fy2 is None:
                break                             # rock above, void below: no floor to find
            if fy2 < y_from - dn - 1e-6:
                return fy2
        _count("inside_rock_fallback", kind)
        return own_y if own_y is not None else fy

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
            fy = floor_at(a["x"], a["z"], a["y_from"], kind="spike_bed", own_y=a["y_from"] - 3.0)
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
                fy = floor_at(p[0], p[2], p[1] + 6.0, kind="prop")
                if fy is None:
                    report["warnings"].append("prop without floor %s at %s" % (a["scene"], v3(p)))
                    _count("props_skipped", "no_floor")
                    continue
                if fy > p[1] + 5.0:
                    _count("props_skipped", "inside_rock")        # every probe started in rock: no buried props
                    continue
                if not headroom(p[0], p[2], fy, 1.0):
                    _count("props_skipped", "no_headroom")        # under a stalactite or a low overhang
                    continue
                if fy < p[1] - 4.0:
                    _count("props_placed_low", "prop")            # counted only: it found a lower ledge
                y = fy - 0.05 + ylift
            box = None
            if a["box"] is not None:
                box = [b * a["scale"] for b in a["box"]]
            ent = {"scene": a["scene"], "pos": v3([p[0], y, p[2]]), "rot": [round(a["rot_x"], 3), round(a["yaw"], 3), 0.0],
                   "scale": round(a["scale"], 3), "box": box, "vis": a["vis"]}
            if box is not None and a.get("boxc") is not None:
                # v49 J4 (#79): the box centre from the prop origin, unrotated frame, already scaled
                ent["box_c"] = [round(c * a["scale"], 3) for c in a["boxc"]]
            if a.get("col") == "hull":
                ent["col"] = "hull"
            if "dim" in a:
                ent["dim"] = a["dim"]
            if a.get("pale"):
                ent["pale"] = True
            if a.get("husk_key"):
                ent["husk_key"] = a["husk_key"]            # v49 K12: resolved to "husk_id" (or dropped) by place_k12
            L["props"].append(ent)
        elif kind == "light":
            p = a["pos"]
            y = p[1]
            if a["snap"]:
                fy = floor_at(p[0], p[2], p[1] + 6.0, kind="light", own_y=p[1])
                if fy is None:
                    continue
                y = fy
            L["lights"].append({"pos": v3([p[0], y + a["lift"], p[2]]), "color": a["color"], "energy": a["energy"], "range": a["range"]})
        elif kind == "fire":
            p = a["pos"]
            fy = floor_at(p[0], p[2], p[1] + 6.0, kind="fire", own_y=p[1])
            if fy is None:
                continue
            L["fires"].append({"pos": v3([p[0], fy, p[2]]), "scale": a["scale"], "beacon": bool(a.get("beacon", False))})
            if a["light"] and not a.get("beacon"):
                L["lights"].append({"pos": v3([p[0], fy + 1.6, p[2]]), "color": [1.0, 0.58, 0.25], "energy": a["energy"], "range": a["range"]})
        elif kind == "ember":
            p = a["pos"]
            fy = floor_at(p[0], p[2], p[1] + 6.0, kind="ember", own_y=p[1])
            if fy is None:
                continue
            L["embers"].append({"pos": v3([p[0], fy + 1.3, p[2]])})
        elif kind == "checkpoint":
            fy = floor_at(a["x"], a["z"], a["y"] + 6.0, kind="checkpoint", own_y=a["y"])
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
                fy = floor_at(a["x"], a["z"], a["y"], kind=kind, own_y=a["y"] - 4.0)
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
            off = float(a.get("off", 1.6))            # tunnel torches sit 1.6 m off the axis; shelf lamps on their line
            for p in a["points"]:
                fy = floor_at(p[0] + off, p[2] + off, p[1] + (3.0 if "trigger" in a else 1.0), kind="dying_light", own_y=p[1])
                if fy is None:
                    continue
                lights.append(v3([p[0] + off, fy, p[2] + off]))
            if lights:
                # v49 (#96): the great shelves pass their own trigger (the centipede's), same schema
                trig = [v3(a["trigger"][0]), float(a["trigger"][1])] if "trigger" in a else [lights[0], 5.0]
                L["dying_lights"].append({"id": a["id"], "trigger": trig, "lights": lights})
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
            fy = floor_at(p[0], p[2], p[1] + 6.0, kind="crystal", own_y=p[1])
            if fy is None:
                continue
            crystals.append({"pos": v3([p[0], fy, p[2]]), "s": round(a["s"], 2), "yaw": round(rng.uniform(0, 6.28), 3),
                             "tilt": round(rng.uniform(-0.3, 0.3), 3)})
        elif kind == "dropper":
            fy = floor_at(a["x"], a["z"], a["ceiling_from"] + 2.0, kind="dropper", own_y=a["y_floor"])
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
                fy = floor_at(p[0], p[2], p[1], 12.0, kind="rubble", own_y=p[1] - 4.0)
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
            fy = floor_at(a["x"], a["z"], a["y"], kind="vent", own_y=a["y"] - 3.0)
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
            fy = floor_at(a["x"], a["z"], a["y"] + 6.0, 70.0, kind="bell", own_y=a["y"])
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
            fy = floor_at(p[0], p[2], p[1] + 5.0, 14.0, kind="ghost", own_y=p[1])
            if fy is None or not headroom(p[0], p[2], fy, 2.0):
                continue
            L["ghosts"].append({"pos": v3([p[0], fy, p[2]]), "yaw": round(godot_yaw_facing(np.array(a["face"])) + math.pi, 4)})
            if len(L["ghosts"]) in (2, 9, 20, 33):
                fc = np.array(a["face"], dtype=float)
                eye = np.array([p[0], fy + 1.8, p[2]]) - fc * 3.0
                L["tour"].append({"pos": v3(eye), "look": v3([p[0], fy + 1.5, p[2]]), "label": "ghost close %d" % len(L["ghosts"])})
        elif kind == "egg":
            fy = floor_at(a["x"], a["z"], a["y"] + 4.0, kind="egg", own_y=a["y"])
            if fy is None or not headroom(a["x"], a["z"], fy, 1.2):
                continue
            L.setdefault("eggs", []).append({"pos": v3([a["x"], fy, a["z"]]), "n": a["n"], "s": round(a["s"], 2)})
        elif kind == "altar":
            fy = floor_at(a["x"], a["z"], a["y"], kind="altar", own_y=a["y"] - 4.0)
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


def _mouth_keep_y(F, A, d, room):
    """v48: the height under which the mouth trim leaves the chamber floor alone. The trim used to
    cut 2-4 m pits in the floor in front of every tube mouth. `room` is the sign of t (along d) on
    the chamber side. Measured from the field a little way into the room, capped under the axis so
    the wall face at the hole is still cut open."""
    dh = np.array([d[0], 0.0, d[2]])
    dh = dh / max(np.linalg.norm(dh), 1e-6)
    lat = np.array([-dh[2], 0.0, dh[0]])
    ys = []
    for t in (1.5, 3.0, 4.5):
        for l in (-1.5, 0.0, 1.5):
            q = A + d * (room * t) + lat * l
            fy = F.floor_below(q[0], q[2], A[1] + 0.3, 4.5)
            if fy is not None and fy < A[1] + 0.1:
                ys.append(fy)
    if not ys:
        return None
    return float(min(max(ys) + 0.35, A[1] - 0.5))


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
        R.mouth_zones.append((A, d0, rs[0] + 1.4, 9.0, _mouth_keep_y(F, A, d0, -1.0), -1.0))
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
                R.mouth_zones.append((Ae, dend, rs[-1] + 1.4, 9.0, _mouth_keep_y(F, Ae, dend, 1.0), 1.0))
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
        cum = np.cumsum(np.concatenate([[0], np.linalg.norm(spts[1:] - spts[:-1], axis=1)]))
        up = np.array([0, 1.0, 0])
        if dec.get("bones"):
            s = 4.0
            while s < total - 3:
                p, t, _ = tubes.along(spts, s)
                r_here = float(np.interp(s, cum, srs))
                side = np.cross(t, up)
                side = side / max(1e-6, np.linalg.norm(side))
                fl = p[1] - 0.55 * r_here
                for k in range(rng.randint(1, 3)):
                    q = p + side * rng.uniform(-0.45, 0.45) * r_here
                    L["props"].append({"scene": "ext/quat/Skull.glb", "pos": v3([q[0], fl - 0.02, q[2]]),
                                       "rot": [round(rng.uniform(-0.6, 0.6), 3), round(rng.uniform(0, 6.28), 3), round(rng.uniform(-0.4, 0.4), 3)],
                                       "scale": round(rng.uniform(0.9, 1.25), 2), "box": None, "vis": 60.0, "dim": 0.35})
                s += dec["bones"] * rng.uniform(0.7, 1.3)
        if dec.get("roots"):
            s = 5.0
            while s < total - 3:
                p, t, _ = tubes.along(spts, s)
                r_here = float(np.interp(s, cum, srs))
                side = np.cross(t, up)
                side = side / max(1e-6, np.linalg.norm(side))
                th = rng.uniform(0.35, 2.8)                       # upper half of the tube wall
                dirw = side * math.cos(th) + up * math.sin(th)
                hit = p + dirw * r_here
                L["dress"].append({"scene": "ext/ph/single_root.glb", "hit": v3(hit), "n": v3(-dirw), "embed": 0.4,
                                   "scale": round(rng.uniform(1.0, 1.6), 2), "yaw": round(rng.uniform(0, 6.28), 3),
                                   "tilt": round(rng.uniform(-0.5, 0.5), 3), "roll": round(rng.uniform(-0.5, 0.5), 3)})
                s += dec["roots"] * rng.uniform(0.7, 1.3)
        if dec.get("husk"):
            # something pale crawled in here and died: a body length of husk, small enough to crawl over
            hs = 0.55
            s0 = min(total - 20.0, max(14.0, total * 0.35))
            n_sec = 11
            for j in range(n_sec):
                s_ = s0 + j * 1.5 * hs
                p, t, _ = tubes.along(spts, s_)
                r_here = float(np.interp(s_, cum, srs))
                side = np.cross(t, up)
                side = side / max(1e-6, np.linalg.norm(side))
                q = p + side * 0.35 * r_here
                fl = p[1] - 0.55 * r_here
                head = j == n_sec - 1
                L["props"].append({"scene": world.A + ("Monster_Head.glb" if head else "Monster_BodySection.glb"),
                                   "pos": v3([q[0], fl + 0.5 * hs, q[2]]),
                                   "rot": [round(rng.uniform(-0.1, 0.1), 3), round(world.godot_yaw_facing(t) + rng.uniform(-0.15, 0.15), 3), 0.0],
                                   "scale": hs, "box": None, "vis": 80.0, "pale": True})
                if j == 5:
                    L["tour"].append({"pos": v3(p - t * 4.0 + np.array([0, 0.15, 0])), "look": v3([q[0], fl + 0.3, q[2]]), "label": "burrow husk", "air": True})
            L["texts"].append({"pos": v3(tubes.along(spts, s0 - 3.0)[0]), "r": 3.0, "text": "Something pale came this way and did not make it out. You crawl over it."})
        if dec.get("bones") and total > 30:
            p, t, _ = tubes.along(spts, 22.0)
            L["tour"].append({"pos": v3(p + np.array([0, 0.1, 0])), "look": v3(tubes.along(spts, 30.0)[0] - np.array([0, 0.5, 0])), "label": "burrow bones", "air": True})
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
        # v49 K12 review: the tube's own centre line and radii, so a flask can sit on the real tube
        # floor (centre - 0.55 r) at the real end of a dead end. On R, not in L, so never written.
        R._tube_ways = getattr(R, "_tube_ways", {})
        R._tube_ways[plan["name"]] = (spts, srs, float(total))
        if plan["true_route"]:
            for ts in (18.0, 58.0, 96.0):
                p, t, _ = tubes.along(spts, min(ts, total - 3))
                L["tour"].append({"pos": v3(p + np.array([0, 0.2, 0])), "look": v3(p + t * 6.0), "label": "burrows %d m" % int(ts)})
        report.setdefault("tubes", []).append({"name": plan["name"], "length_m": round(total, 1), "min_r": round(float(srs.min()), 2)})


def _collect_mouth_tris(zones, g, out):
    """Keep the final (trimmed) triangles near each tube mouth for check_mouth_floors."""
    if len(g["idx"]) == 0:
        return
    tri = g["pos"].astype(np.float64)[g["idx"]]
    cen = tri.mean(axis=1)
    for zi, z in enumerate(zones):
        A, ln = z[0], z[3]
        near = np.linalg.norm(cen - A, axis=1) < ln + 6.0
        if near.any():
            out[zi].append(tri[near])


def check_mouth_floors(zones, mouth_tris, report, F):
    """v48: cast straight down through the FINAL triangles on the chamber side of every tube mouth.
    Every sample must find floor within 1.5 m under the tube axis, or the mouth trim has cut a pit.
    A sample the field puts inside the rock (beside an oblique mouth) is wall, not floor: skipped."""
    worst = []
    counts = []
    for zi, z in enumerate(zones):
        A, d, room = z[0], z[1], z[5]
        tris = np.concatenate(mouth_tris[zi]) if mouth_tris[zi] else np.zeros((0, 3, 3))
        dh = np.array([d[0], 0.0, d[2]])
        dh = dh / max(np.linalg.norm(dh), 1e-6)
        lat = np.array([-dh[2], 0.0, dh[0]])
        a2, b2, c2 = tris[:, 0][:, [0, 2]], tris[:, 1][:, [0, 2]], tris[:, 2][:, [0, 2]]
        v0, v1 = b2 - a2, c2 - a2
        den = v0[:, 0] * v1[:, 1] - v0[:, 1] * v1[:, 0]
        ok_den = np.abs(den) > 1e-9
        den = np.where(ok_den, den, 1.0)
        missing = 0
        for t in (1.5, 2.5, 3.5, 5.0):
            for l in (-1.5, 0.0, 1.5):
                q = A + dh * (room * t) + lat * l
                if float(F.eval(np.array([[q[0], A[1] - 0.3, q[2]]]))[0]) > 0.0:
                    continue
                w = q[[0, 2]] - a2
                u = (w[:, 0] * v1[:, 1] - w[:, 1] * v1[:, 0]) / den
                v = (v0[:, 0] * w[:, 1] - v0[:, 1] * w[:, 0]) / den
                inside = ok_den & (u >= -1e-6) & (v >= -1e-6) & (u + v <= 1.0 + 1e-6)
                ys = tris[inside, 0, 1] + u[inside] * (tris[inside, 1, 1] - tris[inside, 0, 1]) + v[inside] * (tris[inside, 2, 1] - tris[inside, 0, 1])
                hit = ys[(ys <= A[1] + 0.05) & (ys >= A[1] - 1.5)]
                if len(hit) == 0:
                    missing += 1
                    below = ys[ys < A[1] - 1.5]
                    worst.append({"mouth": zi, "t": t, "lat": l, "next_floor_below_axis": round(float(A[1] - below.max()), 2) if len(below) else None})
        counts.append(missing)
        if missing:
            report["errors"].append("tube mouth %d at %s: %d of 12 floor samples on the chamber side find no floor within 1.5 m under the axis" % (zi, v3(A), missing))
    report["mouth_floor_missing"] = counts
    if worst:
        report["mouth_floor_holes"] = worst


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
    validate_built_drops(R, F, report)
    validate_finale_spawns(R, F, report)
    validate_stalker_homes(R, F, report)
    validate_texts(R, report)
    validate_gate_bypass(R, report)
    # v49 (#119): walk_m summed an empty list. It is now the walking the builder planned: the great
    # shelves (terrace walks) and, next to it, the decks and spars that cross the rift.
    report["walk_m"] = round(sum(m["length"] for m in R.moves if m["type"] == "walk"), 0)
    report["spans_m"] = round(sum(m["length"] for m in R.moves if m["type"] in ("span", "spar")), 0)


def snap_stalker_homes(R, F, report):
    """v49 (#39): a stalker home is a point on a landing from the builder, 1 m over where the shelf
    was planned. The real rock can sit a few metres higher or lower (wall noise, the shelf's lip):
    stalker 1 ended 3.4 m inside it. Every home now sits 1 m over the standable floor nearest to it
    in its own column, searched from 8 m above to 45 m below (the runtime's own floor test)."""
    out = []
    for s_ in R.L.get("stalkers", []):
        h = np.array(s_["home"], dtype=float)
        tops = _floor_tops(F, h[0], h[2], h[1] + 8.0, h[1] - 45.0)
        if not tops:
            out.append({"id": s_["id"], "moved_m": None})
            continue
        fy = min(tops, key=lambda y_: abs(y_ - (h[1] - 1.0)))
        s_["home"] = v3([h[0], fy + 1.0, h[2]])
        out.append({"id": s_["id"], "moved_m": round(fy + 1.0 - h[1], 2)})
    report["stalker_home_snap"] = out


# ------------------------------------------------------------------ v49 K12: oil, wall spiders, the waking husk

def _k12_stand(F, x, z, y_ref, tol=2.0):
    """The standable floor nearest y_ref (within +-tol) in this column, with 2.2 m of air over it."""
    tops = [t_ for t_ in _floor_tops(F, x, z, y_ref + tol + 2.4, y_ref - tol - 0.5, step=0.25, head=2.2) if abs(t_ - y_ref) <= tol]
    if not tops:
        return None
    return min(tops, key=lambda t_: abs(t_ - y_ref))


def _k12_walk(F, p, fy_p, q, max_step=1.0):
    """You can walk from p to q on one floor: every metre on the way has rock within max_step of the
    last metre (no gap to fall through, no wall to climb) and head room over it."""
    dx, dz = q[0] - p[0], q[2] - p[2]
    n = int(math.hypot(dx, dz)) + 1
    y = fy_p
    for i in range(1, n + 1):
        x, z = p[0] + dx * i / n, p[2] + dz * i / n
        top = y + max_step + 0.6
        f = F.floor_below(x, z, top, 2.0 * max_step + 0.6)
        if f is None or f > top - 1e-6 or abs(f - y) > max_step:
            return False
        if not np.all(F.eval(np.array([[x, f + 1.0, z], [x, f + 1.8, z]])) < 0.0):
            return False
        y = f
    return True


def _k12_margin(F, x, z, fy, r=1.6):
    """Rock all round, r metres out: not on the lip of a balcony."""
    for k in range(8):
        a = k * math.pi / 4.0
        f = F.floor_below(x + r * math.cos(a), z + r * math.sin(a), fy + 1.0, 2.2)
        if f is None or f > fy + 1.0 - 1e-6:
            return False
    return True


class MeshCols:
    """v49 K12 review: vertical queries against the FINAL triangles (cave blocks after the mouth cuts,
    tubes, collars, slabs, columns): what the game collides with. The field is meshed on 2.5 m voxels,
    so a field floor can be 0.5-3.7 m off the real one (a flask floated 3.7 m up, another sat 0.6 m
    under the floor, spider anchors hung 1 m under the ceiling). Triangle normals point into the air."""

    def __init__(self, nodes, cell=8.0):
        tris, nys = [], []
        for _, prims in nodes:
            for pr in prims:
                I = np.asarray(pr["idx"]).reshape(-1, 3).astype(np.int64)
                if len(I) == 0:
                    continue
                P = np.asarray(pr["pos"], dtype=np.float32)
                N = np.asarray(pr["nrm"], dtype=np.float32)
                tris.append(P[I])
                nys.append(N[I][:, :, 1].mean(axis=1))
        self.T = np.concatenate(tris)
        self.ny = np.concatenate(nys)
        self.cell = cell
        xz = self.T[:, :, [0, 2]]
        c0 = np.floor(xz.min(axis=1) / cell).astype(np.int64)
        c1 = np.floor(xz.max(axis=1) / cell).astype(np.int64)
        sp = c1 - c0
        ids = np.arange(len(self.T), dtype=np.int64)
        keys, owners = [], []
        for di in range(int(sp[:, 0].max()) + 1):
            for dk in range(int(sp[:, 1].max()) + 1):
                m = (sp[:, 0] >= di) & (sp[:, 1] >= dk)
                keys.append(self._key(c0[m, 0] + di, c0[m, 1] + dk))
                owners.append(ids[m])
        keys = np.concatenate(keys)
        owners = np.concatenate(owners)
        o = np.argsort(keys, kind="stable")
        self.keys, self.owners = keys[o], owners[o]

    @staticmethod
    def _key(i, k):
        return (np.asarray(i, dtype=np.int64) + 200000) * 400001 + (np.asarray(k, dtype=np.int64) + 200000)

    def column(self, x, z):
        """[(y, ny)] of every triangle the vertical line through (x, z) crosses, lowest first."""
        key = self._key(int(math.floor(x / self.cell)), int(math.floor(z / self.cell)))
        a0, a1 = np.searchsorted(self.keys, key, "left"), np.searchsorted(self.keys, key, "right")
        if a1 <= a0:
            return []
        cand = self.owners[a0:a1]
        tr = self.T[cand].astype(np.float64)
        a, b, c = tr[:, 0], tr[:, 1], tr[:, 2]
        v0 = b[:, [0, 2]] - a[:, [0, 2]]
        v1 = c[:, [0, 2]] - a[:, [0, 2]]
        v2 = np.array([x, z]) - a[:, [0, 2]]
        den = v0[:, 0] * v1[:, 1] - v1[:, 0] * v0[:, 1]
        ok = np.abs(den) > 1e-12
        den = np.where(ok, den, 1.0)
        u = (v2[:, 0] * v1[:, 1] - v1[:, 0] * v2[:, 1]) / den
        w = (v0[:, 0] * v2[:, 1] - v2[:, 0] * v0[:, 1]) / den
        ins = ok & (u >= -1e-9) & (w >= -1e-9) & (u + w <= 1.0 + 1e-9)
        y = a[:, 1] + u * (b[:, 1] - a[:, 1]) + w * (c[:, 1] - a[:, 1])
        return sorted(zip(y[ins].tolist(), self.ny[cand][ins].tolist()))

    def floor_near(self, x, z, y, band=0.8, head=1.8):
        """The real floor nearest y (within band), facing up, with `head` m of nothing over it."""
        col = self.column(x, z)
        best = None
        for (s, ny) in col:
            if ny < 0.2 or abs(s - y) > band:
                continue
            if any(s + 0.05 < s2 < s + head for (s2, _) in col):
                continue
            if best is None or abs(s - y) < abs(best - y):
                best = s
        return best

    def ceiling_over(self, x, z, fy):
        """The first surface over a floor at fy, if it faces down (a real ceiling), else None."""
        for (s, ny) in self.column(x, z):
            if s > fy + 0.05:
                return s if ny < -0.2 else None
        return None

    def ring(self, x, z, fy, r, tol=0.6):
        """How many of 8 points r metres out have floor within tol of fy (8 = not on a lip)."""
        n = 0
        for k in range(8):
            a = k * math.pi / 4.0
            col = self.column(x + r * math.cos(a), z + r * math.sin(a))
            if any(ny >= 0.2 and abs(s - fy) <= tol for (s, ny) in col):
                n += 1
        return n


def _k12_prop_clear(L, q, fy, base=1.5):
    """Not inside or against a prop: a boxed prop's footprint plus 0.7 m, 3 m round the big unboxed
    rocks and buildings (visual only, a flask vanished into them), `base` round anything else."""
    for p in L["props"]:
        pp = p["pos"]
        if abs(pp[1] - fy) > 6.0:
            continue
        d = math.hypot(pp[0] - q[0], pp[2] - q[2])
        if d > 6.0:
            continue
        nm = p["scene"]
        if p.get("box") is not None:
            r = max(p["box"][0], p["box"][2]) + 0.7
        elif any(k in nm for k in ("boulder", "rocks", "Tower", "Structure", "Building", "Roof", "Wall", "Tent", "Monster_")):
            r = 3.0
        else:
            r = base
        if d < r:
            return False
    return True


def place_k12(R, F, report, M):
    """v49 K12: the lantern-oil flasks, the wall spiders of the Rootworks and Crystal Veins, and the
    one great-shelf husk that wakes. Its own rng (never the builder's), so the rest of the layout is
    unchanged by this pass. Runs after meshing (it adds no geometry) so every flask and spider can be
    checked against, and put on, the real triangles (M)."""
    import random
    rng = random.Random(sdf.SEED + 4912)
    k12 = report.setdefault("k12", {})
    _k12_husk(R, F, report, k12)
    _k12_oil(R, F, report, k12, rng, M)
    _k12_spiders(R, F, report, k12, rng, M)
    _k12_snap_homes(R, report, M)


def _k12_snap_homes(R, report, M):
    """Stalker homes: 1 m over the real floor under them (the field floor can be 1-2 m off)."""
    for s_, rec in zip(R.L.get("stalkers", []), report.get("stalker_home_snap", [])):
        h = s_["home"]
        f = M.floor_near(h[0], h[2], h[1] - 1.0, band=2.5, head=1.6)
        rec["mesh_floor_below_m"] = None if f is None else round(h[1] - f, 2)
        if f is not None:
            s_["home"] = v3([h[0], f + 1.0, h[2]])


def _k12_husk(R, F, report, k12):
    """One dead centipede on a great shelf is not dead. Pick the shelf husk that is whole (head and
    at least 12 sections down), on a shelf where nothing else lives (no centipede, no dying lamps),
    best with its head toward where you land: you walk its length and it gets up behind you."""
    L = R.L
    husks = L.pop("_terrace_husks", [])
    best = None
    for h in husks:
        secs = h["sections"]
        if h["lives"] or len(secs) < 12 or secs[-1][0] != h["n_sec"] - 1:
            continue
        path = np.array(h["path"], dtype=float)
        plen = float(np.linalg.norm(path))
        pdir = path / plen
        land = np.array(h["land"], dtype=float)
        t_head = float((secs[-1][1] - land) @ pdir) / plen
        t_tail = float((secs[0][1] - land) @ pdir) / plen
        land_side = t_head < t_tail
        score = len(secs) + (10 if land_side else 0) + (5 if world.FUNGAL <= h["biome"] <= world.CRYSTAL else 0)
        if best is None or score > best[0]:
            best = (score, h, land, path, plen, pdir, t_head, land_side)
    chosen = None
    if best is not None:
        _, h, land, path, plen, pdir, t_head, land_side = best
        head = h["sections"][-1][1]
        tail = h["sections"][0][1]
        if land_side:
            P = head + (tail - head) * 0.65                 # two thirds of its length walked: the head is behind you
            t = float((P - land) @ pdir) / plen
        else:
            t = t_head + 10.0 / plen                        # just past its head
        t = min(0.92, max(0.08, t))
        q = land + path * t
        fy = _k12_stand(F, q[0], q[2], float(land[1]), 3.0)
        trig = [q[0], (fy if fy is not None else float(land[1])) + 1.0, q[2]]
        fh = _k12_stand(F, head[0], head[2], h["y_top"], 3.0)
        chosen = h["key"]
        L["waking_husk"] = {"id": "wh1", "trigger": v3(trig), "r": 6.0,
                            "head": v3([head[0], (fh if fh is not None else h["y_top"]) + 1.0, head[2]]),
                            "yaw": round(float(godot_yaw_facing(np.array(h["hdir"], dtype=float))), 4)}
        k12["waking_husk"] = {"biome": world.BIOMES[h["biome"]], "shelf": h["idx"], "sections": len(h["sections"]),
                              "head_toward_landing": bool(land_side), "trigger_along_walk": round(t, 2),
                              "trigger_to_head_m": round(float(np.linalg.norm(np.array(trig) - head)), 1)}
    tagged = 0
    for e in L["props"]:
        k = e.pop("husk_key", None)
        if k is not None and k == chosen:
            e["husk_id"] = "wh1"
            tagged += 1
    if chosen is None:
        report["errors"].append("waking husk: no whole great-shelf husk on a quiet shelf")
    else:
        k12["waking_husk"]["props_tagged"] = tagged
        if tagged < 12:
            report["errors"].append("waking husk: only %d props tagged" % tagged)


def _k12_oil(R, F, report, k12, rng, M):
    """2-4 flasks per biome from the Ossuary down, spread over its height: every other one on the
    route (the back of a balcony you stand on anyway), the rest a short detour (the far side of a
    great shelf, the back of a long balcony, the end of a dead-end tube)."""
    L, rift = R.L, R.rift
    st = [s_ for s_ in L["stations"] if s_["kind"] != "hard"]
    main_xyz = np.array([s_["pos"] for s_ in st], dtype=float)
    hazards = [np.array(x_["pos"], dtype=float) for x_ in L.get("spikes", []) + L.get("vents", []) + L.get("crumbles", [])]
    lava = L.get("lava", [])
    placed = []

    def over_lava(q, fy):
        for lv in lava:                                     # the lake is an axis-aligned rectangle (yaw 0)
            c_ = lv["center"]
            if abs(q[0] - c_[0]) <= lv["half_w"] and abs(q[2] - c_[2]) <= lv["half_l"] and fy < c_[1] + float(lv.get("kill_top", 5.0)) + 4.0:
                return True
        return False

    def clear_of(q, fy):
        p3 = np.array([q[0], fy, q[2]])
        if over_lava(q, fy):
            return False
        if any(float(np.linalg.norm(p3 - z_)) < 5.0 for z_ in hazards):
            return False
        return all(float(np.linalg.norm(p3 - z_)) > 30.0 for z_ in placed)

    def real_floor(q, fy, ring_r):
        """The mesh floor the flask will really stand on: near the field floor, 1.8 m of air over
        it, not on a lip, clear of props. None = reject this spot."""
        y2 = M.floor_near(q[0], q[2], fy, band=0.6, head=1.8)
        if y2 is None or M.ring(q[0], q[2], y2, ring_r) < 8 or not _k12_prop_clear(L, q, y2):
            return None
        return y2

    def on_route(s_):
        p = np.array(s_["pos"], dtype=float)
        cx, cz = rift.center(p[1])
        o = np.array([p[0] - float(cx), 0.0, p[2] - float(cz)])
        o = o / max(float(np.linalg.norm(o)), 1e-6)
        lat = np.array([-o[2], 0.0, o[0]])
        for (u, v) in ((2.5, 0.0), (1.5, 1.5), (1.5, -1.5), (3.5, 0.0), (0.8, 2.5), (0.8, -2.5)):
            q = p + o * u + lat * v
            fy = _k12_stand(F, q[0], q[2], p[1], 1.5)
            if fy is None or not clear_of(q, fy) or not _k12_margin(F, q[0], q[2], fy, 1.2):
                continue
            if _k12_walk(F, p, p[1], q):
                y2 = real_floor(q, fy, 1.2)
                if y2 is not None:
                    return [q[0], y2, q[2]]
        return None

    def detour(s_):
        p = np.array(s_["pos"], dtype=float)
        near = main_xyz[np.abs(main_xyz[:, 1] - p[1]) < 8.0]
        best = None
        found = 0
        for _ in range(90):
            a = rng.uniform(0.0, 2.0 * math.pi)
            d = rng.uniform(9.0, 28.0)
            q = p + np.array([math.cos(a) * d, 0.0, math.sin(a) * d])
            dmin = float(np.min(np.linalg.norm((near - q)[:, [0, 2]], axis=1))) if len(near) else 99.0
            if dmin < 8.0:
                continue                                    # still on the line: not a detour
            f0 = F.floor_below(q[0], q[2], p[1] + 2.5, 5.0)
            if f0 is None or f0 > p[1] + 2.5 - 1e-6:
                continue
            fy = _k12_stand(F, q[0], q[2], p[1], 2.0)
            if fy is None or not clear_of(q, fy) or not _k12_margin(F, q[0], q[2], fy, 1.6):
                continue
            if not _k12_walk(F, p, p[1], q):
                continue
            y2 = real_floor(q, fy, 1.6)
            if y2 is None:
                continue
            sc = min(dmin, 16.0) - 0.3 * abs(y2 - p[1])
            if best is None or sc > best[0]:
                best = (sc, [q[0], y2, q[2]])
            found += 1
            if found >= 6:
                break
        return None if best is None else best[1]

    out = []
    for b in range(world.OSSUARY, world.NEST):
        cand = [s_ for s_ in st if s_["biome"] == b and s_["kind"] in ("shelf", "terrace")]
        ys = [s_["pos"][1] for s_ in st if s_["biome"] == b]
        if not cand:
            continue
        y_hi, y_lo = max(ys), min(ys)
        H = y_hi - y_lo
        n = 2 + (1 if H > 600.0 else 0) + (1 if H > 900.0 else 0)
        for k in range(n):
            want_detour = k % 2 == 1
            b_hi = y_hi - H * k / n
            b_lo = y_hi - H * (k + 1) / n
            ym = 0.5 * (b_hi + b_lo)
            pool = sorted([s_ for s_ in cand if b_lo - 1.0 <= s_["pos"][1] <= b_hi + 1.0], key=lambda s_: abs(s_["pos"][1] - ym))
            pos, kind = None, None
            for s_ in pool[:16]:
                pos = detour(s_) if want_detour else on_route(s_)
                if pos is not None:
                    kind = "detour" if want_detour else "route"
                    break
            if pos is None:
                for s_ in pool[:16]:
                    pos = on_route(s_) if want_detour else detour(s_)
                    if pos is not None:
                        kind = "route" if want_detour else "detour"
                        break
            if pos is None:
                # no balcony in this band (a foothold ladder like the Plunge): the nearest balcony
                # outside it, still 30 m from any other flask
                rest = sorted([s_ for s_ in cand if s_ not in pool], key=lambda s_: abs(s_["pos"][1] - ym))
                for s_ in rest[:16]:
                    pos, kind = (detour(s_), "detour") if want_detour else (None, None)
                    if pos is None:
                        pos, kind = on_route(s_), "route"
                    if pos is not None:
                        break
            if pos is None:
                report["warnings"].append("oil: no spot for flask %d of %s" % (k + 1, world.BIOMES[b]))
                continue
            placed.append(np.array(pos, dtype=float))
            out.append((b, kind, pos))
    # THE NEST: one where you land, one out in the nest itself, clear of the idol run and the eggs
    zones = {z_["name"]: z_ for z_ in L["zones"]}
    altar = np.array(L["altar"][0]["pos"], dtype=float) if L.get("altar") else None
    eggs = [np.array(e_["pos"], dtype=float) for e_ in L.get("eggs", [])]
    for (zname, kind, r0, r1) in (("Nest Landing", "route", 3.0, 8.0), ("The Nest", "detour", 16.0, 34.0)):
        z_ = zones.get(zname)
        if z_ is None:
            continue
        c = np.array(z_["center"], dtype=float)
        got = None
        for _ in range(80):
            a = rng.uniform(0.0, 2.0 * math.pi)
            d = rng.uniform(r0, r1)
            q = c + np.array([math.cos(a) * d, 0.0, math.sin(a) * d])
            if altar is not None and float(np.linalg.norm((q - altar)[[0, 2]])) < 14.0:
                continue
            if any(float(np.linalg.norm((q - e_)[[0, 2]])) < 4.0 for e_ in eggs):
                continue
            fy = _k12_stand(F, q[0], q[2], float(z_["floor"]), 3.0)
            if fy is None or not clear_of(q, fy) or not _k12_margin(F, q[0], q[2], fy, 1.6):
                continue
            y2 = real_floor(q, fy, 1.6)
            if y2 is None:
                continue
            got = [q[0], y2, q[2]]
            break
        if got is None:
            report["warnings"].append("oil: no spot in %s" % zname)
            continue
        placed.append(np.array(got, dtype=float))
        out.append((world.NEST, kind, got))
    # THE BURROWS: one half way through, one at the very end of dead end A, before the body there.
    # The tubes are not in the field: their flat floor is the centre line minus 0.55 r (tubes.py),
    # checked on the tube mesh itself. Slide along the tube past the bones.
    ways = getattr(R, "_tube_ways", {})
    for (tname, kind, pick) in (("the way through", "route", "mid"), ("dead end A", "detour", "end")):
        if tname not in ways:
            report["warnings"].append("oil: no tube %s" % tname)
            continue
        spts, srs, total = ways[tname]
        s0 = total * 0.5 if pick == "mid" else total - 5.5
        got = None
        for ds in (0.0, -1.0, 1.0, -2.0, 2.0, -3.0, -4.0, -5.0):
            s = min(max(s0 + ds, 2.0), total - 4.5)
            p, t, i = tubes.along(spts, s)
            if abs(float(t[1])) >= 0.6:
                continue                                    # a steep bit has no flat floor
            fl = float(p[1]) - 0.55 * float(srs[min(i, len(srs) - 1)])
            y2 = M.floor_near(p[0], p[2], fl, band=0.4, head=1.1)
            if y2 is None or not _k12_prop_clear(L, p, y2, base=0.7):
                continue
            got = [float(p[0]), y2, float(p[2])]
            break
        if got is None:
            report["warnings"].append("oil: no spot in %s" % tname)
            continue
        placed.append(np.array(got, dtype=float))
        out.append((world.BURROWS, kind, got))
    L["oil"] = []
    by_b = {}
    for i, (b, kind, pos) in enumerate(out):
        L["oil"].append({"id": "oil_%d" % (i + 1), "pos": v3(pos), "biome": int(b)})
        by_b.setdefault(world.BIOMES[b], {"route": 0, "detour": 0})[kind] += 1
    k12["oil"] = {"total": len(out), "route": sum(1 for o_ in out if o_[1] == "route"),
                  "detour": sum(1 for o_ in out if o_[1] == "detour"), "by_biome": by_b}
    for b in range(world.OSSUARY, 10):
        nb = sum(1 for o_ in out if o_[0] == b)
        if not 2 <= nb <= 4:
            report["errors"].append("oil: %s has %d flasks (want 2-4)" % (world.BIOMES[b], nb))


def _k12_spiders(R, F, report, k12, rng, M):
    """Wall spiders where a walkway runs under rock with 6-14 m of air over it, in the Rootworks and
    the Crystal Veins. anchor = the ceiling point, floor = the walkable point under it."""
    L = R.L
    st = [s_ for s_ in L["stations"] if s_["kind"] != "hard"]
    cps = [np.array(c_["pos"], dtype=float) for c_ in L.get("checkpoints", [])]
    wh = L.get("waking_husk")
    busy = [np.array(wh["trigger"], dtype=float), np.array(wh["head"], dtype=float)] if wh else []
    cand = []
    for b in (world.ROOTS, world.CRYSTAL):
        own = [s_ for s_ in st if s_["biome"] == b and s_["kind"] in ("shelf", "terrace", "span", "foothold")]
        pts = []
        n_try = max(8, int(720 / max(len(own), 1)))         # the Rootworks has few stand points: look harder round each
        for s_ in own:
            p = np.array(s_["pos"], dtype=float)
            pts.append((p, p))
            for _ in range(n_try):
                a = rng.uniform(0.0, 2.0 * math.pi)
                d = rng.uniform(2.0, 12.0)
                pts.append((p + np.array([math.cos(a) * d, 0.0, math.sin(a) * d]), p))
        for (q, base) in pts:
            fy = _k12_stand(F, q[0], q[2], base[1], 1.5)
            if fy is None:
                continue
            up = F.ray_to_rock([q[0], fy + 1.0, q[2]], [0, 1, 0], 15.5, 0.1)
            if up is None:
                continue
            hh = 1.0 + up
            if not 6.0 <= hh <= 14.0:
                continue
            n_ok = 0                                        # something to cling to (a ceiling or a root), not a knife edge
            for (dx, dz) in ((1.5, 0.0), (-1.5, 0.0), (0.0, 1.5), (0.0, -1.5)):
                u2 = F.ray_to_rock([q[0] + dx, fy + 1.0, q[2] + dz], [0, 1, 0], 18.0, 0.2)
                if u2 is not None and abs((1.0 + u2) - hh) <= 4.0:
                    n_ok += 1
            ok = n_ok >= 2
            f3 = np.array([q[0], fy, q[2]])
            if not ok or any(float(np.linalg.norm(f3 - c_)) < 10.0 for c_ in cps):
                continue
            if any(float(np.linalg.norm(f3 - c_)) < 30.0 for c_ in busy):
                continue                                    # the waking husk's shelf has its own scare
            if (q is not base) and not _k12_walk(F, base, base[1], q):
                continue
            # the real triangles: the floor near the field floor and, straight over it with nothing
            # between, a real ceiling (a down-facing face) 6-14 m up. The anchor sits on that face.
            mf = M.floor_near(q[0], q[2], fy, band=0.8, head=2.0)
            if mf is None or M.ring(q[0], q[2], mf, 1.0) < 6:
                continue
            mc = M.ceiling_over(q[0], q[2], mf)
            if mc is None or not 6.0 <= mc - mf <= 14.0:
                continue
            fy, hh = mf, mc - mf
            # best: ~9 m of air (a long, readable drop) and close to where people actually walk
            cand.append((abs(hh - 9.0) + 0.3 * float(np.linalg.norm((q - base)[[0, 2]])), b, [q[0], fy, q[2]], hh))
    cand.sort(key=lambda c_: c_[0])
    chosen = []
    for b in (world.ROOTS, world.CRYSTAL):                  # each biome picks its own (at most 7), 20 m apart
        for (_, b_, f, hh) in cand:
            if b_ != b:
                continue
            if sum(1 for c_ in chosen if c_[0] == b) >= 7:
                break
            if any(float(np.linalg.norm(np.array(f) - np.array(c_[1]))) < 20.0 for c_ in chosen):
                continue
            chosen.append((b, f, hh))
    chosen.sort(key=lambda c_: -c_[1][1])
    L["spiders"] = []
    for i, (b, f, hh) in enumerate(chosen):
        L["spiders"].append({"id": "sp_%d" % (i + 1), "anchor": v3([f[0], f[1] + hh - 0.05, f[2]]), "floor": v3(f), "biome": int(b)})
    k12["spiders"] = {"total": len(chosen), "candidates": len(cand),
                      "by_biome": {world.BIOMES[b]: sum(1 for c_ in chosen if c_[0] == b) for b in (world.ROOTS, world.CRYSTAL)},
                      "headroom_m": [round(c_[2], 1) for c_ in chosen]}
    if not 8 <= len(chosen) <= 14:
        report["errors"].append("spiders: %d placed (want 8-14, %d candidate spots)" % (len(chosen), len(cand)))


def validate_stalker_homes(R, F, report):
    """v49 (#39): a stalker whose home has no floor under it snaps back there on every step and never
    moves (underdark.gd casts from home+8 m down to home-45 m). Same test here, and the home must be
    in open air. A home far from every stand point is only a warning."""
    L = R.L
    st = [np.array(s_["pos"], dtype=float) for s_ in L.get("stations", []) if s_["kind"] != "hard"]
    out = []
    for s_ in L.get("stalkers", []):
        h = np.array(s_["home"], dtype=float)
        v = float(F.eval(h[None, :])[0])
        fy = F.floor_below(h[0], h[2], h[1] + 8.0, 53.0)
        near = min((float(np.linalg.norm(h - q)) for q in st), default=1e9)
        out.append({"id": s_["id"], "floor_below_m": None if fy is None else round(float(h[1] - fy), 1), "nearest_station_m": round(near, 1)})
        if v >= 0.0:
            report["errors"].append("stalker %s home %s is inside rock" % (s_["id"], v3(h)))
        elif fy is None:
            report["errors"].append("stalker %s home %s has no floor within 45 m below it" % (s_["id"], v3(h)))
        if near > 40.0:
            report["warnings"].append("stalker %s home is %.0f m from the nearest stand point" % (s_["id"], near))
    report["stalker_homes"] = out


def validate_texts(R, report):
    """v49 (#51): two text spheres that overlap show one text over the other. A text whose centre is
    inside another text's sphere can be hidden outright: an error. A partial overlap is a warning."""
    T = R.L.get("texts", [])
    worst = []
    for i in range(len(T)):
        for j in range(i + 1, len(T)):
            d = math.dist(T[i]["pos"], T[j]["pos"])
            ri, rj = float(T[i]["r"]), float(T[j]["r"])
            if d < ri + rj:
                worst.append((round(d, 1), i, j))
                if d < max(ri, rj):
                    report["errors"].append("text %d (%s...) and text %d (%s...) are %.1f m apart: one hides the other"
                                            % (i, T[i]["text"][:30], j, T[j]["text"][:30], d))
    report["text_overlaps"] = {"partial": len(worst), "pairs": worst[:12]}


def validate_gate_bypass(R, report):
    """v49 (#20): a co-op door must not be skippable with one rappel. No main-route stand point
    after a gate's entry balcony may lie within 63 m under it (23 m of rope plus a survivable fall)
    and 30 m to the side of it."""
    st = R.L.get("stations", [])
    for entry, after in (("KILN GATE", "ROOTWORKS"), ("PLATE HALL", "BELOW THE PLATES")):
        ei = [i for i, s_ in enumerate(st) if s_["label"] == entry]
        ai = [i for i, s_ in enumerate(st) if s_["label"] == after]
        if not ei or not ai:
            report["errors"].append("gate check: no %s or %s balcony found" % (entry, after))
            continue
        for i in ei:
            a_ = np.array(st[i]["pos"], dtype=float)
            for j in range(ai[0], len(st)):
                if st[j]["kind"] == "hard":
                    continue
                b_ = np.array(st[j]["pos"], dtype=float)
                dy = a_[1] - b_[1]
                h = float(np.linalg.norm((a_ - b_)[[0, 2]]))
                if 0.0 < dy < 63.0 and h < 30.0:
                    report["errors"].append("%s can be skipped: station %d (%s %s) is %.1f m below and %.1f m beside station %d"
                                            % (entry, j, st[j]["kind"], st[j]["label"], dy, h, i))


def _floor_tops(F, x, z, y_hi, y_lo, step=0.5, head=1.5):
    """Every floor surface (air above rock, with `head` m of air over it) in a vertical column."""
    ys = np.arange(y_hi, y_lo, -step)
    if len(ys) < 3:
        return []
    P = np.stack([np.full(len(ys), x), ys, np.full(len(ys), z)], axis=1)
    air = F.eval(P) < 0.0
    k = max(1, int(round(head / step)))
    out = []
    for i in np.nonzero(air[:-1] & ~air[1:])[0]:
        if i - k + 1 >= 0 and air[i - k + 1:i + 1].all():
            fy = float(ys[i + 1])
            # standable, not a bump on a wall: floor within 0.6 m on all four sides, 0.8 m out
            ok = True
            for (dx, dz) in ((0.8, 0.0), (-0.8, 0.0), (0.0, 0.8), (0.0, -0.8)):
                f2 = F.floor_below(x + dx, z + dz, fy + 1.2, 1.8)
                if f2 is None or abs(f2 - fy) > 0.6 or f2 > fy + 1.1:
                    ok = False
                    break
            if ok:
                out.append(fy)
    return out


def validate_built_drops(R, F, report, limit=23.6):
    """v48 (#16): the drops in R.moves are what the builder PLANNED. This walks the main-route stand
    points in order and measures what was BUILT: when the next stand point is more than `limit`
    below the last one, something to stand on must exist between them (a span deck, a tunnel floor,
    a hanging house, a spar), found with the same field floor probes, so that no single fall in
    the chain is longer than `limit`. Short Way ledges are separate routes and are skipped."""
    L = R.L
    st = L.get("stations", [])
    plats = [np.array(p_["pos"], dtype=float) for p_ in L.get("platforms", [])]
    spar_pts = []
    for sp in L.get("spars", []):
        a_, b_ = np.array(sp["a"], dtype=float), np.array(sp["b"], dtype=float)
        n_ = max(2, int(np.linalg.norm(b_ - a_) / 4.0))
        for f in np.linspace(0.0, 1.0, n_):
            spar_pts.append(a_ + (b_ - a_) * f + np.array([0, float(sp["r"]), 0]))
    tun_pts = []
    for p_ in R.prims:
        if getattr(p_, "kind", "") == "tunnel" and not getattr(p_, "phantom", False):
            ln = float(np.linalg.norm(p_.b - p_.a))
            for f in np.linspace(0.0, 1.0, max(2, int(ln / 2.0))):
                q = p_.a + (p_.b - p_.a) * f
                tun_pts.append(np.array([q[0], q[1] - 0.55 * p_.r, q[2]]))
    for ch in R.chambers:
        tun_pts.append(np.array([ch.c[0], ch.floor_y, ch.c[2]]))
    for plan in getattr(R, "tube_plans", []):          # the Burrows crawl tubes are meshed by hand
        if plan.get("true_route"):
            for q, r_ in zip(plan["pts"], plan["rs"]):
                tun_pts.append(np.array([q[0], q[1] - 0.55 * float(r_), q[2]]))
    tun_pts = np.array(tun_pts) if tun_pts else np.zeros((0, 3))

    def stand_y(s_, upper):
        """A station is a small area, not a point: probe a 3 x 3 grid 1.5 m apart and stand on the
        lowest floor of the one you leave (you can always lower yourself) and the highest floor of
        the one you land on. A floor needs 1.9 m of air over it."""
        p = s_["pos"]
        if s_["kind"] in ("platform", "gantry") or s_.get("repaired"):
            return float(p[1])
        fys = []
        for dx in (-1.5, 0.0, 1.5):
            for dz in (-1.5, 0.0, 1.5):
                fy = F.floor_below(p[0] + dx, p[2] + dz, p[1] + 4.5, 9.0)
                if fy is not None and p[1] - 1.6 <= fy <= p[1] + 2.6:
                    fys.append(float(fy))
        if not fys:
            return float(p[1])
        return min(fys) if upper else max(fys)

    worst = []
    checked = 0
    built_max = 0.0
    for i in range(len(st) - 1):
        a_, b_ = st[i], st[i + 1]
        if a_["kind"] == "hard" or b_["kind"] == "hard":
            continue
        ya, yb = stand_y(a_, True), stand_y(b_, False)
        dy = ya - yb
        if dy <= limit:
            built_max = max(built_max, dy)
            continue
        checked += 1
        pa, pb = np.array(a_["pos"], dtype=float), np.array(b_["pos"], dtype=float)
        seg = (pb - pa)[[0, 2]]
        seg_l = float(np.linalg.norm(seg))
        hs = []
        n_col = max(2, min(80, int(seg_l / 2.0) + 1))
        for f in np.linspace(0.0, 1.0, n_col):
            q = pa + (pb - pa) * f
            hs += _floor_tops(F, q[0], q[2], ya + 2.0, yb - 1.0)

        def near_seg(q, reach):
            w = (q - pa)[[0, 2]]
            t = float(np.clip((w @ seg) / max(seg_l * seg_l, 1e-9), 0.0, 1.0))
            return float(np.linalg.norm(w - seg * t)) < reach

        for q in plats:                       # hanging houses and gantries are not in the field
            if near_seg(q, 25.0):
                hs.append(float(q[1]))
        for q in spar_pts:                    # nor are the crystal spars
            if near_seg(q, 25.0):
                hs.append(float(q[1]))
        if len(tun_pts):                      # a walk through the rock: tunnels and their rooms
            dd = np.minimum(np.linalg.norm(tun_pts - pa, axis=1), np.linalg.norm(tun_pts - pb, axis=1))
            if (dd < 40.0).any():
                box_lo, box_hi = np.minimum(pa, pb) - 120.0, np.maximum(pa, pb) + 120.0
                m_ = np.all((tun_pts >= box_lo) & (tun_pts <= box_hi), axis=1)
                hs += [float(v) for v in tun_pts[m_, 1]]
        chain = sorted([ya, yb] + [h for h in hs if yb + 0.5 < h < ya - 0.5], reverse=True)
        step = max(chain[k] - chain[k + 1] for k in range(len(chain) - 1))
        built_max = max(built_max, step)
        worst.append((round(step, 1), i, i + 1, a_["kind"], b_["kind"], round(dy, 1)))
        if step > limit:
            report["errors"].append("built drop of %.1f m with nothing to stand on between station %d (%s %s) and %d (%s), %.1f m lower"
                                    % (step, i, a_["kind"], a_.get("label", ""), i + 1, b_["kind"], dy))
    worst.sort(reverse=True)
    report["built_drops"] = {"pairs_over_limit_checked": checked, "max_unbridged_step": round(built_max, 1), "worst": worst[:10]}


def validate_finale_spawns(R, F, report):
    """v48: the creatures that wake on the idol, and the Follower's finale spawn, must start in open
    air with floor under them (the Follower used to spawn over the Nest chasm)."""
    L = R.L
    pts = []
    for c_ in L.get("centipedes", []):
        if c_.get("on"):
            pts += [("%s %s" % (c_["id"], c_["on"]), sp) for sp in c_["spawn"]]
    if L.get("follower_finale"):
        pts.append(("follower_finale", L["follower_finale"]["spawn"]))
    for name, sp in pts:
        p = np.array(sp, dtype=float)
        v = float(F.eval(p[None, :])[0])
        fy = F.floor_below(p[0], p[2], p[1], 12.0)
        if v >= 0.0 or fy is None:
            report["errors"].append("%s spawn %s is %s" % (name, v3(p), "inside rock" if v >= 0.0 else "over no floor within 12 m"))


def unbury_lanterns(R, F, report):
    """v48 (#50): no guide lamp may sit inside rock. Shelves, overhangs and caves add rock the rift
    formula cannot see, so check every lantern against the real field and walk a buried one out
    toward the middle of the rift, 0.5 m at a time, until it has 1 m of air around it (8 m at most)."""
    rift = getattr(R, "rift", None)
    lan = R.L.get("lanterns", [])
    if rift is None or not lan:
        return
    P = np.array([l_["pos"] for l_ in lan], dtype=np.float64)
    v = np.array([float(F.eval(P[i:i + 1])[0]) for i in range(len(P))])
    inside0 = int((v > 0.0).sum())
    moved = 0
    stuck = 0
    steps = np.arange(0.5, 8.01, 0.5)
    for i in np.nonzero(v > -1.0)[0]:
        p = P[i]
        cx, cz = rift.center(p[1])
        dirv = np.array([float(cx) - p[0], 0.0, float(cz) - p[2]])
        n = float(np.linalg.norm(dirv))
        if n < 1e-6:
            continue
        dirv = dirv / n
        done = False
        best = None
        # out toward the middle of the rift first; under an overhang, out and down
        for dv in (dirv, dirv * 0.7 + np.array([0, -0.7, 0]), dirv * 0.7 + np.array([0, 0.7, 0])):
            cand = p[None, :] + steps[:, None] * dv[None, :]
            vc = F.eval(cand)
            ok = np.nonzero(vc <= -1.0)[0]
            if len(ok):
                lan[i]["pos"] = v3(cand[ok[0]])
                moved += 1
                done = True
                break
            j = int(np.argmin(vc))
            if best is None or vc[j] < best[0]:
                best = (float(vc[j]), cand[j])
        if not done:
            if v[i] > 0.0 and best is not None and best[0] < 0.0:
                lan[i]["pos"] = v3(best[1])           # at least out of the rock
                moved += 1
            elif v[i] > 0.0:
                lan[i]["drop"] = True                 # buried deep: nobody can see it, remove it
                stuck += 1
    if stuck:
        R.L["lanterns"] = [l_ for l_ in lan if not l_.get("drop")]
    report["lanterns_inside_rock_before"] = inside0
    report["lanterns_moved_out"] = moved
    report["lanterns_removed_buried"] = stuck
    if stuck:
        report["warnings"].append("%d lanterns were buried deeper than an 8 m walk out and were removed" % stuck)
    print("lanterns: %d inside rock, %d moved out, %d removed" % (inside0, moved, stuck))


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
    report["warnings"] += R.L.pop("warnings_gen", [])          # v49 (#71): planned terraces that were not built
    repair_stations(R, F, report)
    unbury_lanterns(R, F, report)
    snap_stalker_homes(R, F, report)

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
    mouth_tris = [[] for _ in zones]
    for bi, groups in results:
        if not groups:
            continue
        prims = []
        for g in groups:
            g["mat"] = g["biome"] * 2 + (1 if g["floor"] else 0)
            if zones:
                pos = g["pos"].astype(np.float64)
                cut = np.zeros(len(g["idx"]), dtype=bool)
                cen = None
                for (A, d, rad, ln, keep_y, room) in zones:
                    q = pos - A
                    t = q @ d
                    perp = np.linalg.norm(q - np.outer(t, d), axis=1)
                    zb = (np.abs(t) < ln * 0.5) & (perp < rad)
                    if not zb.any():
                        continue
                    tb = zb[g["idx"]].any(axis=1)
                    if keep_y is not None:
                        # v48: a floor triangle on the room side stays, right up to the hole (it used
                        # to be cut with the wall face, leaving a 2-4 m pit in front of every mouth)
                        # (a floor triangle is 2.5 m wide and climbs into the wall fillet, so test its
                        # lowest corner against the floor band and its centre against the axis)
                        if cen is None:
                            cen = pos[g["idx"]].mean(axis=1)
                            low = pos[g["idx"]][:, :, 1].min(axis=1)
                        tb &= ~((room * ((cen - A) @ d) > 0.0) & (low < keep_y) & (cen[:, 1] < A[1] - 0.5))
                    cut |= tb
                if cut.any():
                    g["idx"] = g["idx"][~cut]
                    if len(g["idx"]) == 0:
                        continue
                _collect_mouth_tris(zones, g, mouth_tris)
            prims.append(g)
            tri_total += len(g["idx"]); vert_total += len(g["pos"])
        if prims:
            nodes.append(("cave_%03d" % bi, prims))
    for i, (kind, m, mat) in enumerate(getattr(R, "tube_meshes", [])):
        m["mat"] = mat
        nodes.append(("%s_%03d" % (kind, i), [m]))
        tri_total += len(m["idx"])
        if zones:
            _collect_mouth_tris(zones, m, mouth_tris)
    check_mouth_floors(zones, mouth_tris, report, F)
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
    # v49 K12 (review): placed on the final triangles; adds no geometry, so it can follow the mesh
    M = MeshCols(nodes)
    place_k12(R, F, report, M)
    del M
    print("k12 placed (%.1fs)" % (time.time() - t0))

    validate(R, F, report, lo, hi)
    L = R.L
    L.pop("slabs_meta", None)
    counts = {k: len(v) for k, v in L.items() if isinstance(v, list)}
    counts["waking_husk"] = 1 if L.get("waking_husk") else 0
    report["counts"] = counts
    min_y = min(z["floor"] for z in L["zones"])
    report["deepest_floor"] = min_y
    report["max_horizontal"] = round(max(math.hypot(z["center"][0], z["center"][2]) for z in L["zones"]), 1)
    # v49 (#119): the old figure summed the distance between biome zone centres in list order. This is
    # the main route itself: the straight lines between its stand points in order (a lower bound:
    # tunnels and caves count as a straight line). Short Way ledges are left out; they are their own.
    path_len = 0.0
    main_st = [s_["pos"] for s_ in L.get("stations", []) if s_["kind"] != "hard"]
    for a_, b_ in zip(main_st, main_st[1:]):
        d_ = math.dist(a_, b_)
        if d_ < 500.0:
            path_len += d_
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
