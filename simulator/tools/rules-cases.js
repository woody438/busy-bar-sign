/*
 * Writes the status rules' decisions as JSON, for the Swift port to match:
 *   node simulator/tools/rules-cases.js out.json
 * The sample day every 15 seconds (with and without the manual controls),
 * and the edge cases from rules-check.js. Checks/rules/main.swift reads it.
 */
const fs = require('fs'), path = require('path');
require(path.join(__dirname, '..', 'rules.js'));
require(path.join(__dirname, '..', 'day.js'));
const R = globalThis.BusyRules, D = globalThis.BusyDay;

const M = 60000;
const cases = [];
function add(input) {
  const out = R.decide(input);
  cases.push({ input: input, expect: { state: out.state, left: out.left === undefined ? null : out.left,
    at: out.at === undefined ? null : out.at } });
}

// the sample day
const day = D.build(0);
for (let t = D.at(0, D.START); t <= D.at(0, D.END); t += 15000) {
  add({ now: t, override: 'auto', dndUntil: null, events: day.events, micSessions: day.micSessions });
}
for (const t of ['08:40', '10:15', '12:40', '13:05', '17:40']) {
  for (const override of ['onCall', 'free']) add({ now: D.at(0, t), override: override, dndUntil: null, events: day.events, micSessions: day.micSessions });
  add({ now: D.at(0, t), override: 'auto', dndUntil: D.at(0, t) + 20 * M, events: day.events, micSessions: day.micSessions });
}

// edge cases
const ev = (o) => Object.assign({ id: o.title || 'e', title: '', start: 0, end: 1, attendees: 0, availability: 'busy', allDay: false,
  notes: '', location: '', url: '', cancelled: false }, o);
const call = (id, s, e, o) => ev(Object.assign({ id: id, title: id, start: s * M, end: e * M, attendees: 3, location: 'Microsoft Teams Meeting' }, o || {}));
const mic = (list) => list.map(([s, e]) => ({ start: s * M, end: e == null ? null : e * M }));
const scenario = (events, sessions, times, extra) => {
  for (const t of times) add(Object.assign({ now: t * M, override: 'auto', dndUntil: null, events: events, micSessions: mic(sessions || []) }, extra || {}));
};
scenario([call('a', 600, 660), call('b', 660, 690)], [[598, 665]], [599, 630, 663, 664.9, 666, 680, 691]);
scenario([call('a', 600, 660)], [[596, 630]], [596, 610, 640, 659.9, 660]);
scenario([call('t', 598, 630, { availability: 'tentative' }), call('c', 602, 630)], [], [585, 595, 599, 601, 605, 629]);
scenario([call('a', 600, 660), call('b', 652, 700)], [[600, 640]], [645, 651, 653, 662]);
scenario([call('a', 600, 660), call('b', 610, 640)], [], [601, 603, 611]);
scenario([ev({ title: 'm', start: 600 * M, end: 660 * M, attendees: 3 }), call('b', 610, 640)], [], [605, 612, 650]);
scenario([call('t', 600, 630, { availability: 'tentative' })], [], [589, 595, 601, 629.5]);
scenario([ev({ title: 'm', start: 600 * M, end: 660 * M, attendees: 3, availability: 'tentative' })], [], [595, 605]);
scenario([ev({ title: 'Drive', start: 590 * M, end: 605 * M }), call('c', 600, 630)], [], [595, 604, 606]);
scenario([ev({ title: 'NO MEETINGS', start: 540 * M, end: 720 * M }), call('c', 600, 630)], [[612, 625]], [560, 595, 605, 615, 626, 640]);
const chain = [call('a', 600, 660), call('b', 660, 690), ev({ title: 'm', start: 695 * M, end: 720 * M, attendees: 2 }), call('d', 730, 760)];
scenario(chain, [[600, null]], [600, 630, 662, 700, 735]);
scenario(chain, [], [630, 700, 725]);
scenario([], [[600, null]], [630]);
scenario([call('a', 600, 660), ev({ title: 'Lunch', start: 660 * M, end: 720 * M })], [[600, null]], [630, 665]);
scenario([ev({ title: 'Déjeuner', start: 590 * M, end: 650 * M })], [], [600], { config: { keywords: { lunch: ['déjeuner'] } } });
scenario([ev({ title: 'Déjeuner', start: 590 * M, end: 650 * M })], [], [600]);

// classification: one event at a time, half way through it
const ONE = [
  { attendees: 3, notes: 'https://eur02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2F' },
  { attendees: 3, notes: 'https%3A%2F%2Fteams%2Emicrosoft%2Ecom%2Fl%2F' },
  { attendees: 3, location: 'Microsoft Teams Meeting' }, { attendees: 3, location: 'Réunion Microsoft Teams' },
  { attendees: 3, location: 'Microsoft Teams Meeting; UK Birmingham Room' },
  { attendees: 2, notes: 'Join: https://protect.checkpoint.com/v2/r02/___https://meet.google.com/sbb-mnif-nvn___' },
  { attendees: 2, notes: 'https://us02web.zoom.us/j/123' }, { notes: 'https://teams.microsoft.com/l/meetup-join/x' },
  { attendees: 4, location: 'Teal Meeting Room (GB)' }, { title: 'Lunch' }, { title: 'team LUNCH out' }, { title: 'NO MEETINGS' },
  { title: 'Focus time' }, { title: 'Call - Linda (home lending)' }, { title: 'Talk to someone, call them' }, { title: 'Recall stock' },
  { title: '✈ CDG→LHR • BA 303' }, { title: '✈️ BNA→JFK' }, { title: 'PRVN CrossFit' },
  { attendees: 9, availability: 'free', location: 'Microsoft Teams Meeting' }, { attendees: 9, cancelled: true },
  { title: 'Canceled: Supplier sync', attendees: 5, location: 'Microsoft Teams Meeting' }, { title: 'Cancelled: Lunch' },
  { title: 'Paris', availability: 'ooo' }, { title: 'PARIS', allDay: true }, { title: 'Maybe', allDay: true, availability: 'tentative' },
  { attendees: 2, availability: 'tentative', location: 'Microsoft Teams Meeting' }, { title: 'Lunch', availability: 'tentative' },
  { title: 'Out of office - Ian' }, { title: 'OOO' }, { title: 'Woody OOO pm' }, { title: 'Spartan Day' }, { title: '' },
  { title: 'Call: Mum %F0%9F%98%80' }, { attendees: 1, url: 'https://zoom.us/j/9' }, { attendees: 1, notes: '%E2%9C%88 not a link' }
];
ONE.forEach((o, i) => scenario([ev(Object.assign({ id: 'one' + i, start: 600 * M, end: 660 * M }, o))], [], [590, 630]));

fs.writeFileSync(process.argv[2], JSON.stringify({ cases: cases }));
console.log('rule cases:', cases.length);
