/*
 * Checks the status rules in rules.js: the sample day's moments, then the
 * edge cases one by one.   node simulator/tools/rules-check.js
 * The Swift port runs the same cases (Checks/rules/main.swift); keep them in step.
 */
const path = require('path');
require(path.join(__dirname, '..', 'rules.js'));
require(path.join(__dirname, '..', 'day.js'));
const R = globalThis.BusyRules, D = globalThis.BusyDay;

let failed = 0, passed = 0;
function expect(name, got, want) {
  if (got === want) { passed++; return; }
  failed++;
  console.log('FAIL', name, '— got', JSON.stringify(got), 'want', JSON.stringify(want));
}

// --- the sample day ----------------------------------------------------------
const base = 0, day = D.build(base);
for (const [t, want, note] of D.MOMENTS) {
  const s = R.decide(Object.assign({ now: D.at(base, t), override: 'auto', dndUntil: null }, day));
  expect(t + ' ' + note, s.state, want);
}
// the countdowns
const sAt = (t, extra) => R.decide(Object.assign({ now: D.at(base, t), override: 'auto', dndUntil: null }, day, extra || {}));
expect('08:20 counts down 10:00', sAt('08:20').left, 600);
expect('09:46 is 60 s late', sAt('09:46').left, 60);
expect('14:47 free till 14:55', sAt('14:47').at, D.at(base, '14:55'));
expect('14:09:59 still late', sAt('14:09:59').state, 'late');
expect('14:10:00 never joined: in person', sAt('14:10:00').state, 'meeting');
expect('…counting down to the end', sAt('14:10:00').at, D.at(base, '15:30'));
expect('09:35:00 warns exactly 10 min out', sAt('09:35:00').state, 'callIn');
expect('09:34:59 too early to warn', sAt('09:34:59').state, 'free');

// manual controls outrank everything
expect('forced free during a call', sAt('08:40', { override: 'free' }).state, 'free');
expect('forced on a call at lunch', sAt('12:40', { override: 'onCall' }).state, 'call');
expect('double-click DND beats a warning', sAt('09:40', { dndUntil: D.at(base, '10:00') }).state, 'dnd');
expect('…but not the mic', sAt('09:50', { dndUntil: D.at(base, '10:30') }).state, 'call');
expect('…and its countdown', sAt('09:40', { dndUntil: D.at(base, '10:00') }).left, 1200);

