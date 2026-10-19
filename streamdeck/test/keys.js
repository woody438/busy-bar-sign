/*
 * The key's picture: every state the bar has is drawn, its words fit, and
 * the line under the pill says what the bar's right-hand side says. The
 * Mute and Leave keys: the right face for what the app says, every face
 * inside the panel, and the app's answer read as the keys use it.
 */
import assert from 'node:assert/strict';
import zlib from 'node:zlib';
import { AWAY_KINDS, awayFace, awayKeyImage, drawAwayKey, N, SIZE, STATES, clockOf, drawKey, drawMeetingKey, keyImage, keyText,
  leaveFace, MEETING_FACES, meetingKeyImage, muteFace, timerOf } from '../src/key.js';
import { viewOf } from '../src/app.js';

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
check(() => assert.deepEqual(say('callMuted', { at: now + 47 * min + 12000 - 30, kind: 'countdown' }).lines, ['ON A', 'CALL']));
check(() => assert.deepEqual(say('late', { at: now - 80030, kind: 'countUp' }), { lines: ['LATE'], detail: '+01:20', blink: false }));
check(() => assert.deepEqual(say('lateMtg', { at: now - 80030, kind: 'countUp' }), { lines: ['LATE', 'MTG'], detail: '+01:20', blink: false }));
check(() => assert.deepEqual(say('callTbc', { at: now + 250000, kind: 'countdown' }).lines, ['CALL', 'TBC']));
check(() => assert.deepEqual(say('busyTbc', { at: new Date(2026, 9, 6, 15, 30).getTime(), kind: 'fixed' }),
  { lines: ['TBC', 'TILL'], detail: '15:30', blink: false }));
check(() => assert.equal(say('freeTil', { at: new Date(2026, 9, 6, 15, 0).getTime(), kind: 'fixed' }).detail, '15:00'));
check(() => assert.equal(say('ooo', null).detail, '14:32'));
check(() => assert.deepEqual(say('onSite', null), { lines: ['ON', 'SITE'], detail: '14:32', blink: true }));
check(() => assert.deepEqual(say('lunch', { at: now + 45 * min + 12000 - 30, kind: 'countdown' }), { lines: ['LUNCH'], detail: '45:12', blink: true }));
check(() => assert.deepEqual(say('lunch', null), { lines: ['LUNCH'], detail: '14:32', blink: true }));
check(() => assert.deepEqual(say('nearby', null), { lines: ['NEAR-', 'BY'], detail: '14:32', blink: true }));
check(() => assert.deepEqual(say('backIn', { at: now + 29 * min + 41000 - 30, kind: 'countdown' }),
  { lines: ['BACK', 'IN'], detail: '29:41', blink: true }));

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

// the app's answer, as the keys read it
check(() => assert.deepEqual(viewOf({ state: 'call', muted: true, dnd: false, meeting: { app: 'teams', muted: true, canLeave: true } }),
  { state: 'callMuted', moment: null, dnd: false, meeting: { app: 'teams', muted: true, canLeave: true }, away: null }));
check(() => assert.deepEqual(viewOf({ state: 'call', dnd: false, meeting: { app: 'zoom', canLeave: true } }).meeting,
  { app: 'zoom', muted: null, canLeave: true }));
check(() => assert.equal(viewOf({ state: 'free', dnd: false }).meeting, null));
check(() => assert.throws(() => viewOf({ dnd: false })));
check(() => assert.deepEqual(viewOf({ state: 'backIn', dnd: false, away: { kind: 'backIn', until: 1760000600000 } }).away,
  { kind: 'backIn', until: 1760000600000 }));
check(() => assert.deepEqual(viewOf({ state: 'lunch', dnd: false, away: { kind: 'lunch' } }).away, { kind: 'lunch', until: null }));
check(() => assert.equal(viewOf({ state: 'free', dnd: false }).away, null));

// the away keys: lit while theirs is the key that's on, dimmed while it isn't; nothing cut off
const awayView = (kind, until) => ({ state: 'free', moment: null, dnd: false, meeting: null, away: kind ? { kind, until: until || null } : null });
check(() => assert.equal(awayFace('lunch', null), 'off'));
check(() => assert.equal(awayFace('lunch', awayView(null)), 'idle'));
check(() => assert.equal(awayFace('lunch', awayView('nearby')), 'idle'));
check(() => assert.equal(awayFace('lunch', awayView('lunch')), 'on'));
const brightness = (frame) => { let sum = 0; for (let i = 0; i < frame.px.length; i++) sum += frame.px[i]; return sum; };
for (const kind of AWAY_KINDS) {
  const at = new Date(now);
  const on = drawAwayKey(kind, awayView(kind, now + 9 * 3600000 + 59 * min), at), idle = drawAwayKey(kind, awayView(null), at);
  check(() => assert.ok(brightness(on) > brightness(idle) * 1.3, `${kind}: lit when on`));
  // (dimmed, the type's too faint to find; it's set as when it's lit)
  const cols = litColumns(on);
  check(() => assert.ok(cols.size > 0 && Math.min(...cols) >= 1 && Math.max(...cols) <= N - 2, `${kind}: cut off`));
}
check(() => assert.notEqual(awayKeyImage('backIn', awayView('backIn', now + 10 * min), new Date(now)),
  awayKeyImage('backIn', awayView('backIn', now + 20 * min), new Date(now))));

// the Mute and Leave keys' faces
const inMeeting = (muted, canLeave = true) => ({ state: 'call', moment: null, dnd: false, meeting: { app: 'teams', muted, canLeave } });
check(() => assert.equal(muteFace(null), 'off'));
check(() => assert.equal(muteFace({ state: 'free', moment: null, dnd: false, meeting: null }), 'idle'));
check(() => assert.equal(muteFace(inMeeting(false)), 'live'));
check(() => assert.equal(muteFace(inMeeting(true)), 'muted'));
check(() => assert.equal(muteFace(inMeeting(null)), 'unknown'));
check(() => assert.equal(leaveFace(null), 'off'));
check(() => assert.equal(leaveFace(inMeeting(false)), 'active'));
check(() => assert.equal(leaveFace(inMeeting(false, false)), 'active'));   // a press leaves through the shortcut
check(() => assert.equal(leaveFace({ state: 'free', moment: null, dnd: false, meeting: null }), 'idle'));
for (const face of [...MEETING_FACES.map((f) => f.split(':')), ['leave', 'active', true], ['mute', 'off']]) {
  const frame = drawMeetingKey(...face);
  let lit = 0;
  const cols = new Set();
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    const [r, g, b] = frame.get(x, y);
    if (r + g + b > 0.3) lit++;
    if (y > 22 && r + g + b > 2.4) cols.add(x);         // the word beneath the pill
  }
  check(() => assert.ok(lit > 100, `${face.join(':')}: drawn`));
  if (cols.size) check(() => assert.ok(Math.min(...cols) >= 1 && Math.max(...cols) <= N - 2, `${face.join(':')}: word cut off`));
}
check(() => assert.equal(meetingKeyImage('mute', 'live'), meetingKeyImage('mute', 'live')));
check(() => assert.notEqual(meetingKeyImage('mute', 'live'), meetingKeyImage('mute', 'muted')));
check(() => assert.notEqual(meetingKeyImage('leave', 'active'), meetingKeyImage('leave', 'active', true)));

console.log(`key drawing: ${checks} checks passed`);
