"""The OpenCourt logo as vectors: a heavy C with a pickleball tucked into its mouth.

Geometry is measured from the supplied 2380 px artwork (OpenCourt Logo.png) and expressed in
"logo units": the C's outer circle has radius 1, centred at the origin.
"""
from __future__ import annotations

import math
from functools import lru_cache

import skia

# brand colours, sampled from the artwork
INK = 0xFF0A372C       # deep court green
BALL = 0xFFCFEE34      # pickleball lime
PAPER = 0xFFFFFFFF

# -- measured geometry (source pixels) ---------------------------------------------------------
_SRC_R = 812.5
_O = (1209.0, 1189.5)          # outer circle centre
_I = (1198.0, 1189.5)          # inner circle centre
_RI = 451.3
_BALL_C = (1738.5, 1189.5)
_BALL_R = 304.0
_GAP_R = 350.0
_CAP_R = 148.5
_CAP_C = (1697.5, 740.0)       # top terminal's round cap (bottom one mirrors it)
_HOLES = [  # dx, dy from ball centre, semi-major, semi-minor, angle (deg)
    (-12.2, -256.7, 40.8, 15.5, -1.8), (122.9, -170.6, 40.6, 26.3, 37.0),
    (-161.5, -170.3, 41.2, 22.2, -41.2), (-25.3, -55.1, 40.7, 39.8, -26.5),
    (239.0, -31.5, 42.3, 21.1, -96.9), (-251.0, -28.1, 41.9, 19.2, -82.0),
    (101.2, 102.1, 41.7, 35.9, -47.2), (-143.8, 121.0, 41.1, 32.9, -129.9),
    (189.7, 174.4, 42.4, 16.3, -48.4), (-8.9, 245.8, 42.4, 21.6, 1.3),
]


def _u(x, y):
    """Source pixels -> logo units."""
    return (x - _O[0]) / _SRC_R, (y - _O[1]) / _SRC_R


def _circle(cx, cy, r):
    p = skia.Path()
    p.addCircle(cx, cy, r)
    return p


def _op(a, b, op):
    out = skia.Op(a, b, op)
    return out if out is not None else a


@lru_cache(maxsize=1)
def c_path() -> skia.Path:
    """The C, in logo units."""
    ox, oy = 0.0, 0.0
    ix, iy = _u(*_I)
    ri = _RI / _SRC_R
    capx, capy = _u(*_CAP_C)
    capr = _CAP_R / _SRC_R
    phi = math.degrees(math.atan2(capy, capx))            # top cap direction (negative)
    # annulus sector through the left side, from the top cap round to the bottom cap
    sector = skia.Path()
    big = 3.0
    sector.moveTo(0, 0)
    sector.arcTo(skia.Rect.MakeXYWH(-big, -big, 2 * big, 2 * big), phi, -(360 + 2 * phi), False)
    sector.close()
    ring = _op(_circle(ox, oy, 1.0), _circle(ix, iy, ri), skia.PathOp.kDifference_PathOp)
    shape = _op(ring, sector, skia.PathOp.kIntersect_PathOp)
    # fill the thin wedge between the inner edge and each cap (hidden by the gap circle)
    wedge = skia.Path()
    wedge.moveTo(0, 0)
    wedge.arcTo(skia.Rect.MakeXYWH(-big, -big, 2 * big, 2 * big), phi, 13, False)
    wedge.close()
    inner_band = _op(_circle(ox, oy, 1.0 - capr), _circle(ix, iy, ri),
                     skia.PathOp.kDifference_PathOp)
    for sgn in (1, -1):
        w = skia.Path(wedge)
        if sgn < 0:
            w.transform(skia.Matrix.Scale(1, -1))
        shape = _op(shape, _op(inner_band, w, skia.PathOp.kIntersect_PathOp),
                    skia.PathOp.kUnion_PathOp)
        shape = _op(shape, _circle(capx, capy * sgn, capr), skia.PathOp.kUnion_PathOp)
    bx, by = _u(*_BALL_C)
    shape = _op(shape, _circle(bx, by, _GAP_R / _SRC_R), skia.PathOp.kDifference_PathOp)
    return shape


def ball_geom():
    bx, by = _u(*_BALL_C)
    return bx, by, _BALL_R / _SRC_R


# Bounds of the whole mark (C + ball), in logo units
def mark_bounds():
    b = c_path().computeTightBounds()
    bx, by, br = ball_geom()
    return skia.Rect.MakeLTRB(b.left(), min(b.top(), by - br), max(b.right(), bx + br),
                              max(b.bottom(), by + br))


