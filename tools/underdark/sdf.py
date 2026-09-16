"""Signed distance primitives and noise for THE UNDERDARK cave generator.

Field convention: f(p) < 0 is open air, f(p) > 0 is rock. Air primitives are
unioned with a smooth min; nothing is ever carved back into rock here (solid
features like shelves and pillars are exported as separate meshes).
"""
import math
import numpy as np

SEED = 131313


# ---------------------------------------------------------------- noise

class Perlin3:
    def __init__(self, seed):
        rng = np.random.default_rng(seed)
        p = rng.permutation(256).astype(np.int64)
        self.perm = np.concatenate([p, p])
        g = np.array([[1, 1, 0], [-1, 1, 0], [1, -1, 0], [-1, -1, 0],
                      [1, 0, 1], [-1, 0, 1], [1, 0, -1], [-1, 0, -1],
                      [0, 1, 1], [0, -1, 1], [0, 1, -1], [0, -1, -1]], dtype=np.float64)
        self.grad = g

    def __call__(self, x, y, z):
        perm = self.perm
        xf0 = np.floor(x); yf0 = np.floor(y); zf0 = np.floor(z)
        xi = xf0.astype(np.int64) & 255
        yi = yf0.astype(np.int64) & 255
        zi = zf0.astype(np.int64) & 255
        xf = x - xf0; yf = y - yf0; zf = z - zf0
        u = xf * xf * xf * (xf * (xf * 6 - 15) + 10)
        v = yf * yf * yf * (yf * (yf * 6 - 15) + 10)
        w = zf * zf * zf * (zf * (zf * 6 - 15) + 10)

        def corner(ox, oy, oz):
            h = perm[perm[perm[xi + ox] + yi + oy] + zi + oz] % 12
            g = self.grad[h]
            return g[..., 0] * (xf - ox) + g[..., 1] * (yf - oy) + g[..., 2] * (zf - oz)

        n000 = corner(0, 0, 0); n100 = corner(1, 0, 0)
        n010 = corner(0, 1, 0); n110 = corner(1, 1, 0)
        n001 = corner(0, 0, 1); n101 = corner(1, 0, 1)
        n011 = corner(0, 1, 1); n111 = corner(1, 1, 1)
        x00 = n000 + u * (n100 - n000)
        x10 = n010 + u * (n110 - n010)
        x01 = n001 + u * (n101 - n001)
        x11 = n011 + u * (n111 - n011)
        y0 = x00 + v * (x10 - x00)
        y1 = x01 + v * (x11 - x01)
        return y0 + w * (y1 - y0)


_P0 = Perlin3(SEED + 1)
_P1 = Perlin3(SEED + 2)
_P2 = Perlin3(SEED + 3)


def noise_fields(P):
    """Three noise bands for the points P (N,3): broad, mid, detail. Roughly in [-1, 1]."""
    x, y, z = P[:, 0], P[:, 1], P[:, 2]
    n0 = _P0(x / 55.0 + 11.3, y / 55.0 + 3.1, z / 55.0 + 7.7) * 1.6
    n1 = _P1(x / 17.0 + 5.2, y / 17.0 + 9.9, z / 17.0 + 1.4) * 1.6
    n2 = _P2(x / 5.5 + 2.8, y / 5.5 + 6.6, z / 5.5 + 4.1) * 1.6
    return n0, n1, n2


def smin(a, b, k):
    h = np.maximum(k - np.abs(a - b), 0.0) / k
    return np.minimum(a, b) - h * h * k * 0.25


# ---------------------------------------------------------------- primitives

class Prim:
    biome = 0
    kind = "prim"
    phantom = False   # bookkeeping only (overlap checks), never part of the field

    def aabb(self):
        raise NotImplementedError

    def sdf(self, P, n0, n1, n2):
        raise NotImplementedError


def _yaw_dirs(yaw):
    d = np.array([math.cos(yaw), 0.0, math.sin(yaw)])
    s = np.array([-math.sin(yaw), 0.0, math.cos(yaw)])
    return d, s


