/*
 * Render engine frames to PNG, headless.
 *   node tools/snap.js out.png <state> <prev|-> <t1> [t2 ...]
 * Each t is seconds since the state change; frames stack vertically.
 */
const fs = require('fs'), zlib = require('zlib'), path = require('path');
require(path.join(__dirname, '..', 'fonts.js'));
require(path.join(__dirname, '..', 'engine.js'));
const E = globalThis.BusyEngine;
E.setFonts(globalThis.BUSY_FONTS);

const [out, state, prevArg, ...ts] = process.argv.slice(2);
const prev = prevArg === '-' ? null : prevArg;
const S = 9, GAP = 12, LABEL = 0;
const W = E.COLS * S, H = ts.length * (E.ROWS * S + GAP);
const img = Buffer.alloc(W * H * 3, 0);

ts.forEach((tStr, i) => {
  const t = parseFloat(tStr);
  const f = new E.Frame();
  const since = 1000, now = since + t;
  E.render(f, now, state, prev, since, { h: 14, m: 32, s: 27, ms: 200 });
  const oy = i * (E.ROWS * S + GAP);
  for (let y = 0; y < E.ROWS; y++) for (let x = 0; x < E.COLS; x++) {
    let [r, g, b] = f.get(x, y);
    if (r + g + b < 0.004) { r = g = b = 0.085; }
    for (let yy = 1; yy < S; yy++) for (let xx = 1; xx < S; xx++) {
      const p = ((oy + y * S + yy) * W + (x * S + xx)) * 3;
      img[p] = Math.round(r * 255); img[p + 1] = Math.round(g * 255); img[p + 2] = Math.round(b * 255);
    }
  }
});

function png(w, h, rgb) {
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (w * 3 + 1)] = 0; rgb.copy(raw, y * (w * 3 + 1) + 1, y * w * 3, (y + 1) * w * 3); }
  const crcT = []; for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; crcT[n] = c >>> 0; }
  const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type), data]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([len, td, c]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
fs.writeFileSync(out, png(W, H, img));
console.log('wrote', out, W + 'x' + H);
