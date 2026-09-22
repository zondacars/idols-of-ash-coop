"""Shapes for THE GREAT RIFT: the abyss itself, and the rock put back into it
(balconies that follow the wall, flat-decked spans, the Lid)."""
import math
import numpy as np

from sdf import Prim, noise_fields


class Rift(Prim):
    """One colossal vertical abyss. Its centre meanders with depth, its radius follows
    control points, and broad noise gives the wall bays and buttresses tens of metres deep."""
    kind = "rift"

    def __init__(self, base, y_top, y_bot, radius_pts, strata, amp=(14.0, 5.0, 1.2)):
        self.base = np.array(base, dtype=np.float64)      # x, z of the axis
        self.y_top = y_top
        self.y_bot = y_bot
        pts = sorted(radius_pts)                           # (y, R), ascending y
        self.ry = np.array([p[0] for p in pts], dtype=np.float64)
        self.rr = np.array([p[1] for p in pts], dtype=np.float64)
        self.strata = strata                               # [(y_top, y_bot, biome)]
        self.amp = amp
        self.biome = strata[0][2]

    def center(self, y):
        y = np.asarray(y, dtype=np.float64)
        cx = self.base[0] + 42.0 * np.sin(y / 470.0 + 1.3) + 16.0 * np.sin(y / 190.0 + 0.4)
        cz = self.base[1] + 42.0 * np.cos(y / 420.0) + 16.0 * np.sin(y / 230.0 + 2.0)
        return cx, cz

    def radius(self, y):
        return np.interp(y, self.ry, self.rr)

    def biome_at(self, y):
        y = np.asarray(y, dtype=np.float64)
        out = np.full(y.shape, self.strata[-1][2], dtype=np.int32)
        for (t, b, bi) in self.strata:
            out[(y <= t) & (y > b)] = bi
        return out

    def aabb(self):
        m = float(self.rr.max()) + 83.0 + 60.0
        lo = np.array([self.base[0] - m, self.y_bot - 6, self.base[1] - m])
        hi = np.array([self.base[0] + m, self.y_top + 6, self.base[1] + m])
        return lo, hi

    def e(self, P, n0, n1, n2):
        cx, cz = self.center(P[:, 1])
        d = np.sqrt((P[:, 0] - cx) ** 2 + (P[:, 2] - cz) ** 2)
        a0, a1, a2 = self.amp
        return d - self.radius(P[:, 1]) - (a0 * n0 + a1 * n1 + a2 * n2), d, cx, cz

    def sdf(self, P, n0, n1, n2):
        e = self.e(P, n0, n1, n2)[0]
        return np.maximum(e, np.maximum(P[:, 1] - self.y_top, self.y_bot - P[:, 1]))

    def wall_r(self, ang, y):
        """Distance from the axis to the first rock met on a bearing. The wall noise can put an
        outcrop in front of the main face, so march outward and refine the FIRST crossing."""
        cx, cz = self.center(y)
        dx, dz = math.cos(ang), math.sin(ang)
        rs = np.arange(5.0, float(self.radius(y)) + 75.0, 2.0)
        P = np.stack([cx + dx * rs, np.full(len(rs), float(y)), cz + dz * rs], axis=1)
        n0, n1, n2 = noise_fields(P)
        e = self.e(P, n0, n1, n2)[0]
        hit = np.nonzero(e >= 0.0)[0]
        if len(hit) == 0:
            return float(rs[-1])
        k = int(hit[0])
        lo_r, hi_r = float(rs[max(k - 1, 0)]), float(rs[k])
        for _ in range(12):
            mid = 0.5 * (lo_r + hi_r)
            p = np.array([[cx + dx * mid, y, cz + dz * mid]])
            m0, m1, m2 = noise_fields(p)
            if self.e(p, m0, m1, m2)[0][0] < 0.0:
                lo_r = mid
            else:
                hi_r = mid
        return 0.5 * (lo_r + hi_r)

    def point(self, ang, y, inset):
        """A point `inset` metres inside the wall on bearing `ang` at height `y`."""
        cx, cz = self.center(y)
        r = self.wall_r(ang, y) - inset
        return np.array([float(cx) + math.cos(ang) * r, y, float(cz) + math.sin(ang) * r])

    def bearing(self, p):
        cx, cz = self.center(p[1])
        return math.atan2(p[2] - float(cz), p[0] - float(cx))


def _rift_e(P, n0, n1, n2, ctx):
    if "e" not in ctx:
        ctx["e"] = ctx["rift"].e(P, n0, n1, n2)
    return ctx["e"]


