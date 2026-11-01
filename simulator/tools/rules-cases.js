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
    at: out.at === undefined ? null : out.at, leftEvents: R.leftEvents(input) } });
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
for (const next of [[660, 690], [665, 700], [666, 700], [690, 720]]) {
  scenario([call('a', 600, 660), call('b', next[0], next[1])], [[600, 630]], [640, 659.9, 661]);
}
scenario([call('a', 600, 660), ev({ title: 'Lunch', start: 660 * M, end: 720 * M })], [[600, 630]], [640]);
scenario([call('a', 600, 660), call('x', 660, 690, { cancelled: true })], [[600, 630]], [640]);
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

// the away keys and the Mac locked, through the sample day and on their own
for (const t of ['08:40', '09:40', '10:15', '11:10', '12:40', '14:05', '14:47', '17:40']) {
  const at = D.at(0, t);
  for (const extra of [{ locked: true }, { locked: true, dndUntil: at + 20 * M }, { away: 'nearby' }, { away: 'lunch', locked: true },
    { away: 'backIn', awayUntil: at + 30 * M }, { away: 'backIn', awayUntil: at - M, locked: true }]) {
    add(Object.assign({ now: at, override: 'auto', dndUntil: null, events: day.events, micSessions: day.micSessions }, extra));
  }
}
scenario([], [], [600], { locked: true });
scenario([], [], [600, 625], { locked: true, dndUntil: 620 * M });
scenario([call('c', 600, 630)], [], [595, 603, 605], { locked: true });
scenario([call('a', 600, 660), call('b', 665, 700)], [[600, 630]], [640], { locked: true });
scenario([ev({ title: 'NO MEETINGS', start: 540 * M, end: 720 * M })], [], [600], { locked: true });
scenario([call('t', 600, 630, { availability: 'tentative' })], [], [595, 605], { locked: true });
for (const away of ['nearby', 'lunch']) {
  scenario([call('c', 600, 630), ev({ title: 'Lunch', start: 640 * M, end: 700 * M })], [[612, 625]], [595, 605, 615, 650], { away: away });
}
for (const locked of [false, true]) {
  scenario([call('c', 640, 670)], [], [600, 629.99, 630, 635], { away: 'backIn', awayUntil: 630 * M, locked: locked });
}
scenario([], [], [600], { away: 'backIn', awayUntil: null });
scenario([], [], [600], { away: 'lunch', override: 'free' });
scenario([], [], [600], { away: 'nearby', dndUntil: 620 * M });

// out on site, a call never joined, in person, and late for a meeting in a room
const venue = ev({ id: 'v', title: 'v', start: 600 * M, end: 660 * M, attendees: 3, location: 'The Ivy' });
const huddle = ev({ id: 'r', title: 'r', start: 600 * M, end: 660 * M, attendees: 3, location: 'LP Huddle' });
const office = ev({ id: 'o', title: 'o', start: 600 * M, end: 660 * M, attendees: 3, location: "Woody's office" });
scenario([venue], [], [595, 610, 659.9, 660]);
scenario([venue, call('c', 615, 640)], [[620, 630]], [610, 612, 625, 635]);
scenario([venue, ev({ id: 'p', title: 'Paris', start: 590 * M, end: 700 * M, availability: 'ooo' })], [], [610]);
scenario([ev({ id: 'd', title: 'ON SITE', start: 0, end: 1440 * M, allDay: true }), call('c', 600, 630)], [], [595, 610]);
scenario([call('h', 600, 660, { location: 'Microsoft Teams Meeting; LP Huddle' })], [], [595, 601, 615]);
scenario([call('a', 600, 660)], [], [609.9, 610, 630, 659.9, 660]);
scenario([call('a', 600, 660)], [], [620], { locked: true });
scenario([call('a', 600, 660), call('b', 630, 690)], [], [625, 632, 645, 670]);
scenario([ev({ title: 'NO MEETINGS', start: 540 * M, end: 720 * M }), call('a', 600, 660)], [], [620]);
for (const mic of [[], [[604, null]], [[604, 620]]]) {
  scenario([call('a', 600, 660)], mic, [595, 603, 610, 625], { inPerson: ['a'] });
}
scenario([call('a', 600, 660)], [], [603], { inPerson: ['b'] });
for (const extra of [{ active: true }, {}, { active: true, locked: true }, { active: true, inPerson: ['r'] }]) {
  scenario([huddle], [], [595, 600, 603, 609.9, 610], extra);
  scenario([huddle], [[601, 605]], [603, 608], extra);
}
scenario([ev({ id: 'r', title: 'r', start: 600 * M, end: 660 * M, attendees: 3, location: 'LP Huddle', availability: 'tentative' })],
  [], [603], { active: true });
