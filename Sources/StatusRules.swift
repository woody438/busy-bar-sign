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
    var lateMinutes = 10.0       // LATE FOR CALL for at most this long, then FREE
    var joinEarlyMinutes = 5.0   // a mic opened this long before a call counts as joining it
    var chainGapMinutes = 5.0    // meetings this close together count as back to back
    var keywords = Keywords()

    /// Words in the titles of your own events (ones with no invitees).
    /// Matched as whole words, any case; the first list that matches wins.
    struct Keywords {
        var ooo = ["✈", "out of office", "ooo"]
        var lunch = ["lunch"]
        var dnd = ["no meetings", "focus", "do not disturb"]
        var call = ["call"]
    }
}

struct StatusInput {
    var now: Double                     // ms
    var override = "auto"               // Override's raw value: auto, onCall, free
    var dndUntil: Double? = nil         // ms
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

    enum Kind: String { case ignore, ooo, call, inPerson, lunch, dndBlock, phone, away }

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
    /// or digit (✈) matches anywhere.
    static func matches(_ title: String, _ words: [String]) -> Bool {
        let t = title.lowercased()
        return words.contains { w in
            let k = w.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = k.unicodeScalars.first else { return false }
            let alnum = (first.value >= 97 && first.value <= 122) || (first.value >= 48 && first.value <= 57)
            if !alnum { return t.range(of: k, options: .literal) != nil }
            let pattern = "(^|[^a-z0-9])" + NSRegularExpression.escapedPattern(for: k) + "($|[^a-z0-9])"
            return t.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /*
     * What an event means for the sign:
     *   ignore   — cancelled (or titled "Canceled: …"), Show As Free, or an all-day event that isn't busy
     *   ooo      — Show As Out of Office, an all-day busy event, or ✈ in your own block's title
     *   call     — has a Teams / Zoom / Meet link
     *   inPerson — has invitees but no link
     *   lunch / dndBlock / phone / away — your own blocks, by title
     * `tentative` is Show As Tentative, for calls and meetings: CALL TBC / BUSY TBC.
     */
    static func classify(_ ev: CalEvent, _ cfg: StatusConfig = StatusConfig()) -> (kind: Kind, tentative: Bool) {
        let kw = cfg.keywords
        func out(_ kind: Kind) -> (kind: Kind, tentative: Bool) {
            (kind, ev.availability == .tentative && (kind == .call || kind == .inPerson))
        }
        if ev.cancelled || find("^cancell?ed:", in: ev.title) || ev.availability == .free { return out(.ignore) }
        if ev.allDay { return out(ev.availability == .busy || ev.availability == .ooo ? .ooo : .ignore) }
        if ev.availability == .ooo { return out(.ooo) }
        if hasJoinLink(ev) { return out(.call) }
        if ev.attendees > 0 { return out(.inPerson) }
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
            if c.kind != .ignore { numbered.append((i, Sorted(ev: e, kind: c.kind, tentative: c.tentative))) }
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
        // 3. a double-click
        if let dnd = input.dndUntil, dnd > now {
            return sign("dnd", "Do Not Disturb", left: (dnd - now) / 1000, at: dnd)
        }

        // 4. the calendar
        // not here, by your own blocks — these outrank meetings, warnings included
        if let e = first({ $0.kind == .ooo }) { return sign("ooo", "Out of office: " + quote(e), event: e, at: e.end) }
        if let e = first({ $0.kind == .lunch }) { return sign("lunch", "Lunch: " + quote(e), event: e, at: e.end) }
        if let e = first({ $0.kind == .away }) { return sign("away", "Away: " + quote(e), event: e, at: e.end) }
        if let e = first({ $0.kind == .phone }) { return until("call", "Call in your calendar: " + quote(e), e) }

        // in a meeting, or should be on a call
        if let e = first({ $0.kind == .inPerson && !$0.tentative }) {
            return until("meeting", "In a meeting: " + quote(e), e)
        }
        if let e = first({ $0.kind == .call && !$0.tentative && now - $0.start < late && !joined($0, sessions, now, cfg) }) {
            return sign("late", "Late for " + quote(e), event: e, left: (now - e.start) / 1000, at: e.start)
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

        // a no-meetings block, then a call you've left early
        if let e = first({ $0.kind == .dndBlock }) { return sign("dnd", "Do Not Disturb block: " + quote(e), event: e, at: e.end) }
        if let e = first({ $0.kind == .call && joined($0, sessions, now, cfg) }) {
            return sign("freeTil", "Left " + quote(e) + " early", event: e, at: e.end)
        }

        // 5. nothing on
        return sign("free", "Free")
    }
}