// --- classification ------------------------------------------------------------
const ev = (o) => Object.assign({ title: '', start: 0, end: 1, attendees: 0, availability: 'busy', allDay: false, notes: '', location: '' }, o);
const kind = (o) => R.classify(ev(o)).kind;
expect('teams via safelinks', kind({ attendees: 3, notes: 'https://eur02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2F' }), 'call');
expect('teams by location', kind({ attendees: 3, location: 'Microsoft Teams Meeting' }), 'call');
expect('french teams location', kind({ attendees: 3, location: 'Réunion Microsoft Teams' }), 'call');
expect('teams + a room', kind({ attendees: 3, location: 'Microsoft Teams Meeting; UK Birmingham Room' }), 'inPerson');
expect('meet via checkpoint wrap', kind({ attendees: 2, notes: 'Join: https://protect.checkpoint.com/v2/r02/___https://meet.google.com/sbb-mnif-nvn___' }), 'call');
expect('zoom', kind({ attendees: 2, notes: 'https://us02web.zoom.us/j/123' }), 'call');
expect('own block with a link is a call', kind({ notes: 'https://teams.microsoft.com/l/meetup-join/x' }), 'call');
expect('in person', kind({ attendees: 4, location: 'Teal Meeting Room (GB)' }), 'inPerson');
expect('lunch', kind({ title: 'Lunch' }), 'lunch');
expect('lunch, any case', kind({ title: 'team LUNCH out' }), 'lunch');
expect('no meetings', kind({ title: 'NO MEETINGS' }), 'dndBlock');
expect('focus', kind({ title: 'Focus time' }), 'dndBlock');
expect('phone call', kind({ title: 'Call - Linda (home lending)' }), 'phone');
expect('call, mid-title', kind({ title: 'Talk to someone, call them' }), 'phone');
expect('"recall" is not a call', kind({ title: 'Recall stock' }), 'away');
expect('flight', kind({ title: '✈ CDG→LHR • BA 303' }), 'ooo');
expect('other own block', kind({ title: 'PRVN CrossFit' }), 'away');
expect('show as free', kind({ attendees: 9, availability: 'free', location: 'Microsoft Teams Meeting' }), 'ignore');
expect('cancelled', kind({ attendees: 9, cancelled: true }), 'ignore');
expect('"Canceled:" title', kind({ title: 'Canceled: Supplier sync', attendees: 5, location: 'Microsoft Teams Meeting' }), 'ignore');
expect('"Cancelled:" title', kind({ title: 'Cancelled: Lunch' }), 'ignore');
expect('show as out of office', kind({ title: 'Paris', availability: 'ooo' }), 'ooo');
expect('your lunch shown as out of office is lunch', kind({ title: 'Lunch', availability: 'ooo' }), 'lunch');
expect('…an invited one stays out of office', kind({ title: 'Lunch with Paul', attendees: 1, availability: 'ooo' }), 'ooo');
expect('…on site beats it', kind({ title: 'Lunch on site', availability: 'ooo' }), 'onSite');
expect('…an all-day one stays out of office', kind({ title: 'Lunch', allDay: true, availability: 'ooo' }), 'ooo');
expect('all-day busy', kind({ title: 'PARIS', allDay: true }), 'ooo');
expect('all-day tentative', kind({ title: 'Maybe', allDay: true, availability: 'tentative' }), 'ignore');
expect('tentative call', R.classify(ev({ attendees: 2, availability: 'tentative', location: 'Microsoft Teams Meeting' })).tentative, true);
expect('tentative own block is not "tentative"', R.classify(ev({ title: 'Lunch', availability: 'tentative' })).tentative, false);

