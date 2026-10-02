/*
 * A sample working day in the calendar, for the simulator's day player and
 * for tools/rules-check.js. Times are 'HH:MM' or 'HH:MM:SS' from midnight;
 * BusyDay.at(base, '09:45') turns one into milliseconds after `base`.
 * The events cover every rule: a call joined late and left early, one never
 * joined, an in-person meeting, a tentative one, lunch with a call inside
 * it, a no-meetings block, your own blocks, a cancelled and a show-as-free
 * meeting, and a flight.
 */
(function (root) {
  'use strict';

  const TEAMS_NOTES = 'Agenda below.\n\n________________________________________________________________________________\n' +
    'Microsoft Teams meeting\nJoin: https://eur02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting&data=05\n' +
    'Meeting ID: 123 456 789';

  const EVENTS = [
    { id: 'gym', title: 'Gym', start: '07:00', end: '07:50' },
    { id: 'nomeet', title: 'NO MEETINGS', start: '08:00', end: '09:30' },
    { id: 'ops', title: 'Ops weekly review', start: '08:30', end: '09:00', attendees: 7,
      location: 'Microsoft Teams Meeting', notes: TEAMS_NOTES },
    { id: 'network', title: 'Network discussion', start: '09:45', end: '10:30', attendees: 13, notes: TEAMS_NOTES },
    { id: 'values', title: 'Values session - in person', start: '11:00', end: '11:30', attendees: 4, location: "Woody's office" },
    { id: 'demo', title: 'Vendor demo', start: '12:00', end: '12:30', attendees: 6, availability: 'tentative',
      location: 'Microsoft Teams Meeting', notes: TEAMS_NOTES },
    { id: 'lunch', title: 'Lunch', start: '12:30', end: '13:25' },
    { id: 'quoting', title: 'Daily quoting needs', start: '13:00', end: '13:15', attendees: 11,
      location: 'Microsoft Teams Meeting', notes: TEAMS_NOTES },
    { id: 'oneone', title: 'Monthly 1:1', start: '14:00', end: '14:30', attendees: 2, notes: TEAMS_NOTES },
    { id: 'phone', title: 'Call - mortgage advisor', start: '15:00', end: '15:30', notes: 'She will call your mobile.' },
    { id: 'drive', title: 'Drive home', start: '15:30', end: '15:55' },
    { id: 'cancelled', title: 'Canceled: Supplier sync', start: '16:00', end: '16:30', attendees: 5, cancelled: true,
      notes: TEAMS_NOTES },
    { id: 'showfree', title: 'Optional town hall', start: '16:40', end: '17:10', attendees: 300, availability: 'free',
      notes: TEAMS_NOTES },
    { id: 'payday', title: 'Payday', start: '00:00', end: '24:00', allDay: true, availability: 'free' },
    { id: 'flight', title: '✈ BNA→LHR • BA 222', start: '17:30', end: '23:45',
      notes: 'British Airways 222 / Nashville to London' }
  ];

  /* When the microphone was in use (debounced), as the detector reports it. */
  const MIC = [
    { start: '08:29', end: '08:58' },       // the ops review, joined a minute early
    { start: '09:48:20', end: '10:12' },     // the network call: 3 min late, out 18 min early
    { start: '13:02', end: '13:14' }         // jumped on the quoting call from lunch
  ];

  function at(base, hhmm) {
    const p = hhmm.split(':').map(Number);
    return base + ((p[0] * 60 + p[1]) * 60 + (p[2] || 0)) * 1000;
  }

  /* The day's events and mic sessions in milliseconds after `base` (midnight). */
  function build(base) {
    return {
      events: EVENTS.map((e) => Object.assign({ attendees: 0, availability: 'busy', allDay: false, notes: '', location: '' }, e,
        { start: at(base, e.start), end: at(base, e.end) })),
      micSessions: MIC.map((m) => ({ start: at(base, m.start), end: at(base, m.end) }))
    };
  }

  /* Moments worth jumping to, with what the sign should say. */
  const MOMENTS = [
    ['07:10', 'away', 'Gym: your own block → AWAY'],
    ['07:55', 'free', 'Nothing on'],
    ['08:05', 'dnd', 'NO MEETINGS block'],
    ['08:20', 'callIn', 'Call at 08:30, inside the block'],
    ['08:40', 'call', 'On the ops review'],
    ['08:59', 'dnd', 'Hung up; still in the block'],
    ['09:35', 'callIn', 'Network call at 09:45'],
    ['09:46', 'late', 'Not on it yet'],
    ['09:50', 'call', 'Joined, 3 min late'],
    ['10:15', 'freeTil', 'Left 18 min early'],
    ['10:35', 'free', 'Slot over'],
    ['10:52', 'busyIn', 'In-person meeting at 11:00'],
    ['11:10', 'meeting', 'In the meeting'],
    ['11:52', 'callTbc', 'Tentative demo at 12:00'],
    ['12:10', 'callTbc', 'Tentative demo, not joined'],
    ['12:40', 'lunch', 'Lunch'],
    ['12:55', 'lunch', 'Quoting call at 13:00: lunch wins, no warning'],
    ['13:05', 'call', 'Joined the quoting call from lunch'],
    ['13:20', 'lunch', 'Back to lunch'],
    ['13:52', 'callIn', '1:1 at 14:00'],
    ['14:05', 'late', 'Not joined'],
    ['14:11', 'free', 'Gave up after 10 min'],
    ['15:10', 'call', '“Call - …” block: phone call'],
    ['15:40', 'away', 'Drive home'],
    ['16:10', 'free', 'Cancelled meeting: ignored'],
    ['16:45', 'free', 'Show As Free: ignored'],
    ['17:40', 'ooo', 'Flight']
  ];

  root.BusyDay = { EVENTS: EVENTS, MIC: MIC, MOMENTS: MOMENTS, at: at, build: build, START: '06:45', END: '18:15' };
})(typeof window !== 'undefined' ? window : globalThis);
