"""Static brand files: the mark and the wordmark as PNG and SVG, plus app icons."""
from __future__ import annotations

import os
import sys

import skia

from brand import BALL, INK, Wordmark, draw_mark, draw_wordmark, mark_bounds

WHITE = 0xFFFFFFFF


def _svg(path, w, h, draw):
    stream = skia.FILEWStream(path)
    c = skia.SVGCanvas.Make(skia.Rect.MakeWH(w, h), stream)
    draw(c)
    del c
    stream.flush()


def _png(path, w, h, draw, bg=0x00000000):
    s = skia.Surface(w, h)
    c = s.getCanvas()
    c.clear(bg)
    draw(c)
    s.makeImageSnapshot().save(path, skia.kPNG)


def mark_drawer(w, h, ink, pad=0.06):
    b = mark_bounds()
    scale = min(w * (1 - 2 * pad) / b.width(), h * (1 - 2 * pad) / b.height())
    cx = w / 2 - (b.left() + b.right()) / 2 * scale
    cy = h / 2 - (b.top() + b.bottom()) / 2 * scale
    return lambda c: draw_mark(c, cx, cy, scale, ink, BALL, INK)


def word_drawer(w, h, ink):
    cap = h * 0.52
    wm = Wordmark(cap)
    scale = min(1.0, w * 0.94 / wm.width)
    cap *= scale
    return lambda c: draw_wordmark(c, w / 2, h / 2 + cap / 2, cap, ink, BALL, INK)


def word_size(cap):
    wm = Wordmark(cap)
    return int(wm.width + cap * 0.3), int(cap * 1.75)


def build(out):
    os.makedirs(out, exist_ok=True)
    for name, ink in (('green', INK), ('white', WHITE)):
        _png(f'{out}/OpenCourt-mark-{name}.png', 2048, 2048, mark_drawer(2048, 2048, ink))
        _svg(f'{out}/OpenCourt-mark-{name}.svg', 512, 512, mark_drawer(512, 512, ink))
        w, h = word_size(600)
        _png(f'{out}/OpenCourt-wordmark-{name}.png', w, h, word_drawer(w, h, ink))
        w2, h2 = word_size(100)
        _svg(f'{out}/OpenCourt-wordmark-{name}.svg', w2, h2, word_drawer(w2, h2, ink))
    # small web/email sizes
    w, h = word_size(52)
    _png(f'{out}/wordmark-white@2x.png', w * 2, h * 2, word_drawer(w * 2, h * 2, WHITE))
    _png(f'{out}/mark-180.png', 180, 180, mark_drawer(180, 180, INK, pad=0.1), bg=WHITE)


def app_icons(light_path, dark_path):
    # iOS masks the corners itself; keep the mark inside the safe area
    _png(light_path, 1024, 1024, mark_drawer(1024, 1024, INK, pad=0.17), bg=WHITE)
    _png(dark_path, 1024, 1024, mark_drawer(1024, 1024, WHITE, pad=0.17), bg=0xFF0A2A22)


if __name__ == '__main__':
    build(sys.argv[1])
    if len(sys.argv) > 3:
        app_icons(sys.argv[2], sys.argv[3])
