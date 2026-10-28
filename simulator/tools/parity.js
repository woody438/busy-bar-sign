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
  free: { left: 4532.6, h: 12, m: 0 }, dnd: { left: 1234.4, h: 15, m: 2 },
  // time left: a call's meeting half done; its last two minutes (amber, sweeping); joined early (full)
  slot: { left: 4532.6, h: 12, m: 0, slot: { left: 1834.2, total: 3600 } },
  slotEnd: { left: 4532.6, h: 12, m: 0, slot: { left: 101.7, total: 1800 } },
  slotEarly: { left: 3700, h: 12, m: 0, slot: { left: 3700, total: 3600 } },
  // CALL SOON in its last two minutes, and just before them
  bigSoon: { left: 101.5, h: 11, m: 0 }, bigLater: { left: 125, h: 11, m: 0 }
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
  ['ooo', 'free', 2.0, null], ['ooo', 'free', 3.8, null], ['ooo', 'free', 9.0, null],
  ['callMuted', 'call', 9.0, 'free'], ['callMuted', 'free', 2.0, 'free'], ['callMuted', 'free', 3.75, 'free'],
  ['callMuted', null, 9.0, null], ['call', 'callMuted', 0.05, 'free'],
  // the muted mic's slow flash: fading out, off, fading back
  ['callMuted', null, 9.2, null], ['callMuted', null, 9.5, null], ['callMuted', 'call', 9.9, 'free'],
  // the away keys: NEARBY alone in its pill, BACK IN counting down (an hour and more: 1H15)
  ['nearby', 'free', 2.0, null], ['nearby', 'free', 3.75, null], ['nearby', null, 9.0, null],
  ['backIn', 'nearby', 2.0, 'soon'], ['backIn', 'nearby', 3.75, 'soon'], ['backIn', 'free', 9.0, 'soon'],
  ['backIn', 'lunch', 9.0, 'free'], ['call', 'backIn', 0.05, 'free'],
  // a meeting in a room started without you, breathing as LATE does; out on site with a client
  ['lateMtg', 'busyIn', 2.0, 'late'], ['lateMtg', 'busyIn', 3.75, 'late'], ['lateMtg', 'busyIn', 9.0, 'late'],
  ['lateMtg', 'busyIn', 9.4, 'late'], ['meeting', 'lateMtg', 0.05, 'free'],
  ['onSite', 'free', 2.0, null], ['onSite', 'free', 3.8, null], ['onSite', 'free', 9.0, null],
  // lunch from the calendar: a countdown to when you're back
  ['lunch', 'free', 3.75, 'free'], ['lunch', 'meeting', 9.0, 'soon'],
  // FREE a quarter of an hour on: the icon and word scroll out to the left and back in from the
  // right (and not after it, or a call); the next quarter's; and the other quiet states'
  ['free', 'call', 904.467, null], ['free', 'call', 905.067, null], ['free', 'call', 905.667, null], ['free', 'call', 906.267, null],
  ['free', 'call', 907.0, null], ['call', 'free', 905.067, 'free'], ['free', 'call', 1804.767, null],
  ['nearby', null, 905.0, null], ['ooo', 'free', 906.0, null], ['lunch', 'free', 905.5, 'free'],
  // time left: the rail filling in as the call settles, settled, muted, amber and sweeping, full;
  // pressed down as FREE takes over; not for lunch; CALL SOON's big countdown widening, held,
  // narrowing and between them (every 9 s by `now`: 1000 + e), not yet, and in the announcement
  ['call', 'free', 3.9, 'slot'], ['call', 'free', 4.1, 'slot'], ['call', 'free', 9.0, 'slot'], ['callMuted', null, 9.0, 'slotEnd'],
  ['meeting', 'free', 9.0, 'slotEnd'], ['meeting', 'free', 9.0, 'slotEarly'], ['free', 'call', 0.05, 'slot'], ['lunch', 'free', 9.0, 'slot'],
  ['callIn', 'free', 8.1, 'bigSoon'], ['callIn', 'free', 9.4, 'bigSoon'], ['callIn', 'free', 11.1, 'bigSoon'], ['callIn', 'free', 13.0, 'bigSoon'],
  ['callIn', 'free', 9.4, 'bigLater'], ['busyIn', 'free', 9.4, 'bigSoon'], ['callIn', 'free', 2.0, 'bigSoon'],
  ['callIn', 'free', 8.03, 'bigSoon'], ['callIn', 'free', 11.25, 'bigSoon']
];
const STACKED_CALENDAR_CASES = [
  ['meeting', 'free', 2.0, 'free'], ['meeting', 'free', 9.0, 'free'], ['callIn', 'free', 2.0, 'soon'], ['callIn', 'free', 3.8, 'soon'],
  ['late', 'callIn', 2.0, 'late'], ['late', 'callIn', 9.3, 'late'], ['freeTil', 'call', 2.0, 'till'], ['freeTil', 'call', 9.0, 'till'],
  ['callTbc', 'free', 2.0, 'till'], ['busyTbc', 'free', 9.0, 'soon'], ['lunch', 'free', 2.0, null], ['ooo', 'free', 2.0, null],
  ['ooo', 'free', 9.0, null], ['away', 'free', 2.0, null], ['callMuted', 'free', 2.0, 'free'], ['callMuted', 'call', 9.0, 'free'],
  ['callMuted', 'call', 9.5, 'free'],
  ['nearby', 'free', 2.0, null], ['nearby', 'free', 3.8, null], ['nearby', 'free', 9.0, null],
  ['backIn', 'free', 2.0, 'soon'], ['backIn', 'free', 9.0, 'soon'],
  ['lateMtg', 'busyIn', 2.0, 'late'], ['lateMtg', 'busyIn', 9.3, 'late'], ['onSite', 'free', 2.0, null], ['onSite', 'free', 9.0, null],
  ['lunch', 'free', 9.0, 'free'],
  // the scroll, stacked
  ['free', 'call', 904.767, null], ['free', 'call', 905.967, null], ['onSite', 'free', 905.3, null],
  // time left, stacked: filling in, settled, amber and sweeping; CALL SOON sweeping
  ['call', 'free', 4.1, 'slot'], ['call', 'free', 9.0, 'slot'], ['meeting', 'free', 9.0, 'slotEnd'], ['callIn', 'free', 9.0, 'bigSoon']
];
// the Nearby key's own word, through each way of fitting it: as it is; stacked a step
// tighter; the announcement in the status face, stacked in it too; stacked on two lines
// (keep in step with main.swift)
const NEARBY_CASES = [
  ['W HOUSE', 'wide', 2.0], ['W HOUSE', 'wide', 3.75], ['W HOUSE', 'wide', 9.0],
  ['W HOUSE', 'stacked', 2.0], ['W HOUSE', 'stacked', 3.8], ['W HOUSE', 'stacked', 9.0],
  ['STUDIO 2', 'wide', 2.0], ['STUDIO 2', 'stacked', 2.0],
  ['1111111111', 'wide', 2.0], ['1111111111', 'wide', 3.75], ['1111111111', 'stacked', 2.0],
  ['1111 1111', 'stacked', 2.0], ['1111 1111', 'stacked', 3.8]
];
// the words the sign takes for the Nearby key, as BarEngine takes them (keep in step with main.swift)
const NEARBY_WORDS = [
  [null, 'NEARBY'], ['', 'NEARBY'], ['  w   house ', 'W HOUSE'], ['Studio 2', 'STUDIO 2'], ['kitchen', 'KITCHEN'],
  ['WAREHOUSE', 'NEARBY'], ['UPSTAIRS', 'NEARBY'], ['Café', 'NEARBY'], ['✈ AWAY', 'NEARBY'], ['1111111111..', '1111111111..']
];
const PROBLEMS = [['W HOUSE', null], ['WAREHOUSE', 'sign'], ['UPSTAIRS', 'key'], ['café', 'characters']];
for (const [word, takes] of NEARBY_WORDS) {
  if (E.nearbyWordOf(word) !== takes) { console.error(`the sign takes ${word} as ${E.nearbyWordOf(word)}, not ${takes}`); process.exit(2); }
}
for (const [word, problem] of PROBLEMS) {
  if (E.nearbyProblem(word) !== problem) { console.error(`${word}: ${E.nearbyProblem(word)}, not ${problem}`); process.exit(2); }
}
// how bright the LEDs are: dimmed only after half an hour of a quiet state (keep in step with main.swift)
const RESTS = [
  ['free', 0, 1], ['free', 1800, 1], ['free', 1815, 0.86], ['free', 1830, 0.83], ['nearby', 7200, 0.83],
  ['call', 7200, 1], ['dnd', 7200, 1], ['callIn', 7200, 1]
];
for (const [state, e, level] of RESTS) {
  if (E.restAt(1000 + e, state, 1000) !== level) { console.error(`${state} at ${e} s rests at ${E.restAt(1000 + e, state, 1000)}, not ${level}`); process.exit(2); }
}
const clock = { h: 14, m: 32, s: 27, ms: 200, dow: 2, date: 30 };
// world clocks: two plans through each phase — settling, the split, a city rolling in, the board
// rolling up, held and rolling away, the ticker, resting, the scroll, a skipped clash, the board
// over the rest, and FREE pressed down as a call starts (keep in step with main.swift)
const WORLD_ZONES = [
  { code: 'LON', h: 14, m: 32, dow: 2, date: 30, dayDelta: 0 }, { code: 'NYC', h: 9, m: 32, dow: 2, date: 30, dayDelta: 0 },
  { code: 'TYO', h: 23, m: 32, dow: 2, date: 30, dayDelta: 0 }, { code: 'SYD', h: 0, m: 32, dow: 3, date: 31, dayDelta: 1 }
];
const WORLD_PLANS = {
  all: { zones: WORLD_ZONES, turns: { on: true, secs: 5 }, rest: { on: true, mins: 30 }, board: { on: true, mins: 5, secs: 20 },
    ticker: { on: true, mins: 15 }, rules: { restHolds: true, clash: 'wait', tickerForScroll: true } },
  plain: { zones: WORLD_ZONES, turns: { on: false, secs: 5 }, rest: { on: true, mins: 60 }, board: { on: true, mins: 7, secs: 20 },
    ticker: { on: true, mins: 21 }, rules: { restHolds: false, clash: 'skip', tickerForScroll: false } }
};
// fewer cities (a clock set to None): the layouts close up around the ones left
WORLD_PLANS.two = Object.assign({}, WORLD_PLANS.all, { zones: [WORLD_ZONES[0], WORLD_ZONES[3]] });
WORLD_PLANS.three = Object.assign({}, WORLD_PLANS.all, { zones: [WORLD_ZONES[0], WORLD_ZONES[1], WORLD_ZONES[3]] });
const WORLD_CASES = [
  ['wide', 'all', 2.167], ['wide', 'all', 3.867], ['wide', 'all', 9.167], ['wide', 'all', 9.367], ['wide', 'all', 304.417],
  ['wide', 'all', 309.167], ['wide', 'all', 324.917], ['wide', 'all', 904.767], ['wide', 'all', 907.167], ['wide', 'all', 917.167],
  ['wide', 'all', 1804.567], ['wide', 'all', 1806.167],
  ['wide', 'plain', 2.167], ['wide', 'plain', 9.167], ['wide', 'plain', 424.417], ['wide', 'plain', 904.767],
  ['wide', 'plain', 1264.767], ['wide', 'plain', 1267.167], ['wide', 'plain', 1280.167], ['wide', 'plain', 3604.667],
  ['wide', 'plain', 3784.417], ['wide', 'plain', 3794.167],
  ['stacked', 'all', 2.167], ['stacked', 'all', 3.867], ['stacked', 'all', 9.167], ['stacked', 'all', 9.367],
  ['stacked', 'all', 304.417], ['stacked', 'all', 309.167], ['stacked', 'all', 904.767], ['stacked', 'all', 907.167],
  ['stacked', 'all', 1804.567], ['stacked', 'all', 1806.167],
  ['stacked', 'plain', 9.167], ['stacked', 'plain', 904.767], ['stacked', 'plain', 3604.667], ['stacked', 'plain', 3784.417],
  ['wide', 'two', 9.367], ['wide', 'two', 309.167], ['wide', 'two', 907.167], ['wide', 'two', 1806.167],
  ['wide', 'three', 309.167], ['wide', 'three', 1806.167],
  ['stacked', 'two', 9.367], ['stacked', 'two', 309.167], ['stacked', 'two', 1806.167],
  ['stacked', 'three', 309.167], ['stacked', 'three', 1806.167]
];
// ...and as a call starts: [layout, plan, how long FREE had been up]
const WORLD_PRESSES = [['wide', 'all', 9.367], ['wide', 'plain', 9.167], ['stacked', 'all', 9.367]];

