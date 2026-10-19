import Foundation

/*
 * The status rules: what the sign says, from the manual controls, the
 * microphone and the calendar.
 *
 * A line-for-line port of simulator/rules.js. Keep them in step: the
 * simulator is where the rules are designed and checked, and
 * Checks/rules compares this file's decisions with that file's, case by
 * case. Pure: no clocks, no EventKit, no time zones. Times are
 * milliseconds since 1970, as in JavaScript.
 */

/// An event as read from macOS Calendar, reduced to what the rules need.
struct CalEvent: Equatable {
    enum Availability: String { case busy, free, tentative, ooo }   // Outlook's Show As

    var id: String
    var title: String
    var start: Double                   // ms
    var end: Double
    var allDay = false
    var availability: Availability = .busy
    var attendees = 0                   // invitees; 0 for your own blocks
    var rooms: [String] = []            // the rooms booked on it, by name
    var notes = ""
    var location = ""
    var url = ""
    var cancelled = false
}

/// A stretch with the microphone in use, debounced; `end` is nil while it's on.
struct MicSession: Equatable {
    var start: Double                   // ms
    var end: Double?
}

struct StatusConfig {
    var leadMinutes = 10.0       // CALL IN / BUSY IN this long before
    var lateMinutes = 10.0       // LATE FOR CALL / MTG for at most this long, then MEETING
    var joinEarlyMinutes = 5.0   // a mic opened this long before a call counts as joining it
    var chainGapMinutes = 5.0    // meetings this close together count as back to back
    var keywords = Keywords()
    var places = Places()

    /// Words in the titles of your own events (ones with no invitees).
    /// Matched as whole words, any case; the first list that matches wins.
    struct Keywords {
        var onSite = ["on site", "onsite", "on-site"]
        var ooo = ["✈", "out of office", "ooo"]
        var lunch = ["lunch"]
        var dnd = ["no meetings", "focus", "do not disturb"]
        var call = ["call"]
    }

    /// Words in a meeting's location, matched the same way: your own office,
    /// Solotech's rooms (a room booked on the invite counts whatever its name),
    /// and Solotech's sites — somewhere at Solotech, not saying which room.
    struct Places {
        var office = ["my office", "woody's office"]
        var rooms = ["room", "huddle", "boardroom"]
        var sites = ["solotech"]
    }
}

struct StatusInput {
    var now: Double                     // ms
    var override = "auto"               // Override's raw value: auto, onCall, free
    var dndUntil: Double? = nil         // ms
    var away: String? = nil             // the away keys: nearby, lunch, backIn
    var awayUntil: Double? = nil        // ms: when you'll be back, for backIn
    var locked = false                  // the Mac is locked, or its screen saver is on
    var active = false                  // someone's used the Mac in the last couple of minutes
    var inPerson: [String] = []         // the ids of calls you said you're at in person
    var micSessions: [MicSession] = []
    var events: [CalEvent] = []
    var config = StatusConfig()
}

/// What the sign says, and why.
struct StatusDecision: Equatable {
    var state: String                   // a BarState raw value
    var why: String
    var left: Double? = nil             // seconds to go (or since, for LATE)
    var at: Double? = nil               // the moment the state is about, ms
    var eventID: String? = nil
    var eventTitle: String? = nil
}

enum StatusRules {
    static let minute = 60.0 * 1000

    enum Kind: String { case ignore, ooo, onSite, call, inPerson, lunch, dndBlock, phone, away }

    /* Where a call's join link lives. Outlook puts it in the notes (wrapped in
       safelinks, which still carries the host in plain text) or names the
       service in the location. */
    static let joinHosts = #"teams\.microsoft\.com|teams\.live\.com|zoom\.us|zoomgov\.com|meet\.google\.com|webex\.com|gotomeeting\.com|whereby\.com|chime\.aws"#
    static let joinPlaces = #"microsoft teams|teams meeting|zoom meeting|google meet|webex"#

