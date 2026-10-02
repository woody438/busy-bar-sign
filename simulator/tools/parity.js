/*
 * Checks the Swift engine against this one, LED by LED. Run via
 * Checks/run.sh, which builds Checks/parity/main.swift and passes its
 * output here. Both sides render the same moments; any LED differing by
 * more than one 8-bit step fails the check.
 */
const fs = require('fs'), path = require('path');
require(path.join(__dirname, '..', 'fonts.js'));
require(path.join(__dirname, '..', 'engine.js'));
const E = globalThis.BusyEngine;
E.setFonts(globalThis.BUSY_FONTS);

// keep in step with Checks/parity/main.swift
const CASES = [
  ['call', 'free', 0.03], ['call', 'free', 0.07], ['call', 'free', 0.12], ['call', 'free', 0.16],
  ['call', 'free', 0.5], ['call', 'free', 2.0], ['call', 'free', 3.6], ['call', 'free', 3.75],
  ['call', 'free', 3.9], ['call', 'free', 4.05], ['call', 'free', 9.0],
  ['free', 'call', 0.05], ['free', 'call', 0.3], ['free', 'call', 3.8], ['free', 'call', 9.0],
  ['call', null, 0.02], ['call', null, 0.4],
  ['dnd', 'free', 0.03], ['dnd', 'free', 0.5], ['dnd', 'free', 3.8], ['dnd', 'free', 9.0],
  ['call', 'dnd', 0.05], ['free', 'dnd', 0.05], ['dnd', 'call', 3.75], ['dnd', null, 0.4]
];
const timer = { left: 1234.4, h: 15, m: 2 };
// the stacked layout, for small screens (keep in step with main.swift)
const STACKED_CASES = [
  ['call', 'free', 0.05], ['call', 'free', 0.15], ['call', 'free', 1.5], ['call', 'free', 3.6],
  ['call', 'free', 3.8], ['call', 'free', 4.0], ['call', 'free', 9.0],
  ['dnd', 'call', 0.3], ['dnd', 'call', 3.85], ['dnd', 'call', 9.0], ['free', 'dnd', 2.0], ['free', null, 9.0]
];
// the calendar's states, each with the timer the app gives it (keep in step with main.swift)
const TIMERS = {
  soon: { left: 461.2, h: 11, m: 0 }, late: { left: 80.4, h: 9, m: 45 }, till: { left: 0, h: 11, m: 0 },
  free: { left: 4532.6, h: 12, m: 0 }, dnd: { left: 1234.4, h: 15, m: 2 }
};
const CALENDAR_CASES = [
  ['meeting', 'free', 2.0, 'free'], ['meeting', 'free', 3.75, 'free'], ['meeting', 'free', 9.0, 'free'],
  ['call', 'callIn', 9.0, 'free'], ['call', 'late', 0.05, 'free'],
  ['callIn', 'free', 0.5, 'soon'], ['callIn', 'free', 2.0, 'soon'], ['callIn', 'free', 3.75, 'soon'], ['callIn', 'free', 9.0, 'soon'],
  ['busyIn', 'free', 9.0, 'soon'],
  ['late', 'callIn', 2.0, 'late'], ['late', 'callIn', 3.75, 'late'], ['late', 'callIn', 9.0, 'late'],
  ['late', 'callIn', 9.4, 'late'], ['late', 'callIn', 10.2, 'late'],
  ['freeTil', 'call', 2.0, 'till'], ['freeTil', 'call', 3.9, 'till'], ['freeTil', 'call', 9.0, 'till'], ['freeTil', 'call', 2.0, null],
  ['callTbc', 'free', 2.0, 'soon'], ['callTbc', 'free', 9.0, 'soon'], ['callTbc', 'free', 9.0, 'till'],
  ['busyTbc', 'free', 9.0, 'till'],
  ['away', 'free', 2.0, null], ['away', 'free', 9.0, null], ['lunch', 'away', 2.0, null], ['lunch', 'away', 3.75, null], ['lunch', null, 9.0, null],
  ['ooo', 'free', 2.0, null], ['ooo', 'free', 3.8, null], ['ooo', 'free', 9.0, null]
];
const STACKED_CALENDAR_CASES = [
  ['meeting', 'free', 2.0, 'free'], ['meeting', 'free', 9.0, 'free'], ['callIn', 'free', 2.0, 'soon'], ['callIn', 'free', 3.8, 'soon'],
  ['late', 'callIn', 2.0, 'late'], ['late', 'callIn', 9.3, 'late'], ['freeTil', 'call', 2.0, 'till'], ['freeTil', 'call', 9.0, 'till'],
  ['callTbc', 'free', 2.0, 'till'], ['busyTbc', 'free', 9.0, 'soon'], ['lunch', 'free', 2.0, null], ['ooo', 'free', 2.0, null],
  ['ooo', 'free', 9.0, null], ['away', 'free', 2.0, null]
];
const clock = { h: 14, m: 32, s: 27, ms: 200, dow: 2, date: 30 };

const JOBS = CASES.map((c) => ['wide', ...c, timer])
  .concat(STACKED_CASES.map((c) => ['stacked', ...c, timer]))
  .concat(CALENDAR_CASES.map(([s, p, e, k]) => ['wide', s, p, e, k ? TIMERS[k] : undefined]))
  .concat(STACKED_CALENDAR_CASES.map(([s, p, e, k]) => ['stacked', s, p, e, k ? TIMERS[k] : undefined]));
const size = (layout) => (layout === 'wide' ? E.COLS * E.ROWS : E.STACKED.cols * E.STACKED.rows) * 3;

const buf = fs.readFileSync(process.argv[2]);
const total = JOBS.reduce((sum, [layout]) => sum + size(layout), 0);
if (buf.length !== total * 8) { console.error('size mismatch', buf.length, 'expected', total * 8); process.exit(2); }

let worst = 0, failed = 0, offset = 0;
JOBS.forEach(([layout, state, prev, e, tm]) => {
  const stacked = layout === 'stacked';
  const f = stacked ? new E.Frame(E.STACKED.cols, E.STACKED.rows) : new E.Frame();
  (stacked ? E.renderStacked : E.render)(f, 1000 + e, state, prev, 1000, clock, tm);
  const n = size(layout);
  let maxd = 0, at = -1, bad = 0;
  for (let j = 0; j < n; j++) {
    const s = buf.readDoubleLE((offset + j) * 8);
    const d = Math.abs(s - f.px[j]);
    if (d > maxd) { maxd = d; at = j; }
    if (d * 255 > 1) bad++;
  }
  offset += n;
  worst = Math.max(worst, maxd);
  const led = at >= 0 ? `x${Math.floor(at / 3) % f.w} y${Math.floor(at / 3 / f.w)}` : '';
  console.log(`${layout.padEnd(8)} ${(state + ' <- ' + (prev || '-')).padEnd(14)} t=${String(e).padEnd(5)} max diff ${(maxd * 255).toFixed(4)}/255 ${bad ? 'FAIL ' + bad + ' LEDs ' + led : 'ok'}`);
  if (bad) failed++;
});
console.log(failed ? `\n${failed} of ${JOBS.length} frames differ` : `\nall ${JOBS.length} frames match (worst ${(worst * 255).toFixed(5)}/255)`);
process.exit(failed ? 1 : 0);