// where a meeting is: the location says where you'll be, a link only that others can dial in
const teams = 'https://teams.microsoft.com/l/meetup-join/x';
const room = (o) => R.classify(ev(o)).room;
expect('teams + a room is in a room', room({ attendees: 3, location: 'Microsoft Teams Meeting; UK Birmingham Room' }), true);
expect('in person in a room', room({ attendees: 4, location: 'Teal Meeting Room (GB)' }), true);
expect('a booked room, any name', kind({ attendees: 3, notes: teams, rooms: ['Arc'], location: 'Arc' }), 'inPerson');
expect('…is a room', room({ attendees: 3, notes: teams, rooms: ['Arc'], location: 'Arc' }), true);
expect('a huddle', room({ attendees: 3, location: 'LP Huddle' }), true);
expect('the boardroom', room({ attendees: 3, notes: teams, location: 'Boardroom' }), true);
expect('a room code', room({ attendees: 3, notes: teams, location: 'MTL-210' }), true);
expect('teams + your office', kind({ attendees: 2, notes: teams, location: "Woody's office" }), 'inPerson');
expect('…is not a room', room({ attendees: 2, notes: teams, location: "Woody's office" }), false);
expect('your office, curly', kind({ attendees: 2, notes: teams, location: 'Woody’s Office' }), 'inPerson');
expect('my office', kind({ attendees: 2, location: 'My office' }), 'inPerson');
expect('no location', room({ attendees: 2 }), false);
expect('a Solotech site', kind({ attendees: 7, location: 'Solotech - Nashville' }), 'inPerson');
expect('…with a teams link', kind({ attendees: 7, notes: teams, location: 'Solotech - Nashville' }), 'inPerson');
expect('…is not a room', room({ attendees: 7, location: 'Solotech - Nashville' }), false);
expect('…but a room there is', room({ attendees: 7, location: 'Solotech - Nashville; MTL-210' }), true);
expect('Solotech’s, curly', kind({ attendees: 3, location: 'Solotech’s warehouse' }), 'inPerson');
expect('a client named like it is not', kind({ attendees: 3, location: 'Solotechnics Ltd, 4 High St' }), 'onSite');
expect('a venue', kind({ attendees: 3, location: 'OVO Arena Wembley, Arena Square, London HA9 0AA' }), 'onSite');
expect('a venue with a teams link', kind({ attendees: 3, notes: teams, location: 'Live Nation, 9348 Civic Center Dr, Beverly Hills' }), 'onSite');
expect('a restaurant', kind({ title: 'Lunch with Paul', attendees: 1, location: 'The Ivy' }), 'onSite');
expect('a venue and a room', kind({ attendees: 3, location: 'LP Huddle; The Ivy' }), 'inPerson');
expect('tentative at a venue', R.classify(ev({ attendees: 3, availability: 'tentative', location: 'The Ivy' })).kind, 'inPerson');
expect('…is tentative', R.classify(ev({ attendees: 3, availability: 'tentative', location: 'The Ivy' })).tentative, true);
expect('TBC is nowhere', kind({ attendees: 2, location: 'TBC' }), 'inPerson');
expect('a call app is nowhere', kind({ attendees: 2, location: 'Teams' }), 'inPerson');
expect('a dial-in is nowhere', kind({ attendees: 2, location: '+44 20 7946 0000' }), 'inPerson');
expect('a dial-in with words is nowhere', kind({ attendees: 2, location: 'Tel +44 (0)20 7946 0000' }), 'inPerson');
expect('a link is nowhere', kind({ attendees: 2, location: 'https://bluejeans.com/123' }), 'inPerson');
expect('…and a link with teams in it a call', kind({ attendees: 2, location: 'https://teams.microsoft.com/l/x' }), 'call');
expect('a dash is nowhere', kind({ attendees: 2, location: '-' }), 'inPerson');
expect('your own block somewhere is still away', kind({ title: 'Dentist', location: '12 High St' }), 'away');
expect('on site', kind({ title: 'On site - Live Nation' }), 'onSite');
expect('onsite', kind({ title: 'Wembley onsite' }), 'onSite');
expect('on-site', kind({ title: 'On-site: Glastonbury' }), 'onSite');
expect('"onsite" inside a word is not', kind({ title: 'Nonsite' }), 'away');
expect('on site all day', kind({ title: 'ON SITE', allDay: true }), 'onSite');
expect('on site, show as out of office', kind({ title: 'On site Coldplay', availability: 'ooo' }), 'onSite');
expect('on site beats ✈', kind({ title: '✈ LHR→LAX on site' }), 'onSite');
expect('an invite titled on site goes by its location', kind({ title: 'On site prep', attendees: 3, notes: teams }), 'call');

// --- edge cases -----------------------------------------------------------------
const M = 60000;
const call = (id, s, e, o) => ev(Object.assign({ id: id, title: id, start: s * M, end: e * M, attendees: 3, location: 'Microsoft Teams Meeting' }, o || {}));
const decide = (now, events, mic) => R.decide({ now: now * M, override: 'auto', dndUntil: null, events: events, micSessions: (mic || []).map(([s, e]) => ({ start: s * M, end: e == null ? null : e * M })) });