    private static func find(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func hasJoinLink(_ ev: CalEvent) -> Bool {
        let text = [ev.notes, ev.url].filter { !$0.isEmpty }.joined(separator: "\n")
        if find(joinHosts, in: text) || find(joinHosts, in: safeDecode(text)) { return true }
        return find(joinPlaces, in: ev.location) || find(joinHosts, in: ev.location)
    }

    /// Decodes %xx escapes of plain ASCII, one at a time, as rules.js does.
    static func safeDecode(_ s: String) -> String {
        let u = Array(s.utf16)
        var out: [UInt16] = []
        var i = 0
        func hex(_ c: UInt16) -> UInt16? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        while i < u.count {
            if u[i] == 37, i + 2 < u.count, let a = hex(u[i + 1]), let b = hex(u[i + 2]), a * 16 + b < 0x80 {
                out.append(a * 16 + b)
                i += 3
            } else {
                out.append(u[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// Whole-word, any-case match; a keyword that doesn't start with a letter
    /// or digit (✈) matches anywhere. Curly apostrophes count as straight ones
    /// (Outlook types "Woody’s office").
    static func matches(_ title: String, _ words: [String]) -> Bool {
        func fold(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "’", with: "'")
        }
        let t = fold(title)
        return words.contains { w in
            let k = fold(w).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = k.unicodeScalars.first else { return false }
            let alnum = (first.value >= 97 && first.value <= 122) || (first.value >= 48 && first.value <= 57)
            if !alnum { return t.range(of: k, options: .literal) != nil }
            let pattern = "(^|[^a-z0-9])" + NSRegularExpression.escapedPattern(for: k) + "($|[^a-z0-9])"
            return t.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Locations that say nothing about where: a link, a dial-in number, a call app, "TBC".
    static let nowhere = ["tbc", "tbd", "tba", "n/a", "online", "virtual", "remote", "phone", "mobile", "call", "dial-in", "dial in",
                          "teams", "zoom", "facetime", "whatsapp", "slack", "skype", "webex"]
    static let phonePattern = #"\+?\d[\d ().-]{7,}\d"#
    static let roomCode = #"(^|[^a-z0-9])[a-z]{2,5}-\d{2,4}($|[^a-z0-9])"#      // MTL-210

    enum Place { case office, room, site, away }

    /*
     * Where a meeting is, from its location:
     *   office — yours (places.office)
     *   room   — a Solotech room: booked on the invite, named with a word in
     *            places.rooms, or a code like MTL-210
     *   site   — somewhere at Solotech, not saying where (places.sites): "Solotech - Nashville"
     *   away   — anywhere else: a client, a venue, a restaurant
     *   nil    — no location, or one that says nothing about where
     * Outlook joins several locations with "; ".
     */
    static func placeOf(_ ev: CalEvent, _ cfg: StatusConfig = StatusConfig()) -> Place? {
        var office = false, room = !ev.rooms.isEmpty, site = false, away = false
        for raw in ev.location.components(separatedBy: ";") {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if part.isEmpty || find(joinPlaces, in: part) || find(joinHosts, in: part) || find(#"https?://|www\."#, in: part) { continue }
            if matches(part, cfg.places.office) { office = true }
            else if matches(part, cfg.places.rooms) || find(roomCode, in: part) { room = true }
            else if matches(part, cfg.places.sites) { site = true }
            else if find(#"\p{L}"#, in: part) && !find(phonePattern, in: part) && !matches(part, nowhere) { away = true }
        }
        return office ? .office : room ? .room : site ? .site : away ? .away : nil
    }

    /*
     * What an event means for the sign:
     *   ignore   — cancelled (or titled "Canceled: …"), Show As Free, or an all-day event that isn't busy
     *   ooo      — Show As Out of Office, an all-day busy event, or ✈ in your own block's title
     *   onSite   — the same with "on site" in the title, or a meeting somewhere that isn't Solotech's
     *   call     — has a Teams / Zoom / Meet link, and no location that says where
     *   inPerson — has invitees and no link, or a link and your office, a room or a Solotech site
     *              as the location; `room` when it's in one of Solotech's rooms (LATE FOR MTG)
     *   lunch / dndBlock / phone / away — your own blocks, by title
     * Where beats how: a meeting's location says where you'll be, and a link
     * only that others can dial in. `tentative` is Show As Tentative, for calls
     * and meetings: CALL TBC / BUSY TBC (an off-site one too: you may not go).
     */
    static func classify(_ ev: CalEvent, _ cfg: StatusConfig = StatusConfig()) -> (kind: Kind, tentative: Bool, room: Bool) {
        let kw = cfg.keywords
        func out(_ kind: Kind, room: Bool = false) -> (kind: Kind, tentative: Bool, room: Bool) {
            (kind, ev.availability == .tentative && (kind == .call || kind == .inPerson), room)
        }
        if ev.cancelled || find("^cancell?ed:", in: ev.title) || ev.availability == .free { return out(.ignore) }
        let gone: Kind = matches(ev.title, kw.onSite) ? .onSite : .ooo
        if ev.allDay { return out(ev.availability == .busy || ev.availability == .ooo ? gone : .ignore) }
        if ev.availability == .ooo { return out(gone) }
        let link = hasJoinLink(ev)
        if ev.attendees > 0 {
            let place = placeOf(ev, cfg)
            if place == .away { return out(ev.availability == .tentative ? .inPerson : .onSite) }
            if link && place == nil { return out(.call) }
            return out(.inPerson, room: place == .room)
        }
        if link { return out(.call) }
        if matches(ev.title, kw.onSite) { return out(.onSite) }
        if matches(ev.title, kw.ooo) { return out(.ooo) }
        if matches(ev.title, kw.lunch) { return out(.lunch) }
        if matches(ev.title, kw.dnd) { return out(.dndBlock) }
        if matches(ev.title, kw.call) { return out(.phone) }
        return out(.away)
    }

    /// An event with what it means.
    struct Sorted {
        let ev: CalEvent
        let kind: Kind
        let tentative: Bool
        let room: Bool
        let here: Bool                  // you said you're there in person
        var start: Double { ev.start }
        var end: Double { ev.end }
    }

    /*
     * Whether you've been on the mic for this event: a mic session that began
     * between a few minutes before it and now. A session already running from
     * the previous call doesn't count, so overrunning one call into the next
     * still shows LATE for the next.
     */
    static func joined(_ x: Sorted, _ sessions: [MicSession], _ now: Double, _ cfg: StatusConfig) -> Bool {
        let early = cfg.joinEarlyMinutes * minute
        return sessions.contains { $0.start >= x.start - early && $0.start <= min(now, x.end) }
    }

    /*
     * When you're next free: the end of the call or meeting you're in, carried
     * on through any that follow back to back. Calls, meetings and calendar
     * phone calls count, tentative ones too; lunch and your own blocks don't.
     */
    static func busyUntil(_ anchor: Sorted, _ evs: [Sorted], _ cfg: StatusConfig) -> Double {
        let work = evs.filter { $0.kind == .call || $0.kind == .inPerson || $0.kind == .phone }
        let gap = cfg.chainGapMinutes * minute
        var end = anchor.end, grew = true
        while grew {
            grew = false
            for x in work where x.start > anchor.start && x.start <= end + gap && x.end > end {
                end = x.end
                grew = true
            }
        }
        return end
    }

    /*
     * Whether something on the sign follows this event straight after: any
     * event in the calendar — a call, a meeting, lunch, a block of your own —
     * starting after now and no more than a few minutes after this one ends,
     * and still on after it. Leave a call early and the sign says FREE TILL
     * its end only then; with nothing straight after, you're just free.
     */
    static func followed(_ e: Sorted, _ evs: [Sorted], _ now: Double, _ cfg: StatusConfig) -> Bool {
        let gap = cfg.chainGapMinutes * minute
        return evs.contains { $0.start > now && $0.start <= e.end + gap && $0.end > e.end }
    }

    /*
     * The sign at `input.now`. ON A CALL and MEETING count down to when you're
     * free: the end of the event, carried through back-to-back ones.
     */
    static func decide(_ input: StatusInput) -> StatusDecision {
        let cfg = input.config
        let now = input.now
        let sessions = input.micSessions
        func sign(_ state: String, _ why: String, event: Sorted? = nil, left: Double? = nil, at: Double? = nil) -> StatusDecision {
            StatusDecision(state: state, why: why, left: left, at: at, eventID: event?.ev.id, eventTitle: event?.ev.title)
        }

        var numbered: [(i: Int, s: Sorted)] = []
        for (i, e) in input.events.enumerated() {
            let c = classify(e, cfg)
            // you said you're there in person: a call becomes a meeting, and a room never says LATE
            let here = input.inPerson.contains(e.id)
            let kind: Kind = here && c.kind == .call ? .inPerson : c.kind
            if kind != .ignore { numbered.append((i, Sorted(ev: e, kind: kind, tentative: c.tentative, room: c.room, here: here))) }
        }
        let evs: [Sorted] = numbered
            .sorted { a, b in
                if a.s.start != b.s.start { return a.s.start < b.s.start }
                if a.s.end != b.s.end { return a.s.end < b.s.end }
                return a.i < b.i                         // stable, as JavaScript's sort
            }
            .map { $0.s }
        let current = evs.filter { $0.start <= now && now < $0.end }
        let lead = cfg.leadMinutes * minute, late = cfg.lateMinutes * minute
        func first(_ pred: (Sorted) -> Bool) -> Sorted? { current.first(where: pred) }
        func quote(_ e: Sorted) -> String { "“" + (e.ev.title.isEmpty ? "Untitled" : e.ev.title) + "”" }
        // busy until the end of this event and any back to back after it: a countdown to free
        func until(_ state: String, _ why: String, _ x: Sorted) -> StatusDecision {
            let end = busyUntil(x, evs, cfg)
            return sign(state, why, event: x, left: (end - now) / 1000, at: end)
        }

        // 1. you said so
        if input.override == "onCall" { return sign("call", "Forced ON A CALL") }
        if input.override == "free" { return sign("free", "Forced FREE") }
        // 2. the microphone: counting down to the end of the call it's for, if the calendar has one
        if sessions.contains(where: { $0.start <= now && ($0.end == nil || $0.end! > now) }) {
            let early = cfg.joinEarlyMinutes * minute
            let on = evs.filter { ($0.kind == .call || $0.kind == .inPerson || $0.kind == .phone) &&
                                  $0.start - early <= now && now < $0.end }
            guard let firstOn = on.first else { return sign("call", "Microphone in use") }
            let anchor = on.dropFirst().reduce(firstOn) { a, b in busyUntil(b, evs, cfg) > busyUntil(a, evs, cfg) ? b : a }
            return until("call", "On " + quote(anchor), anchor)
        }
        // 3. the away keys: where you said you'd be. Back in a few minutes counts down; once it's
        //    up, it gives way to what's next
        if input.away == "backIn", let back = input.awayUntil, back > now {
            return sign("backIn", "Away key: back in a few minutes", left: (back - now) / 1000, at: back)
        }
        if input.away == "nearby" { return sign("nearby", "Away key: nearby") }
        if input.away == "lunch" { return sign("lunch", "Away key: lunch") }
        // 4. a double-click — waiting while the Mac's locked, as under a call: you're not at your desk
        if let dnd = input.dndUntil, dnd > now, !input.locked {
            return sign("dnd", "Do Not Disturb", left: (dnd - now) / 1000, at: dnd)
        }

        // 5. the calendar
        // not here: out of office, out on site, your own blocks — these outrank meetings, warnings included
        if let e = first({ $0.kind == .ooo }) { return sign("ooo", "Out of office: " + quote(e), event: e, at: e.end) }
        if let e = first({ $0.kind == .onSite }) { return sign("onSite", "Out on site: " + quote(e), event: e, at: e.end) }
        if let e = first({ $0.kind == .lunch }) { return sign("lunch", "Lunch: " + quote(e), event: e, at: e.end) }
        if let e = first({ $0.kind == .away }) { return sign("away", "Away: " + quote(e), event: e, at: e.end) }
        if let e = first({ $0.kind == .phone }) { return until("call", "Call in your calendar: " + quote(e), e) }

        // in a meeting, or should be: a meeting in a room that's started with you still at the Mac
        if let e = first({ $0.kind == .inPerson && $0.room && !$0.tentative && !$0.here && now - $0.start < late &&
                           input.active && !input.locked && !joined($0, sessions, now, cfg) }) {
            return sign("lateMtg", "Late for " + quote(e), event: e, left: (now - e.start) / 1000, at: e.start)
        }
        if let e = first({ $0.kind == .inPerson && !$0.tentative }) {
            return until("meeting", (e.here ? "In person: " : e.room ? "In a meeting, in a room: " : "In a meeting: ") + quote(e), e)
        }
        // or on a call: late for it, then — never joined — in it in person
        if let e = first({ $0.kind == .call && !$0.tentative && now - $0.start < late && !joined($0, sessions, now, cfg) }) {
            return sign("late", "Late for " + quote(e), event: e, left: (now - e.start) / 1000, at: e.start)
        }
        if let e = first({ $0.kind == .call && !$0.tentative && !joined($0, sessions, now, cfg) }) {
            return until("meeting", "Never joined " + quote(e) + ": in person", e)
        }

        // about to be busy
        let upcoming = evs.filter { ($0.kind == .call || $0.kind == .inPerson) && $0.start > now && $0.start - now <= lead }
        if let soon = upcoming.first(where: { !$0.tentative }) {
            return sign(soon.kind == .call ? "callIn" : "busyIn", (soon.kind == .call ? "Call" : "Meeting") + " soon: " + quote(soon),
                        event: soon, left: (soon.start - now) / 1000, at: soon.start)
        }
        func tbc(_ x: Sorted) -> String { x.kind == .call ? "callTbc" : "busyTbc" }
        if let e = first({ $0.tentative }) { return sign(tbc(e), "Tentative: " + quote(e), event: e, at: e.end) }
        if let e = upcoming.first {
            return sign(tbc(e), "Tentative, soon: " + quote(e), event: e, left: (e.start - now) / 1000, at: e.start)
        }

        // the Mac locked, with nothing above to say where you are: around somewhere
        if input.locked { return sign("nearby", "Mac locked") }

        // a no-meetings block, then a call you've left early with something straight after it
        if let e = first({ $0.kind == .dndBlock }) { return sign("dnd", "Do Not Disturb block: " + quote(e), event: e, at: e.end) }
        if let e = first({ $0.kind == .call && joined($0, sessions, now, cfg) && followed($0, evs, now, cfg) }) {
            return sign("freeTil", "Left " + quote(e) + " early", event: e, at: e.end)
        }

        // 6. nothing on
        return sign("free", "Free")
    }
}