class Chamber(Prim):
    kind = "chamber"

    def __init__(self, biome, center, radii, yaw, floor_y, amp=(5.0, 2.6, 0.7), floor_amp=0.35, name=""):
        self.biome = biome
        self.c = np.array(center, dtype=np.float64)
        self.r = np.array(radii, dtype=np.float64)
        self.yaw = yaw
        self.floor_y = floor_y
        self.amp = amp
        self.floor_amp = floor_amp
        self.name = name
        self.d, self.s = _yaw_dirs(yaw)

    def aabb(self):
        m = max(self.r[0], self.r[2]) + sum(self.amp) + 4
        lo = np.array([self.c[0] - m, self.floor_y - 6, self.c[2] - m])
        hi = np.array([self.c[0] + m, self.c[1] + self.r[1] + sum(self.amp) + 4, self.c[2] + m])
        return lo, hi

    def local(self, P):
        q = P - self.c
        return np.stack([q @ self.d, q[:, 1], q @ self.s], axis=1)

    def sdf(self, P, n0, n1, n2):
        q = self.local(P)
        k0 = np.linalg.norm(q / self.r, axis=1)
        k1 = np.linalg.norm(q / (self.r * self.r), axis=1)
        e = k0 * (k0 - 1.0) / np.maximum(k1, 1e-9)
        a0, a1, a2 = self.amp
        e = e - (a0 * n0 + a1 * n1 + a2 * n2)
        fl = (self.floor_y + self.floor_amp * n1) - P[:, 1]
        return np.maximum(e, fl)

    def wall_extent(self, local_dir_angle, height_above_floor):
        """Nominal (noise-free) horizontal distance from center to wall."""
        yo = self.floor_y + height_above_floor - self.c[1]
        s = max(0.05, 1.0 - (yo / self.r[1]) ** 2)
        s = math.sqrt(s)
        ca, sa = math.cos(local_dir_angle), math.sin(local_dir_angle)
        return s / math.sqrt((ca / self.r[0]) ** 2 + (sa / self.r[2]) ** 2)

    def world_point(self, lx, lz, y):
        p = self.c + self.d * lx + self.s * lz
        return np.array([p[0], y, p[2]])


class Tunnel(Prim):
    """One straight capsule segment with a flat floor cut 0.55 r below the axis."""
    kind = "tunnel"

    def __init__(self, biome, a, b, radius, amp=(0.0, 1.3, 0.5), floor_amp=0.25):
        self.biome = biome
        self.a = np.array(a, dtype=np.float64)
        self.b = np.array(b, dtype=np.float64)
        self.r = radius
        self.amp = amp
        self.floor_amp = floor_amp

    def aabb(self):
        m = self.r + sum(self.amp) + 3
        lo = np.minimum(self.a, self.b) - m
        hi = np.maximum(self.a, self.b) + m
        return lo, hi

    def sdf(self, P, n0, n1, n2):
        ba = self.b - self.a
        t = np.clip(((P - self.a) @ ba) / (ba @ ba), 0.0, 1.0)
        axis = self.a + t[:, None] * ba
        d = np.linalg.norm(P - axis, axis=1) - self.r
        a0, a1, a2 = self.amp
        d = d - (a0 * n0 + a1 * n1 + a2 * n2)
        fl = (axis[:, 1] - 0.55 * self.r + self.floor_amp * n1) - P[:, 1]
        return np.maximum(d, fl)

    def floor_at_t(self, t):
        p = self.a + t * (self.b - self.a)
        return p[1] - 0.55 * self.r


class Shaft(Prim):
    """Vertical capsule, no floor."""
    kind = "shaft"

    def __init__(self, biome, x, z, y_top, y_bot, radius, amp=(0.0, 1.8, 0.6)):
        self.biome = biome
        self.a = np.array([x, y_top, z], dtype=np.float64)
        self.b = np.array([x, y_bot, z], dtype=np.float64)
        self.r = radius
        self.amp = amp

    def aabb(self):
        m = self.r + sum(self.amp) + 3
        lo = np.array([self.a[0] - m, self.b[1] - m, self.a[2] - m])
        hi = np.array([self.a[0] + m, self.a[1] + m, self.a[2] + m])
        return lo, hi

    def sdf(self, P, n0, n1, n2):
        y = np.clip(P[:, 1], self.b[1], self.a[1])
        dx = P[:, 0] - self.a[0]
        dz = P[:, 2] - self.a[2]
        dy = P[:, 1] - y
        d = np.sqrt(dx * dx + dy * dy + dz * dz) - self.r
        a0, a1, a2 = self.amp
        return d - (a0 * n0 + a1 * n1 + a2 * n2)


class Trench(Prim):
    """Oriented box of air cut down through a chamber floor (a chasm)."""
    kind = "trench"

    def __init__(self, biome, center, yaw, half_w, half_l, y_bot, y_top, amp=(0.0, 1.0, 0.4)):
        self.biome = biome
        self.c = np.array(center, dtype=np.float64)
        self.yaw = yaw
        self.hw = half_w
        self.hl = half_l
        self.y_bot = y_bot
        self.y_top = y_top
        self.amp = amp
        self.d, self.s = _yaw_dirs(yaw)

    def aabb(self):
        m = math.hypot(self.hw, self.hl) + sum(self.amp) + 3
        lo = np.array([self.c[0] - m, self.y_bot - 4, self.c[2] - m])
        hi = np.array([self.c[0] + m, self.y_top + 4, self.c[2] + m])
        return lo, hi

    def sdf(self, P, n0, n1, n2):
        q = P - self.c
        lx = np.abs(q @ self.d) - self.hw
        lz = np.abs(q @ self.s) - self.hl
        ymid = 0.5 * (self.y_top + self.y_bot)
        hy = 0.5 * (self.y_top - self.y_bot)
        ly = np.abs(P[:, 1] - ymid) - hy
        Q = np.stack([lx, ly, lz], axis=1)
        outside = np.linalg.norm(np.maximum(Q, 0.0), axis=1)
        inside = np.minimum(Q.max(axis=1), 0.0)
        d = outside + inside
        a0, a1, a2 = self.amp
        return d - (a0 * n0 + a1 * n1 + a2 * n2)


