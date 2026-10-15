/*
 * Every state on one sheet, at the key's own 144 px and as a 72 px key shows
 * it, for checking the design by eye.
 *
 *   node tools/sheet.js out.png
 *   node tools/sheet.js ../docs/stream-deck-keys.png --readme    # six in a row, for the README
 */
import fs from 'node:fs';
import { drawKey, paint, SIZE, STATES } from '../src/key.js';
import { png } from '../src/png.js';

const at = new Date(2026, 9, 6, 14, 32, 27).getTime();       // Tue 6 Oct, 14:32:27, an odd second
const min = 60 * 1000;
const keys = [
  ...STATES.map((state) => {
    const moment = {
      call: { at: at + 47 * min + 12000, kind: 'countdown' }, meeting: { at: at + 65 * min, kind: 'countdown' },
      dnd: { at: at + 23 * min + 59000, kind: 'countdown' }, callIn: { at: at + 9 * min + 41000, kind: 'countdown' },
      busyIn: { at: at + 9 * min + 41000, kind: 'countdown' }, late: { at: at - 80000, kind: 'countUp' },
      freeTil: { at: at + 28 * min, kind: 'fixed' }, callTbc: { at: at + 4 * min + 10000, kind: 'countdown' },
      busyTbc: { at: at + 58 * min, kind: 'fixed' }
    }[state] || null;
    return { state, moment };
  }),
  { state: 'call', moment: null },        // on a call the calendar doesn't know about: the time
  { state: 'late', moment: { at: at - 81000, kind: 'countUp' }, even: true },   // LATE's other blink
  null,                                   // the app isn't answering
  { state: 'somethingNew', moment: null }
];

const readme = process.argv.includes('--readme');
if (readme) keys.splice(0, keys.length, ...['call', 'free', 'dnd', 'callIn', 'late', 'lunch'].map((s) => keys.find((k) => k && k.state === s)));
const G = readme ? 16 : 12, COLS = 6, rows = Math.ceil(keys.length / COLS);
const W = COLS * (SIZE + G) + G, H = rows * (SIZE + G) + G;
const sheet = Buffer.alloc(W * H * 3, readme ? 20 : 48);
keys.forEach((k, i) => {
  const img = paint(drawKey(k, new Date(at + (readme || (k && k.even) ? 1000 : 0))));
  const ox = G + (i % COLS) * (SIZE + G), oy = G + Math.floor(i / COLS) * (SIZE + G);
  for (let y = 0; y < SIZE; y++) img.copy(sheet, ((oy + y) * W + ox) * 3, y * SIZE * 3, (y + 1) * SIZE * 3);
});
// and as a 72 px key shows it: each 2 x 2 averaged
const w = W >> 1, h = H >> 1, small = Buffer.alloc(w * h * 3);
for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) for (let c = 0; c < 3; c++) {
  const p = (yy, xx) => sheet[(yy * W + xx) * 3 + c];
  small[(y * w + x) * 3 + c] = (p(2 * y, 2 * x) + p(2 * y, 2 * x + 1) + p(2 * y + 1, 2 * x) + p(2 * y + 1, 2 * x + 1) + 2) >> 2;
}
const out = process.argv[2] || 'keys.png';
fs.writeFileSync(out, png(W, H, sheet));
if (!readme) fs.writeFileSync(out.replace(/\.png$/, '') + '-72.png', png(w, h, small));
console.log('wrote', out);