const JOBS = CASES.map((c) => ['wide', ...c, timer])
  .concat(STACKED_CASES.map((c) => ['stacked', ...c, timer]))
  .concat(CALENDAR_CASES.map(([s, p, e, k]) => ['wide', s, p, e, k ? TIMERS[k] : undefined]))
  .concat(STACKED_CALENDAR_CASES.map(([s, p, e, k]) => ['stacked', s, p, e, k ? TIMERS[k] : undefined]))
  .concat(NEARBY_CASES.map(([word, layout, e]) => [layout, 'nearby', 'free', e, undefined, word]))
  .concat(WORLD_CASES.map(([layout, plan, e]) => [layout, 'free', 'call', e, undefined, undefined, { plan, prevFor: 0 }]))
  .concat(WORLD_PRESSES.map(([layout, plan, up]) => [layout, 'call', 'free', 0.05, timer, undefined, { plan, prevFor: up }]));
const size = (layout) => (layout === 'wide' ? E.COLS * E.ROWS : E.STACKED.cols * E.STACKED.rows) * 3;

const buf = fs.readFileSync(process.argv[2]);
const total = JOBS.reduce((sum, [layout]) => sum + size(layout), 0);
if (buf.length !== total * 8) { console.error('size mismatch', buf.length, 'expected', total * 8); process.exit(2); }