// overrunning one call into the next: the next shows LATE, not FREE TILL
const two = [call('a', 600, 660), call('b', 660, 690)];
expect('overrun: on the mic', decide(663, two, [[598, 665]]).state, 'call');
expect('overrun: next call is late', decide(666, two, [[598, 665]]).state, 'late');
expect('overrun: late counts from its start', decide(666, two, [[598, 665]]).left, 360);
// joining a few minutes early counts as joining
expect('joined 4 min early, left early', decide(640, [call('a', 600, 660), call('b', 660, 690)], [[596, 630]]).state, 'freeTil');
// left early: FREE TILL only with something on the sign straight after (within 5 min), else FREE
const own = (title, s, e, o) => ev(Object.assign({ title: title, start: s * M, end: e * M }, o || {}));
expect('left early, nothing after', decide(640, [call('a', 600, 660)], [[600, 630]]).state, 'free');
expect('left early, next call 30 min after', decide(640, [call('a', 600, 660), call('b', 690, 720)], [[600, 630]]).state, 'free');
expect('left early, next call 5 min after', decide(640, [call('a', 600, 660), call('b', 665, 700)], [[600, 630]]).state, 'freeTil');
expect('…free till the slot ends', decide(640, [call('a', 600, 660), call('b', 665, 700)], [[600, 630]]).at, 660 * M);
expect('left early, next call 6 min after', decide(640, [call('a', 600, 660), call('b', 666, 700)], [[600, 630]]).state, 'free');
expect('left early, lunch straight after', decide(640, [call('a', 600, 660), own('Lunch', 660, 720)], [[600, 630]]).state, 'freeTil');
expect('left early, your own block after', decide(640, [call('a', 600, 660), own('Gym', 660, 720)], [[600, 630]]).state, 'freeTil');
expect('left early, tentative after', decide(640, [call('a', 600, 660), call('t', 660, 690, { availability: 'tentative' })], [[600, 630]]).state, 'freeTil');
expect('left early, cancelled after', decide(640, [call('a', 600, 660), call('x', 660, 690, { cancelled: true })], [[600, 630]]).state, 'free');
expect('left early, show-as-free after', decide(640, [call('a', 600, 660), call('x', 660, 690, { availability: 'free' })], [[600, 630]]).state, 'free');
expect('left early, one inside the slot', decide(640, [call('a', 600, 660), own('Gym', 645, 660)], [[600, 630]]).state, 'free');
// a confirmed call beats a tentative one starting sooner
expect('confirmed beats tentative', decide(595, [call('t', 598, 630, { availability: 'tentative' }), call('c', 602, 630)]).state, 'callIn');
expect('tentative call soon', decide(595, [call('t', 600, 630, { availability: 'tentative' })]).state, 'callTbc');
expect('…counts down', decide(595, [call('t', 600, 630, { availability: 'tentative' })]).left, 300);
expect('tentative in person', decide(605, [ev({ title: 'm', start: 600 * M, end: 660 * M, attendees: 3, availability: 'tentative' })]).state, 'busyTbc');
expect('…shows its end', decide(605, [ev({ title: 'm', start: 600 * M, end: 660 * M, attendees: 3, availability: 'tentative' })]).at, 660 * M);
// a warning beats FREE TILL
expect('warning beats free till', decide(645, [call('a', 600, 660), call('b', 652, 700)], [[600, 640]]).state, 'callIn');
// LATE beats the next call's warning
expect('late beats warning', decide(603, [call('a', 600, 660), call('b', 610, 640)]).state, 'late');
// an in-person meeting beats a call warning
expect('meeting beats warning', decide(605, [ev({ title: 'm', start: 600 * M, end: 660 * M, attendees: 3 }), call('b', 610, 640)]).state, 'meeting');
// tentative never goes LATE, and gives way to a confirmed warning
expect('tentative not late', decide(601, [call('t', 600, 630, { availability: 'tentative' })]).state, 'callTbc');
expect('…and no countdown once on', decide(601, [call('t', 600, 630, { availability: 'tentative' })]).left, undefined);
expect('confirmed warning beats tentative now', decide(615, [call('t', 600, 630, { availability: 'tentative' }), call('c', 620, 650)]).state, 'callIn');
// away beats a meeting warning, like lunch
expect('away suppresses warning', decide(595, [ev({ title: 'Drive', start: 590 * M, end: 605 * M }), call('c', 600, 630)]).state, 'away');
expect('warning after away ends', decide(596, [ev({ title: 'Drive', start: 590 * M, end: 595 * M }), call('c', 600, 630)]).state, 'callIn');
// the no-meetings block gives way to a late call
expect('late inside DND block', decide(605, [ev({ title: 'NO MEETINGS', start: 540 * M, end: 720 * M }), call('c', 600, 630)]).state, 'late');
// nothing at all
expect('empty calendar', decide(600, []).state, 'free');