def draw_ball(c, cx, cy, r, color=BALL, hole=INK, spin=0.0, alpha=1.0, squash=1.0):
    """The pickleball centred at (cx, cy) with radius r. `spin` rotates the holes (radians)."""
    if alpha <= 0.002:
        return
    p = skia.Paint(AntiAlias=True, Color=color)
    p.setAlphaf(alpha)
    c.drawCircle(cx, cy, r, p)
    hp = skia.Paint(AntiAlias=True, Color=hole)
    hp.setAlphaf(alpha)
    s = r / _BALL_R
    c.save()
    c.clipPath(_circle(cx, cy, r), skia.ClipOp.kIntersect, True)
    cs, sn = math.cos(spin), math.sin(spin)
    for dx, dy, a, b, ang in _HOLES:
        x = (dx * cs - dy * sn) * s
        y = (dx * sn + dy * cs) * s
        c.save()
        c.translate(cx + x, cy + y)
        c.rotate(ang + math.degrees(spin))
        c.drawOval(skia.Rect.MakeXYWH(-a * s, -b * s, 2 * a * s, 2 * b * s), hp)
        c.restore()
    c.restore()


def draw_mark(c, x, y, scale, c_color=INK, ball_color=BALL, hole_color=INK, alpha=1.0,
              spin=0.0, ball_offset=(0.0, 0.0), ball_scale=1.0, c_alpha=None):
    """Draw the mark with the C's centre at (x, y); `scale` = C outer radius in pixels."""
    c.save()
    c.translate(x, y)
    c.scale(scale, scale)
    p = skia.Paint(AntiAlias=True, Color=c_color)
    p.setAlphaf(alpha if c_alpha is None else c_alpha)
    c.drawPath(c_path(), p)
    c.restore()
    bx, by, br = ball_geom()
    draw_ball(c, x + (bx + ball_offset[0]) * scale, y + (by + ball_offset[1]) * scale,
              br * scale * ball_scale, ball_color, hole_color, spin, alpha)


# -- wordmark ----------------------------------------------------------------------------------
_ROUNDED = skia.Typeface.MakeFromFile('/System/Library/Fonts/SFNSRounded.ttf')


def _tag(s):
    return (ord(s[0]) << 24) | (ord(s[1]) << 16) | (ord(s[2]) << 8) | ord(s[3])


@lru_cache(maxsize=None)
def _rounded(weight):
    # CoreText applies the weight axis when asked by family + style (makeClone does not)
    return skia.FontMgr().matchFamilyStyle(
        '.SF NS Rounded', skia.FontStyle(int(weight), 5, skia.FontStyle.kUpright_Slant))


WORD_WEIGHT = 800


def word_font(size):
    f = skia.Font(_rounded(WORD_WEIGHT), size)
    f.setEdging(skia.Font.Edging.kAntiAlias)
    f.setSubpixel(True)
    f.setHinting(skia.FontHinting.kNone)
    return f


def text_path(s, size, x=0.0, y=0.0, tracking=-0.015):
    f = word_font(size)
    glyphs = f.textToGlyphs(s)
    widths = f.getWidths(glyphs)
    out = skia.Path()
    xx = x
    for g, w in zip(glyphs, widths):
        gp = f.getPath(g)
        if gp is not None:
            gp.offset(xx, y)
            out.addPath(gp)
        xx += w + tracking * size
    return out, xx - x - tracking * size


class Wordmark:
    """Layout of 'Open' + mark + 'ourt' for a given cap height (px)."""

    def __init__(self, cap_height):
        f = word_font(100)
        m = f.getMetrics()
        cap = m.fCapHeight
        self.size = 100 * cap_height / cap
        self.cap = cap_height
        # the C is a capital: its outer height overshoots the cap height a little, like an O
        self.scale = cap_height * 1.07 / 2.0
        self.open_path, self.open_w = text_path('Open', self.size)
        self.ourt_path, self.ourt_w = text_path('ourt', self.size)
        b = mark_bounds()
        self.mark_left = b.left() * self.scale
        self.mark_right = b.right() * self.scale
        self.gap_l = 0.075 * cap_height
        self.gap_r = 0.06 * cap_height
        self.width = (self.open_w + self.gap_l + (self.mark_right - self.mark_left) + self.gap_r
                      + self.ourt_w)

    def positions(self, x, baseline):
        """x of 'Open', centre of the C, x of 'ourt' when the whole word starts at x."""
        mark_cx = x + self.open_w + self.gap_l - self.mark_left
        mark_cy = baseline - self.cap / 2
        ourt_x = mark_cx + self.mark_right + self.gap_r
        return x, (mark_cx, mark_cy), ourt_x


def draw_wordmark(c, cx, baseline, cap_height, ink=INK, ball=BALL, hole=INK, alpha=1.0):
    wm = Wordmark(cap_height)
    ox, (mx, my), ux = wm.positions(cx - wm.width / 2, baseline)
    p = skia.Paint(AntiAlias=True, Color=ink)
    p.setAlphaf(alpha)
    c.save(); c.translate(ox, baseline); c.drawPath(wm.open_path, p); c.restore()
    c.save(); c.translate(ux, baseline); c.drawPath(wm.ourt_path, p); c.restore()
    draw_mark(c, mx, my, wm.scale, ink, ball, hole, alpha)
    return wm
