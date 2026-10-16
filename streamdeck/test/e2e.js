/*
 * The built plugin against a fake Stream Deck and a fake Busy Bar Sign:
 * it registers, draws the key in the sign's colour on the second, toggles
 * Do Not Disturb on a press (with a tick when the sign can't show it),
 * mutes and leaves a meeting from the Mute and Leave keys (a held Leave
 * key only on a hold), lights the away keys (Back In ten minutes a press,
 * held to end), says APP OFF and warns on a press when the app's gone,
 * comes back with it, and stops asking once its keys are gone.
 *
 *   npm run build && node test/e2e.js
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import http from 'node:http';
import path from 'node:path';
import zlib from 'node:zlib';
import { WebSocketServer } from 'ws';

const plugin = path.join(import.meta.dirname, '..', 'com.woodall.busybarsign.sdPlugin');
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const timeout = (ms, what) => new Promise((_, reject) => setTimeout(() => reject(new Error(`timed out: ${what}`)), ms));

// ---- the fake app: the API in Sources/LocalAPI.swift
const app = { state: 'free', moment: null, dnd: false, meeting: null, away: null, pressWorks: true, requests: [] };
const AWAY_KEYS = { '/away/wandering': 'wandering', '/away/lunch': 'lunch', '/away/back-in': 'backIn' };
function appHandler(req, res) {
  app.requests.push({ method: req.method, url: req.url, headers: req.headers, at: Date.now() });
  let pressed = null;
  if (req.method === 'POST' && req.url === '/dnd/toggle') {
    app.dnd = !app.dnd;
    if (app.state !== 'call') app.state = app.dnd ? 'dnd' : 'free';      // a call outranks it
  } else if (req.method === 'POST' && req.url === '/meeting/mute') {
    pressed = { ok: app.pressWorks && !!app.meeting, message: 'Pressed Teams’s own mute button.' };
    if (pressed.ok) app.meeting.muted = !app.meeting.muted;
  } else if (req.method === 'POST' && (req.url === '/meeting/leave' || req.url === '/meeting/end')) {
    pressed = { ok: !!app.meeting, message: req.url === '/meeting/end' ? 'Ended it for everyone.' : 'Pressed Teams’s own leave button.' };
    app.meeting = null;
  } else if (req.method === 'POST' && req.url === '/away/end') {
    app.away = null;
  } else if (req.method === 'POST' && AWAY_KEYS[req.url]) {
    const key = AWAY_KEYS[req.url];
    if (key === 'backIn') {
      app.away = { kind: 'backIn', until: (app.away && app.away.kind === 'backIn' ? app.away.until : Date.now()) + 600000 };
    } else {
      app.away = app.away && app.away.kind === key ? null : { kind: key };
    }
  } else if (!(req.method === 'GET' && req.url === '/status')) {
    res.writeHead(404).end();
    return;
  }
  const body = JSON.stringify(Object.assign({ dnd: app.dnd, state: app.state }, app.moment ? { moment: app.moment } : {},
    app.meeting ? { meeting: app.meeting } : {}, app.away ? { away: app.away } : {}, pressed ? { pressed } : {}));
  res.writeHead(200, { 'Content-Type': 'application/json', Connection: 'close' }).end(body);
}
let appServer = http.createServer(appHandler);
await new Promise((r) => appServer.listen(0, '127.0.0.1', r));
const appPort = appServer.address().port;

// ---- the fake Stream Deck
const wss = new WebSocketServer({ port: 0, host: '127.0.0.1' });
await new Promise((r) => wss.once('listening', r));
const sent = [];                // what the plugin sent, oldest first
let socket, onMessage = () => {};
wss.on('connection', (ws) => {
  socket = ws;
  ws.on('message', (data) => { const m = JSON.parse(data); m.at = Date.now(); sent.push(m); onMessage(m); });
});
const next = (pred, ms, what) => Promise.race([new Promise((resolve) => {
  onMessage = (m) => { if (pred(m)) { onMessage = () => {}; resolve(m); } };
}), timeout(ms, what)]);
const toPlugin = (m) => socket.send(JSON.stringify(m));

const info = {
  application: { font: '.AppleSystemUIFont', language: 'en', platform: 'mac', platformVersion: '15.0', version: '7.1.0.22000' },
  plugin: { uuid: 'com.woodall.busybarsign', version: '1.0.0.0' },
  devicePixelRatio: 2, colors: {},
  devices: [{ id: 'deck', name: 'Stream Deck', size: { columns: 5, rows: 3 }, type: 0 }]
};
const child = spawn(process.execPath, ['bin/plugin.js', '-port', String(wss.address().port), '-pluginUUID', 'abc123',
  '-registerEvent', 'registerPlugin', '-info', JSON.stringify(info)],
  { cwd: plugin, env: Object.assign({}, process.env, { BUSY_BAR_SIGN_PORT: String(appPort) }), stdio: ['ignore', 'inherit', 'inherit'] });
let failed = false;
child.on('exit', (code) => { if (!done) { failed = true; console.error('plugin exited early with', code); } });
let done = false;

/* The colour of the pill's middle, from a setImage picture: 'red', 'green', 'blue', 'amber', 'grey' or 'dark'. */
function pillColour(dataURL) {
  const buf = Buffer.from(dataURL.replace(/^data:image\/png;base64,/, ''), 'base64');
  const idat = [];
  for (let at = 8; at < buf.length;) {
    const len = buf.readUInt32BE(at);
    if (buf.toString('ascii', at + 4, at + 8) === 'IDAT') idat.push(buf.subarray(at + 8, at + 8 + len));
    at += 12 + len;
  }
  const raw = zlib.inflateSync(Buffer.concat(idat)), x = 2 * 4 + 2, y = 3 * 4 + 2;     // LED (2, 3): pill, clear of the type
  const [r, g, b] = [0, 1, 2].map((c) => raw[y * (144 * 3 + 1) + 1 + x * 3 + c]);
  if (Math.max(r, g, b) < 60) return 'dark';
  if (r > 150 && g > 100 && b < 80) return 'amber';
  if (Math.abs(r - g) < 30 && Math.abs(g - b) < 30) return 'grey';
  return r >= g && r >= b ? 'red' : g >= b ? 'green' : 'blue';
}
/* A picture on a key, sent since message `since` or yet to come. */
const imageOn = (context, colour, ms, what, since = sent.length) => {
  const pred = (m) => m.event === 'setImage' && m.context === context && pillColour(m.payload.image) === colour;
  const already = sent.slice(since).find(pred);
  return already ? Promise.resolve(already) : next(pred, ms, what);
};
const image = (colour, ms, what) => imageOn('k1', colour, ms, what);