let worst = 0, failed = 0, offset = 0;
JOBS.forEach(([layout, state, prev, e, tm, word, world]) => {
  const stacked = layout === 'stacked';
  const f = stacked ? new E.Frame(E.STACKED.cols, E.STACKED.rows) : new E.Frame();
  // a word of its own must be the one drawn, not NEARBY in its place
  if (E.setNearbyWord(word) !== (word || E.NEARBY)) { console.error('the sign won\'t take', word); process.exit(2); }
  if (world) {
    (stacked ? E.renderStackedWorld : E.renderWorld)(f, 1000 + e, state, prev, 1000, clock, tm, WORLD_PLANS[world.plan], world.prevFor);
  } else {
    (stacked ? E.renderStacked : E.render)(f, 1000 + e, state, prev, 1000, clock, tm);
  }
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
  console.log(`${layout.padEnd(8)} ${((world ? 'world ' + world.plan + ' ' : '') + (word ? word + ' ' : '') + state + ' <- ' + (prev || '-')).padEnd(14)} t=${String(e).padEnd(5)} max diff ${(maxd * 255).toFixed(4)}/255 ${bad ? 'FAIL ' + bad + ' LEDs ' + led : 'ok'}`);
  if (bad) failed++;
});
console.log(failed ? `\n${failed} of ${JOBS.length} frames differ` : `\nall ${JOBS.length} frames match (worst ${(worst * 255).toFixed(5)}/255)`);
process.exit(failed ? 1 : 0);
