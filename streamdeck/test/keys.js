/*
 * The key's picture: every state the bar has is drawn, its words fit, and
 * the line under the pill says what the bar's right-hand side says.
 */
import assert from 'node:assert/strict';
import zlib from 'node:zlib';
import { N, SIZE, STATES, clockOf, drawKey, keyImage, keyText, timerOf } from '../src/key.js';

const E = globalThis.BusyEngine;
let checks = 0;
const check = (fn) => { fn(); checks++; };

// the key knows every state the engine draws
check(() => assert.deepEqual([...STATES].sort(), [...E.STATES].sort()));

// the timer, as BarMoment.timer(at:) makes it
const now = new Date(2026, 9, 6, 14, 32, 27, 30).getTime();
check(() => assert.deepEqual(timerOf({ at: now + 90500, kind: 'countdown' }, now), { left: 90.5, h: 14, m: 33 }));
check(() => assert.deepEqual(timerOf({ at: now - 80000, kind: 'countUp' }, now), { left: 80, h: 14, m: 31 }));
check(() => assert.deepEqual(timerOf({ at: now + 3600000, kind: 'fixed' }, now), { left: 0, h: 15, m: 32 }));
check(() => assert.equal(timerOf(null, now), null));

// what the key says
const clock = clockOf(new Date(now));
const say = (state, moment) => keyText(state, clock, timerOf(moment, now));
const min = 60000;
check(() => assert.deepEqual(say('call', { at: now + 47 * min + 12000 - 30, kind: 'countdown' }),
  { lines: ['ON A', 'CALL'], detail: '47:12', blink: true }));
check(() => assert.equal(say('meeting', { at: now + 65 * min, kind: 'countdown' }).detail, '1H05'));
check(() => assert.deepEqual(say('free', null), { lines: ['FREE'], detail: '14:32', blink: true }));
check(() => assert.deepEqual(say('late', { at: now - 80030, kind: 'countUp' }), { lines: ['LATE'], detail: '+01:20', blink: false }));
check(() => assert.deepEqual(say('callTbc', { at: now + 250000, kind: 'countdown' }).lines, ['CALL', 'TBC']));
check(() => assert.deepEqual(say('busyTbc', { at: new Date(2026, 9, 6, 15, 30).getTime(), kind: 'fixed' }),
  { lines: ['TBC', 'TILL'], detail: '15:30', blink: false }));
check(() => assert.equal(say('freeTil', { at: new Date(2026, 9, 6, 15, 0).getTime(), kind: 'fixed' }).detail, '15:00'));
check(() => assert.equal(say('ooo', null).detail, '14:32'));

// nothing is cut off: every LED lit lies inside the panel's margin...
function litColumns(frame) {
  const cols = new Set();
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    const [r, g, b] = frame.get(x, y);
    if (r + g + b > 2.4) cols.add(x);               // white type
  }
  return cols;
}
const moments = [null, { at: now + 9 * 3600000 + 59 * min, kind: 'countdown' }, { at: now - 99 * min, kind: 'countUp' },
  { at: now + 12 * 3600000, kind: 'fixed' }];
for (const state of STATES) for (const moment of moments) {
  const cols = litColumns(drawKey({ state, moment, dnd: false }, new Date(now + 1000)));   // even second: colons lit
  check(() => assert.ok(cols.size > 0 && Math.min(...cols) >= 1 && Math.max(...cols) <= N - 2,
    `${state} ${JSON.stringify(moment)}: type from column ${Math.min(...cols)} to ${Math.max(...cols)}`));
}

// ...and the picture is a 144 px PNG, the same each time for the same moment
function readPNG(dataURL) {
  const buf = Buffer.from(dataURL.replace(/^data:image\/png;base64,/, ''), 'base64');
  assert.equal(buf.readUInt32BE(16), SIZE);
  assert.equal(buf.readUInt32BE(20), SIZE);
  let idat = [], at = 8;
  while (at < buf.length) {
    const len = buf.readUInt32BE(at), type = buf.toString('ascii', at + 4, at + 8);
    if (type === 'IDAT') idat.push(buf.subarray(at + 8, at + 8 + len));
    at += 12 + len;
  }
  return zlib.inflateSync(Buffer.concat(idat));
}
const image = keyImage({ state: 'dnd', moment: { at: now + 600000, kind: 'countdown' }, dnd: true }, new Date(now));
check(() => assert.equal(readPNG(image).length, (SIZE * 3 + 1) * SIZE));
check(() => assert.equal(image, keyImage({ state: 'dnd', moment: { at: now + 600000, kind: 'countdown' }, dnd: true }, new Date(now))));
check(() => assert.notEqual(image, keyImage(null, new Date(now))));
check(() => assert.doesNotThrow(() => keyImage({ state: 'notAState', moment: null, dnd: false }, new Date(now))));

console.log(`key drawing: ${checks} checks passed`);