class Bowl(Prim):
    """Open-sky basin at the surface: air above a heightfield that rises into cliffs."""
    kind = "bowl"

    def __init__(self, biome, center, floor_y, radius, cliff_h=74.0, slope=2.4):
        self.biome = biome
        self.c = np.array(center, dtype=np.float64)
        self.floor_y = floor_y
        self.R = radius
        self.cliff_h = cliff_h
        self.slope = slope

    def aabb(self):
        m = self.R + self.cliff_h / self.slope + 10
        lo = np.array([self.c[0] - m, self.floor_y - 8, self.c[2] - m])
        hi = np.array([self.c[0] + m, self.floor_y + self.cliff_h + 20, self.c[2] + m])
        return lo, hi

    def sdf(self, P, n0, n1, n2):
        dx = P[:, 0] - self.c[0]
        dz = P[:, 2] - self.c[2]
        dist = np.sqrt(dx * dx + dz * dz)
        rise = np.clip((dist - self.R + 4.0 * n0) * self.slope, 0.0, self.cliff_h)
        ground = self.floor_y + rise + 0.6 * n1 + 2.5 * n2 * (rise > 1.0)
        return (ground - P[:, 1]) * 0.7


# ---------------------------------------------------------------- field

class Field:
    def __init__(self, prims, sky_y):
        self.prims = prims
        self.sky_y = sky_y
        self.boxes = [p.aabb() for p in prims]

    def prims_for_box(self, lo, hi):
        out = []
        for i, (a, b) in enumerate(self.boxes):
            if np.all(a <= hi) and np.all(b >= lo):
                out.append(i)
        return out

    def eval(self, P, idx=None, want_owner=False):
        if idx is None:
            lo = P.min(axis=0)
            hi = P.max(axis=0)
            idx = self.prims_for_box(lo, hi)
        f = np.full(len(P), 12.0)
        owner = np.full(len(P), -1, dtype=np.int32)
        best = np.full(len(P), 1e9)
        if idx:
            n0, n1, n2 = noise_fields(P)
            for i in idx:
                d = self.prims[i].sdf(P, n0, n1, n2)
                if want_owner:
                    m = d < best
                    best[m] = d[m]
                    owner[m] = i
                f = smin(f, d, 3.0)
        # everything above the sky line is open, which caps the rim plateau
        f = np.where(P[:, 1] > self.sky_y, np.minimum(f, -1.0), f)
        if want_owner:
            return f, owner
        return f

    def gradient(self, P, h=0.35):
        ex = np.array([h, 0, 0]); ey = np.array([0, h, 0]); ez = np.array([0, 0, h])
        allp = np.concatenate([P + ex, P - ex, P + ey, P - ey, P + ez, P - ez])
        v = self.eval(allp)
        n = len(P)
        g = np.stack([v[0:n] - v[n:2 * n], v[2 * n:3 * n] - v[3 * n:4 * n], v[4 * n:5 * n] - v[5 * n:6 * n]], axis=1)
        return g / (2 * h)

    def ray_to_air(self, origin, direction, max_dist=90.0, step=0.25):
        direction = np.asarray(direction, dtype=np.float64)
        direction = direction / np.linalg.norm(direction)
        ts = np.arange(0.0, max_dist, step)
        pts = np.asarray(origin, dtype=np.float64)[None, :] + ts[:, None] * direction[None, :]
        v = self.eval(pts)
        hit = np.nonzero(v < 0.0)[0]
        if len(hit) == 0:
            return None
        return float(ts[hit[0]])

    def ray_to_rock(self, origin, direction, max_dist=90.0, step=0.25):
        direction = np.asarray(direction, dtype=np.float64)
        direction = direction / np.linalg.norm(direction)
        ts = np.arange(0.0, max_dist, step)
        pts = np.asarray(origin, dtype=np.float64)[None, :] + ts[:, None] * direction[None, :]
        v = self.eval(pts)
        hit = np.nonzero(v > 0.0)[0]
        if len(hit) == 0:
            return None
        return float(ts[hit[0]])

    def floor_below(self, x, z, y_from, max_drop=80.0):
        d = self.ray_to_rock([x, y_from, z], [0, -1, 0], max_drop, 0.1)
        if d is None:
            return None
        return y_from - d
