/*
 * Asks Busy Bar Sign, on this Mac, what the sign says
 * (Sources/LocalAPI.swift has the details).
 *
 *   getStatus()   {"state":"call","moment":{"at":1760000000000,"kind":"countdown"},"dnd":false,
 *                  "meeting":{"app":"teams","muted":true,"canLeave":true}}
 *   toggleDND()   as a double-click on the bar; resolves to the new status
 *   pressMute()   mutes or unmutes the Teams or Zoom meeting;
 *   pressLeave()  leaves it;
 *   pressEnd()    ends it for everyone if it's a Zoom meeting you host (else
 *                 leaves); each resolves to { view, pressed: { ok, message } }
 *   pressAway(k)  an away key: 'nearby' or 'lunch' on or off, 'backIn'
 *                 ten minutes more; resolves to the new status
 *   endAway()     back at your desk
 */
import http from 'node:http';

export const PORT = Number(process.env.BUSY_BAR_SIGN_PORT) || 47811;

/* The app's answer as the keys use it. */
export function viewOf(status) {
  if (typeof status.state !== 'string') throw new Error('no state');
  // muted on a call: the app says "call" with muted alongside; the key draws it as the bar does
  const state = status.state === 'call' && status.muted === true ? 'callMuted' : status.state;
  const m = status.meeting;
  const meeting = m && typeof m.app === 'string'
    ? { app: m.app, muted: typeof m.muted === 'boolean' ? m.muted : null, canLeave: !!m.canLeave }
    : null;
  const a = status.away;
  const away = a && typeof a.kind === 'string' ? { kind: a.kind, until: typeof a.until === 'number' ? a.until : null } : null;
  return { state: state, moment: status.moment || null, dnd: !!status.dnd, meeting: meeting, away: away };
}

function ask(method, path, timeout) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1', port: PORT, method, path, agent: false, timeout: timeout,
      headers: { 'Content-Length': 0 }
    }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (part) => { body += part; });
      res.on('end', () => {
        if (res.statusCode !== 200) return reject(new Error(`${method} ${path}: HTTP ${res.statusCode}`));
        try {
          const status = JSON.parse(body);
          resolve({ view: viewOf(status), pressed: status.pressed || null });
        } catch (e) {
          reject(new Error(`${method} ${path}: unreadable answer (${e.message})`));
        }
      });
    });
    req.on('timeout', () => req.destroy(new Error(`${method} ${path}: no answer`)));
    req.on('error', reject);
    req.end();
  });
}

export const getStatus = () => ask('GET', '/status', 800).then((a) => a.view);
export const toggleDND = () => ask('POST', '/dnd/toggle', 800).then((a) => a.view);
// a press can take a few seconds: the meeting's button, then perhaps its shortcut
export const pressMute = () => ask('POST', '/meeting/mute', 12000);
export const pressLeave = () => ask('POST', '/meeting/leave', 12000);
export const pressEnd = () => ask('POST', '/meeting/end', 12000);
const AWAY_PATHS = { nearby: '/away/nearby', lunch: '/away/lunch', backIn: '/away/back-in' };
export const pressAway = (kind) => ask('POST', AWAY_PATHS[kind], 800).then((a) => a.view);
export const endAway = () => ask('POST', '/away/end', 800).then((a) => a.view);
