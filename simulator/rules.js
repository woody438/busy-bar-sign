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
 *     notes, location, url, cancelled }
 */
(function (root) {
  'use strict';

  const MINUTE = 60 * 1000;

  const DEFAULTS = {
    leadMinutes: 10,      // CALL IN / BUSY IN / MAYBE IN this long before
    lateMinutes: 10,      // LATE FOR CALL for at most this long, then FREE
    joinEarlyMinutes: 5,  // a mic opened this long before a call counts as joining it
    // Words in the titles of your own events (ones with no invitees).
    // Matched as whole words, any case; the first list that matches wins.
    keywords: {
      ooo: ['✈', 'out of office', 'ooo'],
      lunch: ['lunch'],
      dnd: ['no meetings', 'focus', 'do not disturb'],
      call: ['call']
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
     or digit (✈) matches anywhere. */
  function matches(title, words) {
    const t = (title || '').toLowerCase();
    return words.some((w) => {
      const k = w.toLowerCase().trim();
      if (!k) return false;
      if (!/^[a-z0-9]/.test(k)) return t.indexOf(k) >= 0;
      const esc = k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      return new RegExp('(^|[^a-z0-9])' + esc + '($|[^a-z0-9])').test(t);
    });
  }

  /*
   * What an event means for the sign:
   *   ignore   — cancelled, Show As Free, or an all-day event that isn't busy
   *   ooo      — Show As Out of Office, an all-day busy event, or ✈ in your own block's title
   *   call     — has a Teams / Zoom / Meet link
   *   inPerson — has invitees but no link
   *   lunch / dndBlock / phone / away — your own blocks, by title
   * `tentative` is Show As Tentative, for calls and meetings.
   */
  function classify(ev, cfg) {
    const kw = (cfg || DEFAULTS).keywords;
    const out = (kind) => ({ kind: kind, tentative: ev.availability === 'tentative' && (kind === 'call' || kind === 'inPerson') });
    if (ev.cancelled || ev.availability === 'free') return out('ignore');
    if (ev.allDay) return out(ev.availability === 'busy' || ev.availability === 'ooo' ? 'ooo' : 'ignore');
    if (ev.availability === 'ooo') return out('ooo');
    if (hasJoinLink(ev)) return out('call');
    if (ev.attendees > 0) return out('inPerson');
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
   * The sign at `now`.
   *   input = { now, override: 'auto' | 'onCall' | 'free', dndUntil (ms or null),
   *             micSessions: [{ start, end }]  — debounced, end null while on,
   *             events: [...], config }
   * Returns { state, left, at, event, why }:
   *   state — an engine state; left — seconds to go (or since, for LATE);
   *   at — the moment the state is about (ms); event — the event behind it.
   */
  function decide(input) {
    const cfg = Object.assign({}, DEFAULTS, input.config || {});
    cfg.keywords = Object.assign({}, DEFAULTS.keywords, (input.config || {}).keywords || {});
    const now = input.now;
    const sessions = input.micSessions || [];
    const sign = (state, why, extra) => Object.assign({ state: state, why: why, event: null }, extra || {});

    // 1. you said so
    if (input.override === 'onCall') return sign('call', 'Forced ON A CALL');
    if (input.override === 'free') return sign('free', 'Forced FREE');
    // 2. the microphone
    if (sessions.some((s) => s.start <= now && (s.end == null || s.end > now))) return sign('call', 'Microphone in use');
    // 3. a double-click
    if (input.dndUntil != null && input.dndUntil > now) {
      return sign('dnd', 'Do Not Disturb', { left: (input.dndUntil - now) / 1000, at: input.dndUntil });
    }

    // 4. the calendar
    const evs = (input.events || []).map((e) => Object.assign({}, e, classify(e, cfg)))
      .filter((e) => e.kind !== 'ignore')
      .sort((a, b) => a.start - b.start || a.end - b.end);
    const current = evs.filter((e) => e.start <= now && now < e.end);
    const lead = cfg.leadMinutes * MINUTE, late = cfg.lateMinutes * MINUTE;
    const first = (pred) => current.find(pred);
    const quote = (e) => '“' + (e.title || 'Untitled') + '”';
    let e;

    // not here, by your own blocks — these outrank meetings, warnings included
    if ((e = first((x) => x.kind === 'ooo'))) return sign('ooo', 'Out of office: ' + quote(e), { event: e, at: e.end });
    if ((e = first((x) => x.kind === 'lunch'))) return sign('lunch', 'Lunch: ' + quote(e), { event: e, at: e.end });
    if ((e = first((x) => x.kind === 'away'))) return sign('away', 'Away: ' + quote(e), { event: e, at: e.end });
    if ((e = first((x) => x.kind === 'phone'))) return sign('call', 'Call in your calendar: ' + quote(e), { event: e, at: e.end });

    // in a meeting, or should be on a call
    if ((e = first((x) => x.kind === 'inPerson' && !x.tentative))) {
      return sign('meeting', 'In a meeting: ' + quote(e), { event: e, at: e.end });
    }
    if ((e = first((x) => x.kind === 'call' && !x.tentative && now - x.start < late && !joined(x, sessions, now, cfg)))) {
      return sign('late', 'Late for ' + quote(e), { event: e, left: (now - e.start) / 1000, at: e.start });
    }

    // about to be busy
    const upcoming = evs.filter((x) => (x.kind === 'call' || x.kind === 'inPerson') && x.start > now && x.start - now <= lead);
    const soon = upcoming.find((x) => !x.tentative);
    if (soon) {
      return sign(soon.kind === 'call' ? 'callIn' : 'busyIn', (soon.kind === 'call' ? 'Call' : 'Meeting') + ' soon: ' + quote(soon),
        { event: soon, left: (soon.start - now) / 1000, at: soon.start });
    }
    if ((e = first((x) => x.tentative))) return sign('tentative', 'Tentative: ' + quote(e), { event: e, at: e.end });
    if (upcoming.length) {
      e = upcoming[0];
      return sign('maybeIn', 'Tentative soon: ' + quote(e), { event: e, left: (e.start - now) / 1000, at: e.start });
    }

    // a no-meetings block, then a call you've left early
    if ((e = first((x) => x.kind === 'dndBlock'))) return sign('dnd', 'Do Not Disturb block: ' + quote(e), { event: e, at: e.end });
    if ((e = first((x) => x.kind === 'call' && joined(x, sessions, now, cfg)))) {
      return sign('freeTil', 'Left ' + quote(e) + ' early', { event: e, at: e.end });
    }

    // 5. nothing on
    return sign('free', 'Free');
  }

  root.BusyRules = { DEFAULTS: DEFAULTS, classify: classify, decide: decide, hasJoinLink: hasJoinLink, matches: matches };
})(typeof window !== 'undefined' ? window : globalThis);
