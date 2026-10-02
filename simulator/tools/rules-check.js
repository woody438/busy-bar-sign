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
expect('10:15 free till 10:30', sAt('10:15').at, D.at(base, '10:30'));
expect('14:09:59 still late', sAt('14:09:59').state, 'late');
expect('14:10:00 gives up', sAt('14:10:00').state, 'free');
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
expect('teams + a room', kind({ attendees: 3, location: 'Microsoft Teams Meeting; UK Birmingham Room' }), 'call');
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
expect('show as out of office', kind({ title: 'Paris', availability: 'ooo' }), 'ooo');
expect('all-day busy', kind({ title: 'PARIS', allDay: true }), 'ooo');
expect('all-day tentative', kind({ title: 'Maybe', allDay: true, availability: 'tentative' }), 'ignore');
expect('tentative call', R.classify(ev({ attendees: 2, availability: 'tentative', location: 'Microsoft Teams Meeting' })).tentative, true);
expect('tentative own block is not "tentative"', R.classify(ev({ title: 'Lunch', availability: 'tentative' })).tentative, false);

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
expect('joined 4 min early, left early', decide(640, [call('a', 600, 660)], [[596, 630]]).state, 'freeTil');
// a confirmed call beats a tentative one starting sooner
expect('confirmed beats tentative', decide(595, [call('t', 598, 630, { availability: 'tentative' }), call('c', 602, 630)]).state, 'callIn');
// a warning beats FREE TILL
expect('warning beats free till', decide(645, [call('a', 600, 660), call('b', 652, 700)], [[600, 640]]).state, 'callIn');
// LATE beats the next call's warning
expect('late beats warning', decide(603, [call('a', 600, 660), call('b', 610, 640)]).state, 'late');
// an in-person meeting beats a call warning
expect('meeting beats warning', decide(605, [ev({ title: 'm', start: 600 * M, end: 660 * M, attendees: 3 }), call('b', 610, 640)]).state, 'meeting');
// tentative never goes LATE, and gives way to a confirmed warning
expect('tentative not late', decide(601, [call('t', 600, 630, { availability: 'tentative' })]).state, 'tentative');
expect('confirmed warning beats tentative now', decide(615, [call('t', 600, 630, { availability: 'tentative' }), call('c', 620, 650)]).state, 'callIn');
// away beats a meeting warning, like lunch
expect('away suppresses warning', decide(595, [ev({ title: 'Drive', start: 590 * M, end: 605 * M }), call('c', 600, 630)]).state, 'away');
expect('warning after away ends', decide(596, [ev({ title: 'Drive', start: 590 * M, end: 595 * M }), call('c', 600, 630)]).state, 'callIn');
// the no-meetings block gives way to a late call
expect('late inside DND block', decide(605, [ev({ title: 'NO MEETINGS', start: 540 * M, end: 720 * M }), call('c', 600, 630)]).state, 'late');
// nothing at all
expect('empty calendar', decide(600, []).state, 'free');
// custom keywords
expect('custom lunch word', R.decide({ now: 600 * M, events: [ev({ title: 'Déjeuner', start: 590 * M, end: 650 * M })],
  config: { keywords: { lunch: ['déjeuner'] } } }).state, 'lunch');

console.log(failed ? `rules: ${failed} failed, ${passed} passed` : `rules: all ${passed} cases pass`);
process.exit(failed ? 1 : 0);