class ShelfSolid:
    """A rock balcony that follows the real wall: flat top, tapered underside."""
    kind = "shelf"

    def __init__(self, rift, y_top, a_mid, half_arc, protrude, thick=4.5):
        self.rift = rift
        self.y_top = y_top
        self.a_mid = a_mid
        self.half_arc = half_arc
        self.p = protrude
        self.thick = thick
        # the real wall face along this balcony, so its width is true metres everywhere
        # (the field value near the wall is not a distance where the noise is steep)
        span = half_arc + 0.06
        n = max(12, int(2 * span * float(rift.radius(y_top)) / 0.7))
        self.tab_a = np.linspace(-span, span, n)
        self.tab_r = np.array([rift.wall_r(a_mid + da, y_top - 0.5) for da in self.tab_a])

    def aabb(self):
        cx, cz = self.rift.center(self.y_top)
        m = float(self.rift.radius(self.y_top)) + 40.0
        lo = np.array([float(cx) - m, self.y_top - self.thick - 3, float(cz) - m])
        hi = np.array([float(cx) + m, self.y_top + 1, float(cz) + m])
        return lo, hi

    def sdf(self, P, n0, n1, n2, ctx):
        e, d, cx, cz = _rift_e(P, n0, n1, n2, ctx)
        ang = np.arctan2(P[:, 2] - cz, P[:, 0] - cx)
        dang = (ang - self.a_mid + math.pi) % (2 * math.pi) - math.pi
        w = np.interp(dang, self.tab_a, self.tab_r) - d    # true metres out from the wall face
        w = np.where(e > 0.0, np.minimum(w, -e), w)        # inside rock stays rock
        s_ang = (np.abs(dang) - self.half_arc) * np.maximum(d, 1.0)
        taper = self.thick * (0.45 + 0.55 * np.clip(1.0 - w / self.p, 0.0, 1.0))
        s_y = np.maximum(P[:, 1] - self.y_top, (self.y_top - taper) - P[:, 1])
        return np.maximum(np.maximum(w - self.p, s_y), s_ang)


class BeamSolid:
    """A straight span with a flat deck: rock bridges, giant roots, causeways."""
    kind = "beam"

    def __init__(self, a, b, half_w, thick, rough=0.25):
        self.a = np.array(a, dtype=np.float64)          # deck centre line
        self.b = np.array(b, dtype=np.float64)
        self.hw = half_w
        self.thick = thick
        self.rough = rough
        t = self.b - self.a
        self.L = float(np.linalg.norm(t))
        self.t = t / self.L
        u = np.cross(np.array([0.0, 1.0, 0.0]), self.t)
        self.u = u / np.linalg.norm(u)
        self.v = np.cross(self.t, self.u)

    def aabb(self):
        m = max(self.hw, self.thick) * 1.6 + 4
        return np.minimum(self.a, self.b) - m, np.maximum(self.a, self.b) + m

    def sdf(self, P, n0, n1, n2, ctx):
        q = P - self.a
        tt = q @ self.t
        uu = q @ self.u
        vv = q @ self.v
        bulge = 1.0 + self.rough * n1
        s = np.maximum(np.abs(uu) - self.hw * bulge, vv)
        s = np.maximum(s, -(vv + self.thick * bulge))
        return np.maximum(s, np.maximum(-tt, tt - self.L))

    def at(self, f):
        return self.a + (self.b - self.a) * f


class PlugSolid:
    """A slab of fallen rock that seals the rift from wall to wall."""
    kind = "plug"

    def __init__(self, rift, y_top, y_bot):
        self.rift = rift
        self.y_top = y_top
        self.y_bot = y_bot

    def aabb(self):
        lo, hi = self.rift.aabb()
        return np.array([lo[0], self.y_bot - 6, lo[2]]), np.array([hi[0], self.y_top + 6, hi[2]])

    def sdf(self, P, n0, n1, n2, ctx):
        e, d, cx, cz = _rift_e(P, n0, n1, n2, ctx)
        ymid = 0.5 * (self.y_top + self.y_bot)
        half = 0.5 * (self.y_top - self.y_bot)
        s_y = np.abs(P[:, 1] - ymid) - half - 2.5 * n1
        return np.maximum(s_y, e - 30.0)


