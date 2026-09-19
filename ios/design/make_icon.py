"""Draws the app icon (1024x1024): a court seen from above, in court green, with the amber
signal light glowing over it. Run with the sensor venv: sensor/.venv/bin/python ios/design/make_icon.py"""

from pathlib import Path

import cv2
import numpy as np

S = 1024
SS = 4  # supersample for smooth edges
N = S * SS

# Background: diagonal gradient, deep green to court green.
y, x = np.mgrid[0:N, 0:N].astype(np.float32) / N
t = np.clip(0.55 * x + 0.75 * y, 0, 1)[..., None]
top = np.array([0x6e, 0x8a, 0x1e], np.float32)     # BGR ~ #1E8A6E
bottom = np.array([0x3a, 0x4a, 0x0f], np.float32)  # BGR ~ #0F4A3A
img = (top * (1 - t) + bottom * t).astype(np.uint8)

def P(v):
    return int(v * SS)

# Court: blue playing surface with white lines, slightly inset.
court = np.array([[250, 330], [774, 330], [774, 890], [250, 890]], np.int32) * SS
cv2.fillPoly(img, [court], (0x8c, 0x55, 0x2e), lineType=cv2.LINE_AA)  # BGR ~ #2E558C
white = (245, 245, 245)
lw = P(18)
cv2.polylines(img, [court], True, white, lw, cv2.LINE_AA)
cv2.line(img, (P(250), P(610)), (P(774), P(610)), white, P(26), cv2.LINE_AA)       # net
cv2.line(img, (P(250), P(520)), (P(774), P(520)), white, P(12), cv2.LINE_AA)       # kitchen
cv2.line(img, (P(250), P(700)), (P(774), P(700)), white, P(12), cv2.LINE_AA)       # kitchen
cv2.line(img, (P(512), P(330)), (P(512), P(520)), white, P(12), cv2.LINE_AA)       # centre
cv2.line(img, (P(512), P(700)), (P(512), P(890)), white, P(12), cv2.LINE_AA)       # centre

# Amber light with a soft glow, top right.
glow = np.zeros((N, N), np.float32)
cv2.circle(glow, (P(760), P(215)), P(120), 1.0, -1, cv2.LINE_AA)
glow = cv2.GaussianBlur(glow, (0, 0), P(60))
amber = np.array([0x0a, 0x9e, 0xf5], np.float32)  # BGR ~ #F59E0A
img = (img * (1 - 0.85 * glow[..., None]) + amber * 0.85 * glow[..., None]).astype(np.uint8)
cv2.circle(img, (P(760), P(215)), P(78), (0x2c, 0xc2, 0xff), -1, cv2.LINE_AA)
cv2.circle(img, (P(738), P(193)), P(26), (0xd8, 0xf2, 0xff), -1, cv2.LINE_AA)

out = cv2.resize(img, (S, S), interpolation=cv2.INTER_AREA)
dest = Path(__file__).resolve().parents[1] / "OpenCourt/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
cv2.imwrite(str(dest), out)
print(dest)