// on a call or in a meeting: a countdown to free, through back-to-back meetings
expect('on the ops review, free at 09:00', sAt('08:40').at, D.at(base, '09:00'));
expect('…20 minutes to go', sAt('08:40').left, 1200);
expect('joined a minute early: counts to its end', sAt('08:29:30').at, D.at(base, '09:00'));
expect('quoting call from lunch: free at 13:15', sAt('13:05').at, D.at(base, '13:15'));
expect('calendar phone call counts down', sAt('15:10').left, 1200);
expect('in-person meeting counts down', sAt('11:10').at, D.at(base, '11:30'));
const chain = [call('a', 600, 660), call('b', 660, 690), ev({ title: 'm', start: 695 * M, end: 720 * M, attendees: 2 }), call('d', 730, 760)];
expect('back to back: through b and the 5-min gap to m', decide(630, chain, [[600, null]]).at, 720 * M);
expect('…not across a 10-min gap', decide(630, chain, [[600, null]]).state, 'call');
expect('meeting chains too', decide(700, chain).at, 720 * M);
expect('mic with nothing in the calendar: no countdown', decide(630, [], [[600, null]]).left, undefined);
expect('mic after the call overran: no countdown', decide(665, [call('a', 600, 660)], [[600, null]]).left, undefined);
expect('lunch does not chain', decide(630, [call('a', 600, 660), ev({ title: 'Lunch', start: 660 * M, end: 720 * M })], [[600, null]]).at, 660 * M);
// --- the away keys, and the Mac locked ---------------------------------------
const decideWith = (now, events, mic, extra) => R.decide(Object.assign({ now: now * M, override: 'auto', dndUntil: null, events: events,
  micSessions: (mic || []).map(([s, e]) => ({ start: s * M, end: e == null ? null : e * M })) }, extra || {}));
const meeting = ev({ title: 'm', start: 600 * M, end: 660 * M, attendees: 3 });
expect('nearby key', decideWith(600, [], [], { away: 'nearby' }).state, 'nearby');
expect('lunch key', decideWith(600, [], [], { away: 'lunch' }).state, 'lunch');
expect('…beats a meeting in the calendar', decideWith(610, [meeting], [], { away: 'lunch' }).state, 'lunch');
expect('…and a warning', decideWith(595, [call('c', 600, 630)], [], { away: 'nearby' }).state, 'nearby');
expect('…and Do Not Disturb', decideWith(600, [], [], { away: 'nearby', dndUntil: 620 * M }).state, 'nearby');
expect('the mic beats the keys', decideWith(605, [], [[600, null]], { away: 'lunch' }).state, 'call');
expect('the Sign setting beats them', decideWith(600, [], [], { away: 'lunch', override: 'free' }).state, 'free');
expect('back in: counts down', decideWith(600, [], [], { away: 'backIn', awayUntil: 630 * M }).left, 1800);
expect('…to its time', decideWith(600, [], [], { away: 'backIn', awayUntil: 630 * M }).at, 630 * M);
expect('…till the last moment', decideWith(629.99, [], [], { away: 'backIn', awayUntil: 630 * M }).state, 'backIn');
expect('…then gives way: free', decideWith(630, [], [], { away: 'backIn', awayUntil: 630 * M }).state, 'free');
expect('…or nearby, locked', decideWith(630, [], [], { away: 'backIn', awayUntil: 630 * M, locked: true }).state, 'nearby');
expect('back in with no time is nothing', decideWith(600, [], [], { away: 'backIn' }).state, 'free');
expect('locked, nothing on: nearby', decideWith(600, [], [], { locked: true }).state, 'nearby');
expect('locked: Do Not Disturb waits', decideWith(600, [], [], { locked: true, dndUntil: 620 * M }).state, 'nearby');
expect('…and comes back unlocked', decideWith(600, [], [], { dndUntil: 620 * M }).state, 'dnd');
expect('locked: the calendar still says lunch', decideWith(600, [own('Lunch', 590, 650)], [], { locked: true }).state, 'lunch');
expect('…a meeting', decideWith(610, [meeting], [], { locked: true }).state, 'meeting');
expect('…a warning', decideWith(595, [call('c', 600, 630)], [], { locked: true }).state, 'callIn');
expect('…a call you\'re late for', decideWith(603, [call('c', 600, 630)], [], { locked: true }).state, 'late');
expect('…a tentative call', decideWith(605, [call('t', 600, 630, { availability: 'tentative' })], [], { locked: true }).state, 'callTbc');
expect('locked beats a no-meetings block', decideWith(600, [own('NO MEETINGS', 540, 720)], [], { locked: true }).state, 'nearby');
expect('locked beats free till', decideWith(640, [call('a', 600, 660), call('b', 665, 700)], [[600, 630]], { locked: true }).state, 'nearby');
expect('locked on a call: on a call', decideWith(605, [], [[600, null]], { locked: true }).state, 'call');