scenario([office], [], [603], { active: true });
const nashville = ev({ id: 'n', title: 'n', start: 600 * M, end: 745 * M, attendees: 7, location: 'Acme - Nashville' });
const acmeSites = { places: { sites: ['acme'] } };
scenario([nashville], [], [595, 603, 610, 744.9], { active: true, config: acmeSites });
scenario([nashville, call('c', 620, 640)], [], [615, 625], { config: acmeSites });
scenario([nashville], [], [610]);
scenario([ev({ id: 'l', title: 'Lunch', start: 750 * M, end: 805 * M, availability: 'ooo' }), call('c', 800, 815)], [[801, 810]],
  [745, 760, 792, 802, 811]);
scenario([ev({ id: 'm', title: 'm', start: 600 * M, end: 660 * M, attendees: 2, location: 'Production Resource Group' })], [], [610],
  { config: { places: { sites: ['production resource group'] } } });
scenario([ev({ id: 'm', title: 'm', start: 600 * M, end: 660 * M, attendees: 2, location: 'The Den' })], [], [610],
  { config: { places: { office: ['the den'] } } });
scenario([ev({ id: 'm', title: 'm', start: 600 * M, end: 660 * M, attendees: 2, location: 'Studio 3' })], [], [603],
  { active: true, config: { places: { rooms: ['studio'] } } });
scenario([ev({ id: 'c', title: 'Client day', start: 600 * M, end: 660 * M })], [], [610], { config: { keywords: { onSite: ['client day'] } } });
// ended early: End Now, or the Leave key outside a call-app meeting
const ownOffice = ev({ id: 'o', title: 'o', start: 600 * M, end: 660 * M, attendees: 2, location: "Woody's office" });
for (const extra of [{ ended: ['o'] }, { ended: ['o', 'c'] }, { ended: ['x'] }]) {
  scenario([ownOffice, call('c', 660, 690)], [], [605, 620, 652, 665], extra);
  scenario([ownOffice, call('c', 700, 730)], [[605, 615]], [610, 620], extra);
}
scenario([ev({ id: 's', title: 'Site visit', start: 600 * M, end: 720 * M, location: 'O2 Arena' }), call('c', 720, 750)], [], [620, 715],
  { ended: ['s'] });
