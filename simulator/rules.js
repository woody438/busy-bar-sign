/*
 * Busy Bar status rules — decides what the sign says from the microphone,
 * the manual controls and the calendar.
 *
 * Pure and deterministic, like engine.js: no Date.now(), no time zones.
 * Times are milliseconds on one clock; the caller turns `at` into hours and
 * minutes for the bar. The Mac app's Swift port is checked against this
 * file (simulator/tools/rules-check.js holds the cases).
 *
 * An event, as the app reads it from macOS Calendar (EventKit):
 *   { id, title, start, end, allDay,
 *     availability: 'busy' | 'free' | 'tentative' | 'ooo',   // Outlook's Show As
 *     attendees: number,                                     // invitees, 0 for your own blocks
 *     rooms: [string],                                       // the rooms booked on it, by name
 *     notes, location, url, cancelled }
 */
(function (root) {
  'use strict';

  const MINUTE = 60 * 1000;

  const DEFAULTS = {
    leadMinutes: 10,      // CALL IN / BUSY IN / MAYBE IN this long before
    lateMinutes: 10,      // LATE FOR CALL / MTG for at most this long, then MEETING
    joinEarlyMinutes: 5,  // a mic opened this long before a call counts as joining it
    chainGapMinutes: 5,   // meetings this close together count as back to back
    // Words in the titles of your own events (ones with no invitees).
    // Matched as whole words, any case; the first list that matches wins.
    keywords: {
      onSite: ['on site', 'onsite', 'on-site'],
      ooo: ['✈', 'out of office', 'ooo'],
      lunch: ['lunch'],
      dnd: ['no meetings', 'focus', 'do not disturb'],
      call: ['call']
    },
    // Words in a meeting's location, matched the same way: your own office,
    // and Solotech's rooms (a room booked on the invite counts whatever its name).
    places: {
      office: ['my office', "woody's office"],
      rooms: ['room', 'huddle', 'boardroom']
    }
  };

  /* Where a call's join link lives. Outlook puts it in the notes (wrapped in
     safelinks, which still carries the host in plain text) or names the
     service in the location. */
  const JOIN_HOSTS = /teams\.microsoft\.com|teams\.live\.com|zoom\.us|zoomgov\.com|meet\.google\.com|webex\.com|gotomeeting\.com|whereby\.com|chime\.aws/i;
  const JOIN_PLACES = /microsoft teams|teams meeting|zoom meeting|google meet|webex/i;

  function hasJoinLink(ev) {
    const text = [ev.notes, ev.url].filter(Boolean).join('\n');
    if (JOIN_HOSTS.test(text) || JOIN_HOSTS.test(safeDecode(text))) return true;
    return JOIN_PLACES.test(ev.location || '') || JOIN_HOSTS.test(ev.location || '');
  }
  function safeDecode(s) {
    return s.replace(/%[0-9a-f]{2}/gi, (m) => { try { return decodeURIComponent(m); } catch (e) { return m; } });
  }

  /* Whole-word, any-case match; a keyword that doesn't start with a letter
     or digit (✈) matches anywhere. Curly apostrophes count as straight ones
     (Outlook types "Woody’s office"). */
  const fold = (s) => s.toLowerCase().replace(/[‘’]/g, "'");
  function matches(title, words) {
    const t = fold(title || '');
    return words.some((w) => {
      const k = fold(w).trim();
      if (!k) return false;
      if (!/^[a-z0-9]/.test(k)) return t.indexOf(k) >= 0;
      const esc = k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      return new RegExp('(^|[^a-z0-9])' + esc + '($|[^a-z0-9])').test(t);
    });
  }

  /* Locations that say nothing about where: a link, a dial-in number, a call app, "TBC". */
  const NOWHERE = ['tbc', 'tbd', 'tba', 'n/a', 'online', 'virtual', 'remote', 'phone', 'mobile', 'call', 'dial-in', 'dial in',
    'teams', 'zoom', 'facetime', 'whatsapp', 'slack', 'skype', 'webex'];
  const PHONE = /\+?\d[\d ().-]{7,}\d/;
  const ROOM_CODE = /(^|[^a-z0-9])[a-z]{2,5}-\d{2,4}($|[^a-z0-9])/i;     // MTL-210

  /*
   * Where a meeting is, from its location:
   *   office — yours (places.office)
   *   room   — a Solotech room: booked on the invite, named with a word in
   *            places.rooms, or a code like MTL-210
   *   away   — anywhere else: a client, a venue, a restaurant
   *   null   — no location, or one that says nothing about where
   * Outlook joins several locations with "; ".
   */
  function placeOf(ev, cfg) {
    const places = (cfg || DEFAULTS).places;
    let office = false, room = (ev.rooms || []).length > 0, away = false;
    for (const raw of (ev.location || '').split(';')) {
      const part = raw.trim();
      if (!part || JOIN_PLACES.test(part) || JOIN_HOSTS.test(part) || /https?:\/\/|www\./i.test(part)) continue;
      if (matches(part, places.office)) office = true;
      else if (matches(part, places.rooms) || ROOM_CODE.test(part)) room = true;
      else if (/\p{L}/u.test(part) && !PHONE.test(part) && !matches(part, NOWHERE)) away = true;
    }
    return office ? 'office' : room ? 'room' : away ? 'away' : null;
  }

  /*
   * What an event means for the sign:
   *   ignore   — cancelled (or titled "Canceled: …"), Show As Free, or an all-day event that isn't busy
   *   ooo      — Show As Out of Office, an all-day busy event, or ✈ in your own block's title
   *   onSite   — the same with "on site" in the title, or a meeting somewhere that isn't Solotech's
   *   call     — has a Teams / Zoom / Meet link, and no location that says where
   *   inPerson — has invitees and no link, or a link and your office or a room as the location;
   *              `room` when it's in one of Solotech's rooms, not your office
   *   lunch / dndBlock / phone / away — your own blocks, by title
   * Where beats how: a meeting's location says where you'll be, and a link
   * only that others can dial in. `tentative` is Show As Tentative, for calls
   * and meetings: CALL TBC / BUSY TBC (an off-site one too: you may not go).
   */
  function classify(ev, cfg) {
    const c = cfg || DEFAULTS, kw = c.keywords;
    const out = (kind, room) => ({ kind: kind, room: !!room,
      tentative: ev.availability === 'tentative' && (kind === 'call' || kind === 'inPerson') });
    if (ev.cancelled || /^cancell?ed:/i.test(ev.title || '') || ev.availability === 'free') return out('ignore');
    const gone = matches(ev.title, kw.onSite) ? 'onSite' : 'ooo';
    if (ev.allDay) return out(ev.availability === 'busy' || ev.availability === 'ooo' ? gone : 'ignore');
    if (ev.availability === 'ooo') return out(gone);
    const link = hasJoinLink(ev);
    if (ev.attendees > 0) {
      const place = placeOf(ev, c);
      if (place === 'away') return out(ev.availability === 'tentative' ? 'inPerson' : 'onSite');
      if (link && place === null) return out('call');
      return out('inPerson', place === 'room');
    }
    if (link) return out('call');
    if (matches(ev.title, kw.onSite)) return out('onSite');
    if (matches(ev.title, kw.ooo)) return out('ooo');
    if (matches(ev.title, kw.lunch)) return out('lunch');
    if (matches(ev.title, kw.dnd)) return out('dndBlock');
    if (matches(ev.title, kw.call)) return out('phone');
    return out('away');
  }

  /*
   * Whether you've been on the mic for this event: a mic session that began
   * between a few minutes before it and now. A session already running from
   * the previous call doesn't count, so overrunning one call into the next
   * still shows LATE for the next.
   */
  function joined(ev, sessions, now, cfg) {
    const early = cfg.joinEarlyMinutes * MINUTE;
    return sessions.some((s) => s.start >= ev.start - early && s.start <= Math.min(now, ev.end));
  }

  /*
   * When you're next free: the end of the call or meeting you're in, carried
   * on through any that follow back to back. Calls, meetings and calendar
   * phone calls count, tentative ones too; lunch and your own blocks don't.
   */
  function busyUntil(anchor, evs, cfg) {
    const work = evs.filter((x) => x.kind === 'call' || x.kind === 'inPerson' || x.kind === 'phone');
    const gap = cfg.chainGapMinutes * MINUTE;
    let end = anchor.end, grew = true;
    while (grew) {
      grew = false;
      for (const x of work) if (x.start > anchor.start && x.start <= end + gap && x.end > end) { end = x.end; grew = true; }
    }
    return end;
  }

  /*
   * Whether something on the sign follows this event straight after: any
   * event in the calendar — a call, a meeting, lunch, a block of your own —
   * starting after now and no more than a few minutes after this one ends,
   * and still on after it. Leave a call early and the sign says FREE TILL
   * its end only then; with nothing straight after, you're just free.
   */
  function followed(e, evs, now, cfg) {
    const gap = cfg.chainGapMinutes * MINUTE;
    return evs.some((x) => x.start > now && x.start <= e.end + gap && x.end > e.end);
  }

  /*
   * The sign at `now`.
   *   input = { now, override: 'auto' | 'onCall' | 'free', dndUntil (ms or null),
   *             away: 'nearby' | 'lunch' | 'backIn' | null  — the away keys,
   *             awayUntil (ms or null)  — when you'll be back, for 'backIn',
   *             locked  — the Mac is locked, or its screen saver is on,
   *             active  — someone's used the Mac in the last couple of minutes,
   *             inPerson: [event ids]  — calls you said you're at in person,
   *             micSessions: [{ start, end }]  — debounced, end null while on,
   *             events: [...], config }
   * Returns { state, left, at, event, why }:
   *   state — an engine state; left — seconds to go (or since, for LATE);
   *   at — the moment the state is about (ms); event — the event behind it.
   * ON A CALL and MEETING count down to when you're free: the end of the
   * event, carried through back-to-back ones (busyUntil).
   */
  function decide(input) {
    const cfg = Object.assign({}, DEFAULTS, input.config || {});
    cfg.keywords = Object.assign({}, DEFAULTS.keywords, (input.config || {}).keywords || {});
    cfg.places = Object.assign({}, DEFAULTS.places, (input.config || {}).places || {});
    const now = input.now;
    const sessions = input.micSessions || [];
    const marked = input.inPerson || [];
    const sign = (state, why, extra) => Object.assign({ state: state, why: why, event: null }, extra || {});

    const evs = (input.events || []).map((e) => {
      const c = classify(e, cfg);
      // you said you're there in person: a call becomes a meeting, and a room never says LATE
      c.here = marked.indexOf(e.id) >= 0;
      if (c.here && c.kind === 'call') c.kind = 'inPerson';
      return Object.assign({}, e, c);
    })
      .filter((e) => e.kind !== 'ignore')
      .sort((a, b) => a.start - b.start || a.end - b.end);
    const current = evs.filter((e) => e.start <= now && now < e.end);
    const lead = cfg.leadMinutes * MINUTE, late = cfg.lateMinutes * MINUTE;
    const first = (pred) => current.find(pred);
    const quote = (e) => '“' + (e.title || 'Untitled') + '”';
    // busy until the end of this event and any back to back after it: a countdown to free
    const until = (x) => { const end = busyUntil(x, evs, cfg); return { event: x, left: (end - now) / 1000, at: end }; };
    let e;

    // 1. you said so
    if (input.override === 'onCall') return sign('call', 'Forced ON A CALL');
    if (input.override === 'free') return sign('free', 'Forced FREE');
    // 2. the microphone: counting down to the end of the call it's for, if the calendar has one
    if (sessions.some((s) => s.start <= now && (s.end == null || s.end > now))) {
      const early = cfg.joinEarlyMinutes * MINUTE;
      const on = evs.filter((x) => (x.kind === 'call' || x.kind === 'inPerson' || x.kind === 'phone') &&
        x.start - early <= now && now < x.end);
      if (!on.length) return sign('call', 'Microphone in use');
      const anchor = on.reduce((a, b) => (busyUntil(b, evs, cfg) > busyUntil(a, evs, cfg) ? b : a));
      return sign('call', 'On ' + quote(anchor), until(anchor));
    }
    // 3. the away keys: where you said you'd be. Back in a few minutes counts down; once it's
    //    up, it gives way to what's next
    if (input.away === 'backIn' && input.awayUntil != null && input.awayUntil > now) {
      return sign('backIn', 'Away key: back in a few minutes', { left: (input.awayUntil - now) / 1000, at: input.awayUntil });
    }
    if (input.away === 'nearby') return sign('nearby', 'Away key: nearby');
    if (input.away === 'lunch') return sign('lunch', 'Away key: lunch');
    // 4. a double-click — waiting while the Mac's locked, as under a call: you're not at your desk
    if (input.dndUntil != null && input.dndUntil > now && !input.locked) {
      return sign('dnd', 'Do Not Disturb', { left: (input.dndUntil - now) / 1000, at: input.dndUntil });
    }

    // 5. the calendar

    // not here: out of office, out on site, your own blocks — these outrank meetings, warnings included
    if ((e = first((x) => x.kind === 'ooo'))) return sign('ooo', 'Out of office: ' + quote(e), { event: e, at: e.end });
    if ((e = first((x) => x.kind === 'onSite'))) return sign('onSite', 'Out on site: ' + quote(e), { event: e, at: e.end });
    if ((e = first((x) => x.kind === 'lunch'))) return sign('lunch', 'Lunch: ' + quote(e), { event: e, at: e.end });
    if ((e = first((x) => x.kind === 'away'))) return sign('away', 'Away: ' + quote(e), { event: e, at: e.end });
    if ((e = first((x) => x.kind === 'phone'))) return sign('call', 'Call in your calendar: ' + quote(e), until(e));

    // in a meeting, or should be: a meeting in a room that's started with you still at the Mac
    if ((e = first((x) => x.kind === 'inPerson' && x.room && !x.tentative && !x.here && now - x.start < late &&
      input.active && !input.locked && !joined(x, sessions, now, cfg)))) {
      return sign('lateMtg', 'Late for ' + quote(e), { event: e, left: (now - e.start) / 1000, at: e.start });
    }
    if ((e = first((x) => x.kind === 'inPerson' && !x.tentative))) {
      return sign('meeting', (e.here ? 'In person: ' : e.room ? 'In a meeting, in a room: ' : 'In a meeting: ') + quote(e), until(e));
    }
    // or on a call: late for it, then — never joined — in it in person
    if ((e = first((x) => x.kind === 'call' && !x.tentative && now - x.start < late && !joined(x, sessions, now, cfg)))) {
      return sign('late', 'Late for ' + quote(e), { event: e, left: (now - e.start) / 1000, at: e.start });
    }
    if ((e = first((x) => x.kind === 'call' && !x.tentative && !joined(x, sessions, now, cfg)))) {
      return sign('meeting', 'Never joined ' + quote(e) + ': in person', until(e));
    }

    // about to be busy
    const upcoming = evs.filter((x) => (x.kind === 'call' || x.kind === 'inPerson') && x.start > now && x.start - now <= lead);
    const soon = upcoming.find((x) => !x.tentative);
    if (soon) {
      return sign(soon.kind === 'call' ? 'callIn' : 'busyIn', (soon.kind === 'call' ? 'Call' : 'Meeting') + ' soon: ' + quote(soon),
        { event: soon, left: (soon.start - now) / 1000, at: soon.start });
    }
    const tbc = (x) => (x.kind === 'call' ? 'callTbc' : 'busyTbc');
    if ((e = first((x) => x.tentative))) return sign(tbc(e), 'Tentative: ' + quote(e), { event: e, at: e.end });
    if (upcoming.length) {
      e = upcoming[0];
      return sign(tbc(e), 'Tentative, soon: ' + quote(e), { event: e, left: (e.start - now) / 1000, at: e.start });
    }

    // the Mac locked, with nothing above to say where you are: around somewhere
    if (input.locked) return sign('nearby', 'Mac locked');

    // a no-meetings block, then a call you've left early with something straight after it
    if ((e = first((x) => x.kind === 'dndBlock'))) return sign('dnd', 'Do Not Disturb block: ' + quote(e), { event: e, at: e.end });
    if ((e = first((x) => x.kind === 'call' && joined(x, sessions, now, cfg) && followed(x, evs, now, cfg)))) {
      return sign('freeTil', 'Left ' + quote(e) + ' early', { event: e, at: e.end });
    }

    // 6. nothing on
    return sign('free', 'Free');
  }

  root.BusyRules = { DEFAULTS: DEFAULTS, classify: classify, decide: decide, hasJoinLink: hasJoinLink, matches: matches, placeOf: placeOf };
})(typeof window !== 'undefined' ? window : globalThis);