// out on site, a call never joined, and in person
const venue = ev({ id: 'v', title: 'v', start: 600 * M, end: 660 * M, attendees: 3, location: 'The Ivy' });
expect('at a venue: out on site', decide(610, [venue]).state, 'onSite');
expect('…till it ends', decide(610, [venue]).at, 660 * M);
expect('…no warning before', decide(595, [venue]).state, 'free');
expect('…beats a call warning', decide(610, [venue, call('c', 615, 640)]).state, 'onSite');
expect('…and a meeting', decide(610, [venue, meeting]).state, 'onSite');
expect('…the mic beats it', decide(610, [venue], [[605, null]]).state, 'call');
expect('out of office beats it', decide(610, [venue, own('Paris', 590, 700, { availability: 'ooo' })]).state, 'ooo');
expect('on site all day', decide(610, [own('ON SITE', 0, 1440, { allDay: true }), call('c', 600, 630)]).state, 'onSite');
const hybrid = call('h', 600, 660, { location: 'Microsoft Teams Meeting; LP Huddle' });
expect('teams + a room: busy soon', decide(595, [hybrid]).state, 'busyIn');
expect('…then in a meeting, not late', decide(601, [hybrid]).state, 'meeting');
expect('…counting down', decide(601, [hybrid]).at, 660 * M);
expect('never joined: late', decide(609.9, [call('a', 600, 660)]).state, 'late');
expect('…then in person', decide(610, [call('a', 600, 660)]).state, 'meeting');
expect('…counting down to its end', decide(610, [call('a', 600, 660)]).at, 660 * M);
expect('…locked too', decideWith(620, [call('a', 600, 660)], [], { locked: true }).state, 'meeting');
expect('…but joined and left: free', decide(640, [call('a', 600, 660)], [[600, 630]]).state, 'free');
expect('…a tentative one still TBC', decide(620, [call('t', 600, 660, { availability: 'tentative' })]).state, 'callTbc');
expect('…beats a warning', decide(625, [call('a', 600, 660), call('b', 630, 690)]).state, 'meeting');
expect('…but not the next call starting late', decide(632, [call('a', 600, 660), call('b', 630, 690)]).state, 'late');
expect('…and a no-meetings block', decide(620, [own('NO MEETINGS', 540, 720), call('a', 600, 660)]).state, 'meeting');
expect('in person, said so: a meeting at once', decideWith(603, [call('a', 600, 660)], [], { inPerson: ['a'] }).state, 'meeting');
expect('…till it ends', decideWith(603, [call('a', 600, 660)], [], { inPerson: ['a'] }).at, 660 * M);
expect('…and busy soon before it', decideWith(595, [call('a', 600, 660)], [], { inPerson: ['a'] }).state, 'busyIn');
expect('…joining on the Mac is still on a call', decideWith(605, [call('a', 600, 660)], [[604, null]], { inPerson: ['a'] }).state, 'call');
expect('…only that call', decideWith(603, [call('a', 600, 660)], [], { inPerson: ['b'] }).state, 'late');
const huddle = ev({ id: 'r', title: 'r', start: 600 * M, end: 660 * M, attendees: 3, location: 'LP Huddle' });
expect('a room meeting, still at the Mac: late for it', decideWith(603, [huddle], [], { active: true }).state, 'lateMtg');
expect('…counting up', decideWith(603, [huddle], [], { active: true }).left, 180);
expect('…from its start', decideWith(603, [huddle], [], { active: true }).at, 600 * M);
expect('…not at the Mac: in the meeting', decideWith(603, [huddle], []).state, 'meeting');
expect('…locked: in the meeting', decideWith(603, [huddle], [], { active: true, locked: true }).state, 'meeting');
expect('…after ten minutes: in the meeting', decideWith(610, [huddle], [], { active: true }).state, 'meeting');
expect('…said so: in the meeting', decideWith(603, [huddle], [], { active: true, inPerson: ['r'] }).state, 'meeting');
expect('…on the mic: on a call', decideWith(603, [huddle], [[601, null]], { active: true }).state, 'call');
expect('…joined, then off it: in the meeting', decideWith(608, [huddle], [[601, 605]], { active: true }).state, 'meeting');
expect('…tentative: busy tbc', decideWith(603, [ev({ id: 'r', title: 'r', start: 600 * M, end: 660 * M, attendees: 3,
  location: 'LP Huddle', availability: 'tentative' })], [], { active: true }).state, 'busyTbc');
