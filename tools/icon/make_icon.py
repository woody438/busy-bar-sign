#!/usr/bin/env python3
"""
Draws the app icon: the bar's black glass face in its metal rim, as a macOS
squircle, showing the ON A CALL pill (the firmware's red, the mic pictogram)
on a grid of LEDs.

    python3 tools/icon/make_icon.py        # needs Pillow and NumPy

Writes Resources/Assets.xcassets/AppIcon.appiconset (every size macOS asks
for), docs/icon.png and the Stream Deck plugin's icon. Large sizes show the
LED dots; 64 px and below draw the LEDs edge to edge, which reads better
when each is a few pixels.
"""
import json
import os

import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ICONSET = os.path.join(ROOT, "Resources", "Assets.xcassets", "AppIcon.appiconset")

SS = 2                      # supersampling for the 1024 master
N = 1024 * SS

# macOS icon grid: an 824 pt squircle centred on a 1024 canvas
BODY_R = 412
RIM = 15                    # the metal rim's width
FACE_R = BODY_R - RIM

# LED grid, as on the bar: pill 16 rows tall, 3 unlit rows above and below
COLS, ROWS = 23, 22
PITCH = 32.5
GRID_X0 = 512 - COLS * PITCH / 2
GRID_Y0 = 512 - ROWS * PITCH / 2 + 6        # a touch low: the glass sheen weighs the top


def hexc(h):
    return np.array([(h >> 16) & 255, (h >> 8) & 255, h & 255], dtype=np.float64) / 255


# the firmware's ON A CALL palette (simulator/engine.js)
HIGHLIGHT, TOP, BOTTOM = hexc(0xFF808E), hexc(0xFF001D), hexc(0x6E0002)
RIM_BOTTOM, EDGE, SHADOW = hexc(0x7C191B), hexc(0xD14C58), hexc(0x4A0006)
WHITE = np.array([1.0, 1.0, 1.0])
UNLIT = hexc(0x141416)

# the mic pictogram, as the bar draws it (simulator/engine.js ICONS.call)
MIC = [
    "...###...",
    "..#####..",
    "..#####..",
    "..#####..",
    "..#####..",
    "#.#####.#",
    "#.#####.#",
    "#..###..#",
    ".#.....#.",
    "..#####..",
    "....#....",
    "..#####..",
]


def mix(a, b, t):
    return a + (b - a) * t


def round_rect_sdf(px, py, x0, y0, w, h, r):
    cx, cy = x0 + w / 2, y0 + h / 2
    qx, qy = abs(px - cx) - (w / 2 - r), abs(py - cy) - (h / 2 - r)
    ox, oy = max(qx, 0), max(qy, 0)
    return (ox * ox + oy * oy) ** 0.5 + min(max(qx, qy), 0) - r


def led_frame():
    """Colour and brightness of every LED: (COLS x ROWS x 3), unlit = None."""
    frame = [[None] * ROWS for _ in range(COLS)]
    px0, pw, py0, ph, pr = 1, COLS - 2, 3, 16, 2.6       # the pill, in LEDs
    for y in range(ROWS):
        for x in range(COLS):
            d = round_rect_sdf(x + 0.5, y + 0.5, px0, py0, pw, ph, pr)
            cover = min(max(0.5 - d, 0), 1)
            if cover <= 0:
                continue
            row = y - py0
            if row == 0:
                c = HIGHLIGHT
            elif row <= 3:
                c = TOP
            elif row == ph - 1:
                c = RIM_BOTTOM
            else:
                c = mix(TOP, BOTTOM, (row - 3) / (ph - 2 - 3))
            edge = min(max(1 - abs(d + 0.9), 0), 1)
            if edge > 0 and 0 < row < ph - 1:
                c = mix(c, EDGE, edge * 0.85)
            frame[x][y] = c * cover
    # the mic, centred, with its hard shadow one LED down and right
    mx0 = px0 + (pw - len(MIC[0])) // 2
    my0 = py0 + (ph - len(MIC)) // 2
    for colour, d, a in ((SHADOW, 1, 0.9), (WHITE, 0, 1.0)):
        for j, line in enumerate(MIC):
            for i, ch in enumerate(line):
                if ch == "#":
                    x, y = mx0 + i + d, my0 + j + d
                    frame[x][y] = mix(frame[x][y], colour, a)
    return frame


def squircle(radius, size, scale, corner=None):
    """The macOS icon shape: a square of half-width `radius` with corners
    of radius 185/412 of that (the macOS template's), as a mask."""
    corner = radius * 185 / 412 if corner is None else corner
    c = (size - 1) / 2
    t = np.abs(np.arange(size) - c) / scale - (radius - corner)
    qx, qy = t[None, :], t[:, None]
    d = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - corner
    return np.clip(0.5 - d * scale, 0, 1).astype(np.float32)


def vgradient(stops, top, bottom, size, scale):
    """Vertical gradient between y=top and y=bottom (in 1024 units)."""
    y = (np.arange(size) / scale - top) / (bottom - top)
    y = np.clip(y, 0, 1)
    out = np.zeros((size, 3), np.float32)
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        m = (y >= p0) & (y <= p1)
        t = ((y[m] - p0) / (p1 - p0))[:, None]
        out[m] = c0 + (c1 - c0) * t
    return np.broadcast_to(out[:, None, :], (size, size, 3))