try {
  const reg = await next((m) => m.event === 'registerPlugin', 5000, 'registration');
  assert.equal(reg.uuid, 'abc123');

  // a Status key appears: FREE, green
  const appear = { action: 'com.woodall.busybarsign.status', context: 'k1', device: 'deck', event: 'willAppear',
    payload: { controller: 'Keypad', coordinates: { column: 0, row: 0 }, isInMultiAction: false, settings: {}, state: 0 } };
  toPlugin(appear);
  await image('green', 3000, 'FREE');
  console.log('ok  draws FREE in green');

  // asks on the second, without an Origin, as 127.0.0.1
  const gets = app.requests.filter((r) => r.method === 'GET');
  assert.ok(gets.length > 0);
  assert.equal(gets[0].headers.host, `127.0.0.1:${appPort}`);
  assert.equal(gets[0].headers.origin, undefined);

  // a countdown changes the picture every second, just after the second turns
  app.state = 'call'; app.moment = { at: Date.now() + 47 * 60000, kind: 'countdown' };
  await image('red', 3000, 'ON A CALL');
  const from = sent.length;
  await wait(3200);
  const ticks = sent.slice(from).filter((m) => m.event === 'setImage');
  assert.ok(ticks.length >= 3, `${ticks.length} pictures in 3.2 s of countdown`);
  const late = app.requests.slice(-3).map((r) => r.at % 1000);
  assert.ok(late.every((ms) => ms < 300), `asked at ${late.join(', ')} ms past the second`);
  console.log('ok  counts down once a second, on the second');

  // a press, not on a call: Do Not Disturb, blue; again: FREE
  app.state = 'free'; app.moment = null;
  await image('green', 3000, 'FREE again');
  const press = { action: 'com.woodall.busybarsign.status', context: 'k1', device: 'deck', event: 'keyDown',
    payload: { coordinates: { column: 0, row: 0 }, isInMultiAction: false, settings: {}, state: 0 } };
  toPlugin(press);
  await image('blue', 2000, 'DND after a press');
  const post = app.requests.find((r) => r.method === 'POST');
  assert.equal(post.url, '/dnd/toggle');
  assert.equal(post.headers.origin, undefined);
  toPlugin(press);
  await image('green', 2000, 'FREE after a second press');
  console.log('ok  a press starts and ends Do Not Disturb');

  // on a call the sign can't show it: a tick instead
  app.state = 'call';
  await image('red', 3000, 'on a call');
  toPlugin(press);
  await next((m) => m.event === 'showOk' && m.context === 'k1', 2000, 'showOk on a call');
  assert.equal(app.dnd, true);
  console.log('ok  on a call, a press shows a tick');

  // the Mute and Leave keys: dark outside a meeting
  const meetingKey = (kind, context, settings) => ({ action: `com.woodall.busybarsign.${kind}`, context, device: 'deck',
    payload: { controller: 'Keypad', coordinates: { column: 1, row: 0 }, isInMultiAction: false, settings, state: 0 } });
  const mute = meetingKey('mute', 'm1', {});
  const leave = meetingKey('leave', 'l1', { confirm: 'hold' });
  app.state = 'free';
  toPlugin(Object.assign({ event: 'willAppear' }, mute));
  await imageOn('m1', 'dark', 3000, 'Mute key outside a meeting');
  toPlugin(Object.assign({ event: 'willAppear' }, leave));
  await imageOn('l1', 'dark', 3000, 'Leave key outside a meeting');
  console.log('ok  Mute and Leave keys are dark outside a meeting');

  // in a meeting: LIVE in green, LEAVE in red; a press mutes, at once
  app.state = 'call';
  app.meeting = { app: 'teams', muted: false, canLeave: true };
  const joined = sent.length;
  await imageOn('m1', 'green', 3000, 'LIVE', joined);
  await imageOn('l1', 'red', 3000, 'LEAVE', joined);
  const pressAt = sent.length;
  toPlugin(Object.assign({ event: 'keyDown' }, mute));
  await imageOn('m1', 'red', 1500, 'MUTED after a press', pressAt);
  assert.ok(app.requests.some((r) => r.method === 'POST' && r.url === '/meeting/mute' && r.headers.origin === undefined));
  console.log('ok  in a meeting: LIVE and LEAVE; a press mutes');

  // a press the app couldn't do warns
  app.pressWorks = false;
  toPlugin(Object.assign({ event: 'keyDown' }, mute));
  await next((m) => m.event === 'showAlert' && m.context === 'm1', 2000, 'showAlert when the press failed');
  app.pressWorks = true;
  console.log('ok  a press that didn\'t take warns');

  // Leave, set to hold: a tap doesn't leave; a hold does
  toPlugin(Object.assign({ event: 'keyDown' }, leave));
  await wait(100);
  toPlugin(Object.assign({ event: 'keyUp' }, leave));
  await wait(900);
  assert.ok(!app.requests.some((r) => r.url === '/meeting/leave'), 'a tap left the meeting');
  const held = sent.length;
  toPlugin(Object.assign({ event: 'keyDown' }, leave));
  await wait(750);
  toPlugin(Object.assign({ event: 'keyUp' }, leave));
  await imageOn('l1', 'dark', 2000, 'Leave key dark after leaving', held);
  assert.equal(app.requests.filter((r) => r.url === '/meeting/leave').length, 1);
  assert.equal(app.meeting, null);
  console.log('ok  a held Leave key leaves only when held');

  // Leave, on a press: leaves when let go; held a second, ends it for everyone
  const quick = meetingKey('leave', 'l2', {});
  toPlugin(Object.assign({ event: 'willAppear' }, quick));
  app.meeting = { app: 'zoom', muted: false, canLeave: true };
  await imageOn('l2', 'red', 3000, 'LEAVE on the press key');
  const posts = (url) => app.requests.filter((r) => r.method === 'POST' && r.url === url).length;
  toPlugin(Object.assign({ event: 'keyDown' }, quick));
  await wait(150);
  toPlugin(Object.assign({ event: 'keyUp' }, quick));
  await wait(400);
  assert.equal(posts('/meeting/leave'), 2, 'a press leaves, on release');
  assert.equal(posts('/meeting/end'), 0);
  app.meeting = { app: 'zoom', muted: false, canLeave: true };
  toPlugin(Object.assign({ event: 'keyDown' }, quick));
  await wait(1200);
  assert.equal(posts('/meeting/end'), 1, 'held a second, it ends the meeting for everyone');
  toPlugin(Object.assign({ event: 'keyUp' }, quick));
  await wait(300);
  assert.equal(posts('/meeting/leave'), 2, 'and letting go after doesn\'t leave as well');
  console.log('ok  a Leave key leaves on a press, and ends it for everyone when held a second');

  toPlugin(Object.assign({ event: 'willDisappear' }, mute));
  toPlugin(Object.assign({ event: 'willDisappear' }, leave));
  toPlugin(Object.assign({ event: 'willDisappear' }, quick));
  app.state = 'free';
  app.meeting = null;

  // the away keys: dimmed until pressed; Back In ten minutes a press, held to end
  const awayKey = (kind, context) => ({ action: `com.woodall.busybarsign.${kind}`, context, device: 'deck',
    payload: { controller: 'Keypad', coordinates: { column: 2, row: 1 }, isInMultiAction: false, settings: {}, state: 0 } });
  const backIn = awayKey('backin', 'b1'), lunch = awayKey('lunch', 'u1'), wandering = awayKey('wandering', 'w1');
  const appeared = sent.length;
  for (const key of [backIn, lunch, wandering]) toPlugin(Object.assign({ event: 'willAppear' }, key));
  await imageOn('b1', 'dark', 3000, 'Back In dimmed', appeared);
  await imageOn('u1', 'dark', 3000, 'Lunch dimmed', appeared);
  await imageOn('w1', 'dark', 3000, 'Wandering dimmed', appeared);
  const tap = async (key) => {
    toPlugin(Object.assign({ event: 'keyDown' }, key));
    await wait(80);
    toPlugin(Object.assign({ event: 'keyUp' }, key));
    await wait(150);
  };
  const pressedAt = Date.now(), lit = sent.length;
  for (let i = 0; i < 3; i++) await tap(backIn);
  await imageOn('b1', 'grey', 1500, 'Back In lit', lit);
  assert.equal(app.requests.filter((r) => r.method === 'POST' && r.url === '/away/back-in').length, 3);
  assert.ok(Math.abs(app.away.until - pressedAt - 30 * 60000) < 2000, 'three presses: half an hour');
  const heldAt = sent.length;
  toPlugin(Object.assign({ event: 'keyDown' }, backIn));
  await next((m) => m.event === 'showOk' && m.context === 'b1', 2000, 'a tick when Back In is held');
  toPlugin(Object.assign({ event: 'keyUp' }, backIn));
  await imageOn('b1', 'dark', 1500, 'Back In dimmed after a hold', heldAt);
  assert.equal(app.away, null);
  assert.equal(app.requests.filter((r) => r.method === 'POST' && r.url === '/away/back-in').length, 3, 'a hold adds no time');
  console.log('ok  Back In: ten minutes a press, held to end');

  const lunchAt = sent.length;
  await tap(lunch);
  await imageOn('u1', 'grey', 1500, 'Lunch lit', lunchAt);
  const swap = sent.length;
  await tap(wandering);
  await imageOn('w1', 'grey', 1500, 'Wandering lit', swap);
  await imageOn('u1', 'dark', 1500, 'Lunch dimmed once Wandering is on', swap);
  await tap(wandering);
  assert.equal(app.away, null, 'a second press ends it');
  for (const key of [backIn, lunch, wandering]) toPlugin(Object.assign({ event: 'willDisappear' }, key));
  console.log('ok  Lunch and Wandering go on and off, one at a time');

  // the app quits: APP OFF; a press warns; it comes back
  await new Promise((r) => { appServer.close(r); appServer.closeAllConnections(); });
  await image('dark', 3000, 'APP OFF');
  toPlugin(press);
  await next((m) => m.event === 'showAlert' && m.context === 'k1', 2000, 'showAlert with the app gone');
  appServer = http.createServer(appHandler);
  await new Promise((r) => appServer.listen(appPort, '127.0.0.1', r));
  app.state = 'free'; app.dnd = false;
  await image('green', 3000, 'back after the app returns');
  console.log('ok  says APP OFF while the app is away, and comes back');

  // the key goes: the plugin stops asking
  toPlugin(Object.assign({}, appear, { event: 'willDisappear' }));
  await wait(1500);
  const before = app.requests.length;
  await wait(2500);
  assert.equal(app.requests.length, before, 'still asking with no key showing');
  // and starts again when one returns
  toPlugin(appear);
  await image('green', 3000, 'drawn again');
  console.log('ok  stops asking with no key showing, and starts again');

  done = true;
  console.log('Stream Deck plugin: end to end passed');
} catch (e) {
  failed = true;
  console.error('FAIL', e.message);
} finally {
  done = true;
  child.kill();
  wss.close();
  appServer.close();
  appServer.closeAllConnections();
}
process.exit(failed ? 1 : 0);
