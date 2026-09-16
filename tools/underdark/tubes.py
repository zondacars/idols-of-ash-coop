"""THE BURROWS: hand-meshed tight tunnels (the cave mesher's 2.5 m voxels cannot resolve
tubes this thin). A tube is a smooth Catmull-Rom path with rings of vertices; the mouths
punch through the coarse chamber walls and get a rock collar so there is never a gap."""
import math
import numpy as np

from sdf import Perlin3, SEED

_JIT = Perlin3(SEED + 21)


def catmull_rom(way, radii, step):
    way = np.asarray(way, dtype=np.float64)
    radii = np.asarray(radii, dtype=np.float64)
    P = np.vstack([way[0], way, way[-1]])
    Rr = np.concatenate([[radii[0]], radii, [radii[-1]]])
    pts, rs = [], []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        seg_len = np.linalg.norm(p2 - p1)
        n = max(2, int(math.ceil(seg_len / step)))
        for k in range(n):
            t = k / n
            t2, t3 = t * t, t * t * t
            q = 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
            pts.append(q)
            rs.append(Rr[i] + (Rr[i + 1] - Rr[i]) * t)
    pts.append(P[-2]); rs.append(Rr[-2])
    return np.array(pts), np.array(rs)


def frames(pts):
    n = len(pts)
    T = np.zeros((n, 3))
    T[:-1] = pts[1:] - pts[:-1]
    T[-1] = T[-2]
    T /= np.maximum(np.linalg.norm(T, axis=1, keepdims=True), 1e-9)
    N = np.zeros((n, 3))
    up = np.array([0, 1.0, 0])
    n0 = np.cross(T[0], up)
    if np.linalg.norm(n0) < 0.1:
        n0 = np.cross(T[0], np.array([1.0, 0, 0]))
    N[0] = n0 / np.linalg.norm(n0)
    for i in range(1, n):
        v = N[i - 1] - T[i] * (N[i - 1] @ T[i])
        if np.linalg.norm(v) < 1e-6:
            v = np.cross(T[i], up)
        N[i] = v / np.linalg.norm(v)
    B = np.cross(T, N)
    return T, N, B


def tube_mesh(way, radii, sides=16, step=0.7, cap_end=False, cap_start=False, jitter=0.06):
    pts, rs = catmull_rom(way, radii, step)
    T, N, B = frames(pts)
    ang = np.linspace(0, 2 * math.pi, sides, endpoint=False)
    rings = []
    for i in range(len(pts)):
        c = pts[i]
        ring = []
        for a in ang:
            dirv = N[i] * math.cos(a) + B[i] * math.sin(a)
            j = _JIT(np.array([c[0] + dirv[0] * 2.0]) / 2.2, np.array([c[1] + dirv[1] * 2.0]) / 2.2, np.array([c[2] + dirv[2] * 2.0]) / 2.2)[0]
            r = rs[i] * (1.0 + jitter * j)
            v = c + dirv * r
            if abs(T[i][1]) < 0.6:
                fl = c[1] - 0.55 * rs[i]
                if v[1] < fl:
                    v = v.copy(); v[1] = fl
            ring.append(v)
        rings.append(np.array(ring))
    pos, nrm, faces = [], [], []
    for i, ring in enumerate(rings):
        for v in ring:
            pos.append(v)
            d = pts[i] - v
            nrm.append(d / max(np.linalg.norm(d), 1e-6))
    for i in range(len(rings) - 1):
        for k in range(sides):
            a = i * sides + k
            b = i * sides + (k + 1) % sides
            c = (i + 1) * sides + k
            d = (i + 1) * sides + (k + 1) % sides
            faces.append([a, c, b]); faces.append([b, c, d])
    for cap, i in ((cap_start, 0), (cap_end, len(rings) - 1)):
        if not cap:
            continue
        ci = len(pos)
        pos.append(pts[i] + (T[i] if i == 0 else -T[i]) * 0.3 * rs[i])
        nrm.append(T[i] if i == 0 else -T[i])
        for k in range(sides):
            a = i * sides + k
            b = i * sides + (k + 1) % sides
            faces.append([ci, a, b])
    pos = np.array(pos, dtype=np.float32)
    nrm = np.array(nrm, dtype=np.float32)
    idx = np.array(faces, dtype=np.uint32)
    ao = np.full(len(pos), 0.55, dtype=np.float32)
    return dict(pos=pos, nrm=nrm, ao=ao, idx=idx), pts, rs, T