expect('in your office, at the Mac: in the meeting', decideWith(603, [meeting], [], { active: true }).state, 'meeting');
const nashville = ev({ id: 'n', title: 'n', start: 600 * M, end: 745 * M, attendees: 7, location: 'Solotech - Nashville' });
expect('at a Solotech site: a meeting, not out on site', decide(610, [nashville]).state, 'meeting');
expect('…and at the Mac, not late for it', decideWith(603, [nashville], [], { active: true }).state, 'meeting');
expect('…busy soon before it', decide(595, [nashville]).state, 'busyIn');

// your lunch, shown as Out of Office: LUNCH, as you're coming back
const oofLunch = own('Lunch', 750, 805, { availability: 'ooo' });
expect('lunch shown as out of office: lunch', decide(760, [oofLunch]).state, 'lunch');
expect('…beats a call warning', decide(760, [oofLunch, call('c', 800, 815)]).state, 'lunch');
expect('…a real out of office still beats it', decide(760, [oofLunch, own('Paris', 700, 900, { availability: 'ooo' })]).state, 'ooo');

// custom words
expect('custom office word', R.decide({ now: 610 * M, events: [ev({ title: 'm', start: 600 * M, end: 660 * M, attendees: 2, location: 'The Den' })],
  config: { places: { office: ['the den'] } } }).state, 'meeting');
expect('custom site word', R.decide({ now: 610 * M, events: [ev({ title: 'm', start: 600 * M, end: 660 * M, attendees: 2,
  location: 'Production Resource Group' })], config: { places: { sites: ['production resource group'] } } }).state, 'meeting');
expect('custom room word', R.decide({ now: 603 * M, active: true, events: [ev({ title: 'm', start: 600 * M, end: 660 * M, attendees: 2,
  location: 'Studio 3' })], config: { places: { rooms: ['studio'] } } }).state, 'lateMtg');
expect('custom on-site word', R.decide({ now: 610 * M, events: [own('Client day', 600, 660)],
  config: { keywords: { onSite: ['client day'] } } }).state, 'onSite');
expect('custom lunch word', R.decide({ now: 600 * M, events: [ev({ title: 'Déjeuner', start: 590 * M, end: 650 * M })],
  config: { keywords: { lunch: ['déjeuner'] } } }).state, 'lunch');

console.log(failed ? `rules: ${failed} failed, ${passed} passed` : `rules: all ${passed} cases pass`);
process.exit(failed ? 1 : 0);
