#!/usr/bin/env python3
"""
Makes the Stream Deck screensaver: the one Stream Deck shows across its
keys while the Mac is locked, in place of Elgato's logo. The bar's lit
pill and BUSY / BAR in its LEDs, the sheen crossing it, as an animated GIF
for each Stream Deck size.

    python3 tools/screensaver.py         # in streamdeck/; needs node and Pillow

Writes screensaver/busy-bar-<model>.gif, and busy-bar-<model>.png as a still
for a Stream Deck that won't take the GIF. Set one in Stream Deck ▸ Settings
▸ Devices ▸ your Stream Deck ▸ Screensaver.
"""
import os
import subprocess

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "screensaver")
# the screensaver's size on each Stream Deck that shows one
MODELS = {"mk2": (480, 272), "xl": (1024, 600), "plus": (800, 480)}
FRAMES = 40                      # the sheen's 8 s, at 5 a second
STATE = "call"                   # the pill's colour: the bar's red

os.makedirs(OUT, exist_ok=True)
for model, (w, h) in MODELS.items():
    raw = subprocess.run(["node", os.path.join(HERE, "screensaver-frames.mjs"), str(w), str(h), str(FRAMES), STATE],
                         check=True, capture_output=True).stdout
    size = w * h * 3
    frames = [Image.frombytes("RGB", (w, h), raw[i * size:(i + 1) * size]) for i in range(FRAMES)]
    # one palette for every frame, from frames across the sheen's path, so it has the sheen's colours too
    sample = Image.new("RGB", (w, h * 4))
    for k in range(4):
        sample.paste(frames[k * FRAMES // 4 + FRAMES // 8], (0, h * k))
    palette = sample.quantize(colors=255, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    gif = [f.quantize(palette=palette, dither=Image.Dither.NONE) for f in frames]
    path = os.path.join(OUT, f"busy-bar-{model}.gif")
    gif[0].save(path, save_all=True, append_images=gif[1:], duration=200, loop=0, optimize=True)
    print("wrote", os.path.relpath(path), f"{w}x{h}", os.path.getsize(path) // 1024, "KB")
    still = os.path.join(OUT, f"busy-bar-{model}.png")
    frames[FRAMES // 2].save(still, optimize=True)            # the sheen half way across
    print("wrote", os.path.relpath(still), f"{w}x{h}", os.path.getsize(still) // 1024, "KB")