def dot_tile(pitch_px, gap):
    """One LED: a rounded square at 85% of the pitch, shading to its corners
    (after Flipper's preview shader). Returns alpha and shade arrays."""
    t = np.arange(pitch_px) + 0.5
    cx = pitch_px / 2
    if not gap:
        a = np.ones((pitch_px, pitch_px))
        return a, a
    half = pitch_px * 0.85 / 2
    r = pitch_px * 0.30
    qx = np.abs(t - cx)[None, :] - (half - r)
    qy = np.abs(t - cx)[:, None] - (half - r)
    d = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r
    alpha = np.clip(0.5 - d, 0, 1)
    rr = np.hypot((t - cx)[None, :], (t - cx)[:, None]) / (pitch_px * 0.6)
    shade = 1 - 0.28 * rr ** 2
    return alpha, shade


def render(detailed):
    """The 1024 px icon, RGBA."""
    body = squircle(BODY_R, N, SS)
    face = squircle(FACE_R, N, SS, corner=BODY_R * 185 / 412 - RIM)     # concentric with the rim

    rim = vgradient([(0, hexc(0x6A6E73)), (0.05, hexc(0x3A3D41)), (0.5, hexc(0x222427)),
                     (0.95, hexc(0x17181A)), (1, hexc(0x44474B))], 512 - BODY_R, 512 + BODY_R, N, SS)
    img = rim * body[..., None]
    img = img * (1 - face[..., None])            # face starts black

    # LEDs
    frame = led_frame()
    pitch_px = int(round(PITCH * SS))
    alpha, shade = dot_tile(pitch_px, detailed)
    leds = np.zeros((N, N, 3), np.float32)
    lit = np.zeros((N, N, 3), np.float32)                    # lit LEDs only, for the glow
    for x in range(COLS):
        for y in range(ROWS):
            x0 = int(round((GRID_X0 + x * PITCH) * SS))
            y0 = int(round((GRID_Y0 + y * PITCH) * SS))
            # only LEDs wholly inside the face
            cx, cy = (x0 + pitch_px / 2) / SS - 512, (y0 + pitch_px / 2) / SS - 512
            reach = FACE_R - PITCH * 0.75
            k = BODY_R * 185 / 412 - RIM - PITCH * 0.75        # the face's corner, less a margin
            ox, oy = max(abs(cx) - (reach - k), 0), max(abs(cy) - (reach - k), 0)
            if abs(cx) > reach or abs(cy) > reach or (ox * ox + oy * oy) ** 0.5 > k:
                continue
            c = frame[x][y]
            if c is None:
                if not detailed:
                    continue
                c, is_lit = UNLIT, False
            else:
                is_lit = True
            tile = (alpha * shade)[..., None] * c
            leds[y0:y0 + pitch_px, x0:x0 + pitch_px] = np.maximum(leds[y0:y0 + pitch_px, x0:x0 + pitch_px], tile)
            if is_lit:
                lit[y0:y0 + pitch_px, x0:x0 + pitch_px] = alpha[..., None] * c
    img = img + leds * face[..., None]

    rgb = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).resize((1024, 1024), Image.LANCZOS)
    a_body = Image.fromarray((body * 255).astype(np.uint8)).resize((1024, 1024), Image.LANCZOS)
    a_face = np.asarray(Image.fromarray((face * 255).astype(np.uint8)).resize((1024, 1024), Image.LANCZOS)) / 255
    out = np.asarray(rgb).astype(np.float64) / 255

    # the light the lit LEDs throw across the glass
    glow_src = Image.fromarray((np.clip(lit, 0, 1) * 255).astype(np.uint8)).resize((1024, 1024), Image.LANCZOS)
    glow = np.asarray(glow_src.filter(ImageFilter.GaussianBlur(26))).astype(np.float64) / 255
    out = 1 - (1 - out) * (1 - glow * 0.55 * a_face[..., None])          # screen blend

    # glass: a soft sheen on the top third of the face
    y = np.arange(1024)
    top = 512 - FACE_R
    sheen = np.clip(1 - (y - top) / (FACE_R * 0.75), 0, 1) ** 1.6 * 0.10
    out = out + (1 - out) * (sheen[:, None, None] * a_face[..., None])

    # the drop shadow of the macOS icon grid
    body_a = np.asarray(a_body).astype(np.float64) / 255
    shadow = Image.fromarray((body_a * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(14))
    shadow = np.roll(np.asarray(shadow).astype(np.float64) / 255, 10, axis=0) * 0.38

    alpha_out = body_a + shadow * (1 - body_a)
    rgb_out = (out * body_a[..., None]) / np.maximum(alpha_out, 1e-6)[..., None]
    rgba = np.dstack([np.clip(rgb_out, 0, 1), alpha_out])
    return Image.fromarray((rgba * 255).round().astype(np.uint8), "RGBA")


def main():
    os.makedirs(ICONSET, exist_ok=True)
    detailed = render(True)
    simple = render(False)
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            src = detailed if px >= 128 else simple
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            src.resize((px, px), Image.LANCZOS).save(os.path.join(ICONSET, name))
            images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x", "filename": name})
    with open(os.path.join(ICONSET, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    with open(os.path.join(ICONSET, "..", "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    detailed.save(os.path.join(ROOT, "docs", "icon.png"))
    # the Stream Deck plugin's icon, in Stream Deck's list of plugins
    plugin = os.path.join(ROOT, "streamdeck", "com.woodall.busybarsign.sdPlugin", "imgs", "plugin")
    os.makedirs(plugin, exist_ok=True)
    for px, name in ((288, "marketplace.png"), (512, "marketplace@2x.png")):
        detailed.resize((px, px), Image.LANCZOS).save(os.path.join(plugin, name))
    print("wrote", ICONSET)


if __name__ == "__main__":
    main()
