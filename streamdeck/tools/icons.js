/*
 * Draws the plugin's small images into the plugin folder: each action's
 * icon in Stream Deck's list (white on clear, as Elgato asks), the
 * category's, and each key's picture before the plugin has drawn one.
 * The plugin's own icon is the app's (tools/icon/make_icon.py).
 *
 *   node tools/icons.js
 */
import fs from 'node:fs';
import path from 'node:path';
import { drawLabel, drawMeetingKey, KEY_ICONS, paint, SIZE } from '../src/key.js';
import { png } from '../src/png.js';

const imgs = path.join(import.meta.dirname, '..', 'com.woodall.busybarsign.sdPlugin', 'imgs');

/* Signed distance to a rounded rectangle; negative inside. */
function box(px, py, x0, y0, w, h, r) {
  const qx = Math.abs(px - (x0 + w / 2)) - (w / 2 - r), qy = Math.abs(py - (y0 + h / 2)) - (h / 2 - r);
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
}

/* The bar in outline, on a 40-unit square: its case, the lit pill on the
   left, and the clock's two lines on the right. */
function glyph(x, y) {
  const inCase = Math.max(box(x, y, 2, 11, 36, 18, 5), -box(x, y, 4.5, 13.5, 31, 13, 2.5));    // a 2.5-unit rim
  const pill = box(x, y, 7, 16, 15, 8, 2);
  const clock = Math.min(box(x, y, 25, 16.5, 8, 3, 1), box(x, y, 26.5, 21.5, 5, 2, 0.8));
  return Math.min(inCase, pill, clock);
}

/* A key icon's LED rows, centred on the 40-unit square: inside where a row has '#'. */
function rowsGlyph(rows) {
  const cell = 34 / Math.max(rows.length, rows[0].length);
  const x0 = (40 - rows[0].length * cell) / 2, y0 = (40 - rows.length * cell) / 2;
  return (x, y) => {
    const c = Math.floor((x - x0) / cell), r = Math.floor((y - y0) / cell);
    return r >= 0 && r < rows.length && c >= 0 && c < rows[0].length && rows[r][c] === '#' ? -1 : 1;
  };
}

/* White on clear at `px` px, anti-aliased by 4 x 4 samples. */
function icon(px, shape = glyph) {
  const out = Buffer.alloc(px * px * 4), s = 40 / px, ss = 4;
  for (let y = 0; y < px; y++) for (let x = 0; x < px; x++) {
    let a = 0;
    for (let j = 0; j < ss; j++) for (let i = 0; i < ss; i++) {
      if (shape((x + (i + 0.5) / ss) * s, (y + (j + 0.5) / ss) * s) <= 0) a++;
    }
    out.fill(255, (y * px + x) * 4, (y * px + x) * 4 + 3);
    out[(y * px + x) * 4 + 3] = Math.round(255 * a / (ss * ss));
  }
  return png(px, px, out, 4);
}

function write(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, data);
  console.log('wrote', path.relative(process.cwd(), file));
}

write(path.join(imgs, 'actions', 'status', 'icon.png'), icon(20));
write(path.join(imgs, 'actions', 'status', 'icon@2x.png'), icon(40));
write(path.join(imgs, 'plugin', 'category-icon.png'), icon(28));
write(path.join(imgs, 'plugin', 'category-icon@2x.png'), icon(56));

/* A key's picture at 144 px and, each 2 x 2 averaged, at 72. */
function keyPictures(dir, frame) {
  const key = paint(frame);
  write(path.join(imgs, 'actions', dir, 'key@2x.png'), png(SIZE, SIZE, key));
  const half = SIZE / 2, small = Buffer.alloc(half * half * 3);
  for (let y = 0; y < half; y++) for (let x = 0; x < half; x++) for (let c = 0; c < 3; c++) {
    const p = (yy, xx) => key[(yy * SIZE + xx) * 3 + c];
    small[(y * half + x) * 3 + c] = (p(2 * y, 2 * x) + p(2 * y, 2 * x + 1) + p(2 * y + 1, 2 * x) + p(2 * y + 1, 2 * x + 1) + 2) >> 2;
  }
  write(path.join(imgs, 'actions', dir, 'key.png'), png(half, half, small));
}

keyPictures('status', drawLabel(['BUSY', 'BAR'], 'away'));

// the Mute and Leave keys: their icons in the list, and their faces outside a meeting
for (const [dir, rows] of [['mute', KEY_ICONS.mic], ['leave', KEY_ICONS.handset]]) {
  write(path.join(imgs, 'actions', dir, 'icon.png'), icon(20, rowsGlyph(rows)));
  write(path.join(imgs, 'actions', dir, 'icon@2x.png'), icon(40, rowsGlyph(rows)));
  keyPictures(dir, drawMeetingKey(dir, 'idle'));
}