// left with the Leave key: the events the call was for (expect.leftEvents), and the sign once they're
// ended and the mic session's closed, as the app does it
const leave = (events, sessions, times) => {
  for (const t of times) {
    const input = { now: t * M, override: 'auto', dndUntil: null, events: events, micSessions: mic(sessions) };
    add(input);
    add(Object.assign({}, input, { ended: R.leftEvents(input), micSessions: mic(sessions.map(([s, e]) => [s, e == null ? t : e])) }));
  }
};
const hybridCall = call('h', 600, 660, { location: 'Microsoft Teams Meeting; LP Huddle' });
leave([hybridCall], [[602, null]], [603, 620, 659.9]);
leave([hybridCall, call('n', 650, 680)], [[602, null]], [620, 645]);
leave([ev({ id: 'p', title: 'Call - Linda', start: 600 * M, end: 630 * M })], [[602, null]], [610]);
leave([call('a', 600, 660), call('b', 660, 690)], [[600, null]], [640, 659, 665]);
leave([call('c', 600, 630)], [[597, null]], [598, 605]);
leave([call('t', 600, 630, { availability: 'tentative' })], [[601, null]], [610]);
leave([ev({ id: 'l', title: 'Lunch', start: 590 * M, end: 650 * M }), call('c', 600, 630)], [[601, null]], [610]);
leave([call('a', 600, 660), call('b', 600, 630)], [[601, null]], [615]);
leave([call('a', 600, 660)], [[540, null]], [610]);
leave([venue], [[601, null]], [615]);
leave([], [[601, null]], [610]);
for (const t of ['08:40', '09:50', '11:20', '14:20', '16:10']) {
  const at = D.at(0, t);
  const input = { now: at, override: 'auto', dndUntil: null, events: day.events, micSessions: day.micSessions };
  add(Object.assign({}, input, { ended: R.leftEvents(input),
    micSessions: day.micSessions.map((s) => ({ start: s.start, end: s.end == null || s.end > at ? at : s.end })) }));
}
for (const t of ['09:46', '11:10', '14:05', '14:11', '15:40']) {
  for (const extra of [{ active: true }, { inPerson: ['oneone', 'network'] }]) {
    add(Object.assign({ now: D.at(0, t), override: 'auto', dndUntil: null, events: day.events, micSessions: day.micSessions }, extra));
  }
}

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
  { title: 'Call: Mum %F0%9F%98%80' }, { attendees: 1, url: 'https://zoom.us/j/9' }, { attendees: 1, notes: '%E2%9C%88 not a link' },
  // where: a room, your office, somewhere else, or nowhere in particular
  { attendees: 3, notes: 'https://teams.microsoft.com/l/x', rooms: ['Arc'], location: 'Arc' }, { attendees: 3, location: 'LP Huddle' },
  { attendees: 3, notes: 'https://teams.microsoft.com/l/x', location: 'Boardroom' }, { attendees: 3, location: 'MTL-210' },
  { attendees: 3, location: 'mtl-210 (8)' }, { attendees: 2, notes: 'https://teams.microsoft.com/l/x', location: "Woody's office" },
  { attendees: 2, location: 'Woody’s Office' }, { attendees: 2, location: 'My office' },
  { attendees: 3, location: 'OVO Arena Wembley, Arena Square, London HA9 0AA' },
  { attendees: 3, notes: 'https://teams.microsoft.com/l/x', location: 'Live Nation, 9348 Civic Center Dr, Beverly Hills' },
  { title: 'Lunch with Paul', attendees: 1, location: 'The Ivy' }, { attendees: 3, location: 'LP Huddle; The Ivy' },
  { attendees: 3, availability: 'tentative', location: 'The Ivy' }, { attendees: 2, location: 'TBC' }, { attendees: 2, location: 'Teams' },
  { attendees: 2, location: '+44 20 7946 0000' }, { attendees: 2, location: 'Tel +44 (0)20 7946 0000' },
  { attendees: 2, location: 'https://bluejeans.com/123' }, { attendees: 2, location: 'https://teams.microsoft.com/l/x' },
  { attendees: 2, location: '-' }, { attendees: 2, location: 'Café de Flore; Microsoft Teams Meeting' }, { attendees: 2, location: '東京' },
  { title: 'Dentist', location: '12 High St' }, { title: 'On site - Live Nation' }, { title: 'Wembley onsite' },
  { title: 'On-site: Glastonbury' }, { title: 'Nonsite' }, { title: 'ON SITE', allDay: true },
  { title: 'On site Coldplay', availability: 'ooo' }, { title: '✈ LHR→LAX on site' },
  { title: 'On site prep', attendees: 3, notes: 'https://teams.microsoft.com/l/x' },
  { title: 'Lunch', availability: 'ooo' }, { title: 'Lunch with Paul', attendees: 1, availability: 'ooo' },
  { title: 'Lunch on site', availability: 'ooo' }, { title: 'Lunch', allDay: true, availability: 'ooo' }
];
ONE.forEach((o, i) => scenario([ev(Object.assign({ id: 'one' + i, start: 600 * M, end: 660 * M }, o))], [], [590, 630]));
// a company's sites, with its name set in Settings
const AT_SITES = [
  { attendees: 7, location: 'Acme - Nashville' }, { attendees: 7, notes: 'https://teams.microsoft.com/l/x', location: 'Acme - Nashville' },
  { attendees: 7, location: 'Acme - Nashville; MTL-210' }, { attendees: 3, location: 'Acme’s warehouse' },
  { attendees: 3, location: 'Acmetech Ltd, 4 High St' }
];
AT_SITES.forEach((o, i) => scenario([ev(Object.assign({ id: 'site' + i, start: 600 * M, end: 660 * M }, o))], [], [590, 630], { config: acmeSites }));

fs.writeFileSync(process.argv[2], JSON.stringify({ cases: cases }));
console.log('rule cases:', cases.length);
