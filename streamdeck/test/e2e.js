/*
 * The built plugin against a fake Stream Deck and a fake Busy Bar Sign:
 * it registers, draws the key in the sign's colour on the second, toggles
 * Do Not Disturb on a press (with a tick when the sign can't show it),
 * says APP OFF and warns on a press when the app's gone, comes back with
 * it, and stops asking once its key is gone.
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
const app = { state: 'free', moment: null, dnd: false, requests: [] };
function appHandler(req, res) {
  app.requests.push({ method: req.method, url: req.url, headers: req.headers, at: Date.now() });
  if (req.method === 'POST' && req.url === '/dnd/toggle') {
    app.dnd = !app.dnd;
    if (app.state !== 'call') app.state = app.dnd ? 'dnd' : 'free';      // a call outranks it
  } else if (!(req.method === 'GET' && req.url === '/status')) {
    res.writeHead(404).end();
    return;
  }
  const body = JSON.stringify(Object.assign({ dnd: app.dnd, state: app.state }, app.moment ? { moment: app.moment } : {}));
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

/* The colour of the pill's middle, from a setImage picture: 'red', 'green', 'blue', 'amber' or 'dark'. */
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
  return r >= g && r >= b ? 'red' : g >= b ? 'green' : 'blue';
}
const image = (colour, ms, what) => next((m) => m.event === 'setImage' && m.context === 'k1' && pillColour(m.payload.image) === colour, ms, what);

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