def collar_mesh(center, axis, r_in, r_out, length, sides=20):
    axis = np.asarray(axis, dtype=np.float64); axis /= np.linalg.norm(axis)
    up = np.array([0, 1.0, 0])
    n = np.cross(axis, up)
    if np.linalg.norm(n) < 0.1:
        n = np.cross(axis, np.array([1.0, 0, 0]))
    n /= np.linalg.norm(n)
    b = np.cross(axis, n)
    c = np.asarray(center, dtype=np.float64)
    ang = np.linspace(0, 2 * math.pi, sides, endpoint=False)
    tris = []
    for z0, z1 in ((-length / 2, length / 2),):
        for k in range(sides):
            a0, a1 = ang[k], ang[(k + 1) % sides]
            d0 = n * math.cos(a0) + b * math.sin(a0)
            d1 = n * math.cos(a1) + b * math.sin(a1)
            j0 = 1.0 + 0.12 * _JIT(np.array([a0 * 3]), np.array([c[1]]), np.array([0.0]))[0]
            j1 = 1.0 + 0.12 * _JIT(np.array([a1 * 3]), np.array([c[1]]), np.array([0.0]))[0]
            for zz in (z0, z1):
                p = c + axis * zz
                # annulus cap
                tris.append([p + d0 * r_in, p + d0 * r_out * j0, p + d1 * r_out * j1])
                tris.append([p + d0 * r_in, p + d1 * r_out * j1, p + d1 * r_in])
            # outer wall
            tris.append([c + axis * z0 + d0 * r_out * j0, c + axis * z1 + d0 * r_out * j0, c + axis * z1 + d1 * r_out * j1])
            tris.append([c + axis * z0 + d0 * r_out * j0, c + axis * z1 + d1 * r_out * j1, c + axis * z0 + d1 * r_out * j1])
    tris = np.array(tris)
    e1 = tris[:, 1] - tris[:, 0]; e2 = tris[:, 2] - tris[:, 0]
    nr = np.cross(e1, e2); nr /= np.maximum(np.linalg.norm(nr, axis=1, keepdims=True), 1e-9)
    cen = tris.mean(axis=1)
    out = cen - c
    flip = (nr * out).sum(axis=1) < 0
    nr[flip] *= -1
    pos = tris.reshape(-1, 3).astype(np.float32)
    nrm = np.repeat(nr, 3, axis=0).astype(np.float32)
    idx = np.arange(len(pos), dtype=np.uint32).reshape(-1, 3)
    ao = np.full(len(pos), 0.6, dtype=np.float32)
    return dict(pos=pos, nrm=nrm, ao=ao, idx=idx)


def plan_waypoints(start, yaw, segs, r_start):
    """segs: (length, turn_deg, drop) with length 0 meaning a vertical hole of `drop` m."""
    pts = [np.array(start, dtype=np.float64)]
    rs = [r_start]
    p = pts[0].copy()
    for (length, turn, drop, r) in segs:
        yaw += math.radians(turn)
        d = np.array([math.cos(yaw), 0.0, math.sin(yaw)])
        if length == 0:
            p = p + np.array([0, -drop, 0])
        else:
            p = p + d * length + np.array([0, -drop, 0])
        pts.append(p.copy())
        rs.append(r)
    return np.array(pts), np.array(rs), yaw


def along(pts, s):
    """point, tangent and index at arc length s"""
    acc = 0.0
    for i in range(len(pts) - 1):
        seg = pts[i + 1] - pts[i]
        ln = np.linalg.norm(seg)
        if acc + ln >= s:
            t = (s - acc) / max(ln, 1e-6)
            return pts[i] + seg * t, seg / max(ln, 1e-6), i
        acc += ln
    return pts[-1], (pts[-1] - pts[-2]) / max(np.linalg.norm(pts[-1] - pts[-2]), 1e-6), len(pts) - 2


def path_length(pts):
    return float(np.sum(np.linalg.norm(pts[1:] - pts[:-1], axis=1)))
