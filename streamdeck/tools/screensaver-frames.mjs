/*
 * Frames of the Stream Deck screensaver: the bar's lit pill filling the
 * deck, BUSY / BAR in the announcement's 14-row capitals, the sheen
 * crossing it as it crosses the bar. Raw RGB, frame after frame, to stdout;
 * tools/screensaver.py makes the GIFs.
 *
 *   node tools/screensaver-frames.mjs <width> <height> <frames> <state>
 */
import '../../simulator/fonts.js';
import '../../simulator/engine.js';

const E = globalThis.BusyEngine;
E.setFonts(globalThis.BUSY_FONTS);

const [W, H, FRAMES] = process.argv.slice(2, 5).map(Number);
const STATE = process.argv[5] || 'call';
const LINES = ['BUSY', 'BAR'];
const FONT = 'busy_regular_14', LINE_H = 14, GAP = 4;
const SHEEN_CYCLE = 8;                         // seconds: the bar's sheen

// LEDs as big as fit: the words' 32 rows, and two rows of pill above and below them
const rows = LINES.length * LINE_H + (LINES.length - 1) * GAP + 8;
const pitch = Math.floor(H / (rows + 2));
const cols = Math.floor(W / pitch) - 2;
const ox = Math.floor((W - cols * pitch) / 2), oy = Math.floor((H - rows * pitch) / 2);

// LEDRaster's look, as the keys have it (src/key.js)
const LOOK = { ledFill: 0.85, ledRadius: 0.353, unlit: [0.018, 0.018, 0.02], gamma: 1.25 };
const mask = new Float32Array(pitch * pitch);
{
  const led = pitch * LOOK.ledFill, r = led * LOOK.ledRadius, half = led / 2;
  for (let y = 0; y < pitch; y++) for (let x = 0; x < pitch; x++) {
    const px = x + 0.5 - pitch / 2, py = y + 0.5 - pitch / 2;
    const qx = Math.abs(px) - (half - r), qy = Math.abs(py) - (half - r);
    const d = Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
    const cover = Math.min(Math.max(0.5 - d, 0), 1);
    const dist = Math.hypot(px, py) / pitch;
    mask[y * pitch + x] = cover * (dist <= 0.3 ? 1 : Math.max(0.85, 1 - 0.15 * (dist - 0.3) / 0.4));
  }
}

const pal = E.palOf(STATE);
for (let i = 0; i < FRAMES; i++) {
  const out = Buffer.alloc(W * H * 3);          // a buffer a frame: stdout writes later
  const now = (i / FRAMES) * SHEEN_CYCLE;
  const f = new E.Frame(cols, rows);
  E.drawPill(f, 0, cols, pal, { h: rows, sheen: E.sheenAt(now, cols) });
  let top = Math.round((rows - (LINES.length * LINE_H + (LINES.length - 1) * GAP)) / 2);
  for (const line of LINES) {
    const w = E.textWidth(FONT, line, 0, 6);
    E.drawText(f, FONT, line, Math.round((cols - w) / 2), top + LINE_H - 1, E.PALETTE.white,
      { shadow: pal.shadow, shadowDepth: 2, space: 6, shadowAlpha: 0.9 });
    top += LINE_H + GAP;
  }
  for (let ly = 0; ly < rows; ly++) for (let lx = 0; lx < cols; lx++) {
    const c = f.get(lx, ly).map((v, k) => LOOK.unlit[k] + Math.pow(Math.max(v, 0), LOOK.gamma) * (1 - LOOK.unlit[k]));
    for (let y = 0; y < pitch; y++) for (let x = 0; x < pitch; x++) {
      const m = mask[y * pitch + x], o = ((oy + ly * pitch + y) * W + ox + lx * pitch + x) * 3;
      for (let k = 0; k < 3; k++) out[o + k] = Math.round(255 * Math.min(1, c[k] * m));
    }
  }
  process.stdout.write(out);
}
