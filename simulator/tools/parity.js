/*
 * Checks the Swift engine against this one, LED by LED.
 *
 *   swiftc -O Sources/Bar/{BarEngine,PixelFonts,FontData}.swift simulator/tools/parity.swift -o /tmp/bartest
 *   /tmp/bartest /tmp/swift.bin
 *   node simulator/tools/parity.js /tmp/swift.bin
 *
 * Both sides render the same moments; any LED differing by more than one
 * 8-bit step fails the check.
 */
const fs = require('fs'), path = require('path');
require(path.join(__dirname, '..', 'fonts.js'));
require(path.join(__dirname, '..', 'engine.js'));
const E = globalThis.BusyEngine;
E.setFonts(globalThis.BUSY_FONTS);

// keep in step with parity.swift
const CASES = [
  ['call', 'free', 0.03], ['call', 'free', 0.07], ['call', 'free', 0.12], ['call', 'free', 0.16],
  ['call', 'free', 0.5], ['call', 'free', 2.0], ['call', 'free', 3.6], ['call', 'free', 3.75],
  ['call', 'free', 3.9], ['call', 'free', 4.05], ['call', 'free', 9.0],
  ['free', 'call', 0.05], ['free', 'call', 0.3], ['free', 'call', 3.8], ['free', 'call', 9.0],
  ['call', null, 0.02], ['call', null, 0.4]
];
const clock = { h: 14, m: 32, s: 27, ms: 200, dow: 2, date: 30 };

const buf = fs.readFileSync(process.argv[2]);
const n = E.COLS * E.ROWS * 3;
if (buf.length !== CASES.length * n * 8) { console.error('size mismatch', buf.length); process.exit(2); }

let worst = 0, failed = 0;
CASES.forEach(([state, prev, e], i) => {
  const f = new E.Frame();
  E.render(f, 1000 + e, state, prev, 1000, clock);
  let maxd = 0, at = -1, bad = 0;
  for (let j = 0; j < n; j++) {
    const s = buf.readDoubleLE((i * n + j) * 8);
    const d = Math.abs(s - f.px[j]);
    if (d > maxd) { maxd = d; at = j; }
    if (d * 255 > 1) bad++;
  }
  worst = Math.max(worst, maxd);
  const led = at >= 0 ? `x${Math.floor(at / 3) % E.COLS} y${Math.floor(at / 3 / E.COLS)}` : '';
  console.log(`${(state + ' <- ' + (prev || '-')).padEnd(14)} t=${String(e).padEnd(5)} max diff ${(maxd * 255).toFixed(4)}/255 ${bad ? 'FAIL ' + bad + ' LEDs ' + led : 'ok'}`);
  if (bad) failed++;
});
console.log(failed ? `\n${failed} of ${CASES.length} frames differ` : `\nall ${CASES.length} frames match (worst ${(worst * 255).toFixed(5)}/255)`);
process.exit(failed ? 1 : 0);