class RodSolid:
    """A round bar between two points, any direction: ribs, tusks, struts."""
    kind = "rod"

    def __init__(self, a, b, r0, r1=None, rough=0.18, look=None):
        self.a = np.array(a, dtype=np.float64)
        self.b = np.array(b, dtype=np.float64)
        self.r0 = r0
        self.r1 = r0 if r1 is None else r1
        self.rough = rough
        self.look = look

    def aabb(self):
        m = max(self.r0, self.r1) * 1.5 + 3
        return np.minimum(self.a, self.b) - m, np.maximum(self.a, self.b) + m

    def sdf(self, P, n0, n1, n2, ctx):
        pa = P - self.a
        ba = self.b - self.a
        h = np.clip((pa @ ba) / float(ba @ ba), 0.0, 1.0)
        d = np.linalg.norm(pa - h[:, None] * ba[None, :], axis=1)
        r = self.r0 + (self.r1 - self.r0) * h
        return d - r * (1.0 + self.rough * n1)


class ConeSolid:
    """A vertical spike of rock. height < 0 hangs down from the base (stalactite),
    height > 0 stands up from it (needle)."""
    kind = "cone"

    def __init__(self, base, height, r0, rough=0.3, look=None, lean=(0.0, 0.0)):
        self.base = np.array(base, dtype=np.float64)
        self.h = float(height)
        self.r0 = r0
        self.rough = rough
        self.look = look
        self.lean = lean

    def aabb(self):
        m = self.r0 * 1.6 + 4 + abs(self.h) * max(abs(self.lean[0]), abs(self.lean[1]))
        y0, y1 = sorted((self.base[1] - math.copysign(6.0, self.h), self.base[1] + self.h))
        return (np.array([self.base[0] - m, y0 - 2, self.base[2] - m]),
                np.array([self.base[0] + m, y1 + 2, self.base[2] + m]))

    def tip(self):
        return self.base + np.array([self.lean[0] * abs(self.h), self.h, self.lean[1] * abs(self.h)])

    def sdf(self, P, n0, n1, n2, ctx):
        t = (P[:, 1] - self.base[1]) / self.h
        tc = np.clip(t, 0.0, 1.0)
        cx = self.base[0] + self.lean[0] * abs(self.h) * tc
        cz = self.base[2] + self.lean[1] * abs(self.h) * tc
        d = np.sqrt((P[:, 0] - cx) ** 2 + (P[:, 2] - cz) ** 2)
        r = self.r0 * (1.0 - tc) ** 0.72 * (1.0 + self.rough * n1) + 0.4 * self.rough * n0
        s = d - r
        ah = abs(self.h)
        return np.maximum(s, np.maximum((t - 1.0) * ah, (-t) * ah - 6.0))


class TerraceSolid:
    """A shelf of rock the size of a field, fallen across most of the rift: everything on the
    a_mid side of a chord, flat on top. It closes the straight line down, so nobody can fall
    the whole rift in one go, and it turns a descent into a long walk to its open edge."""
    kind = "terrace"

    def __init__(self, rift, y_top, a_mid, k=0.2, thick=13.0):
        self.rift = rift
        self.y_top = y_top
        self.a_mid = a_mid
        self.k = k                       # the chord sits k*R past the axis, on the far side
        self.thick = thick
        self.R = float(rift.radius(y_top))
        self.ca, self.sa = math.cos(a_mid), math.sin(a_mid)

    def aabb(self):
        lo, hi = self.rift.aabb()
        return (np.array([lo[0], self.y_top - self.thick * 1.4 - 5, lo[2]]),
                np.array([hi[0], self.y_top + 2, hi[2]]))

    def side(self, p):
        """> 0 on the covered side, in metres from the chord."""
        cx, cz = self.rift.center(p[1])
        return (p[0] - float(cx)) * self.ca + (p[2] - float(cz)) * self.sa + self.k * self.R

    def covers(self, p, margin=0.0):
        return (self.y_top - self.thick * 1.4 - margin) < p[1] < (self.y_top + margin) and self.side(p) > -margin

    def sdf(self, P, n0, n1, n2, ctx):
        e, d, cx, cz = _rift_e(P, n0, n1, n2, ctx)
        sgn = (P[:, 0] - cx) * self.ca + (P[:, 2] - cz) * self.sa + self.k * self.R
        edge = -sgn - 4.0 * n0                                   # ragged open edge
        s_y = np.maximum(P[:, 1] - self.y_top, (self.y_top - self.thick * (1.0 + 0.25 * n1)) - P[:, 1])
        return np.maximum(np.maximum(s_y, edge), e - 30.0)
