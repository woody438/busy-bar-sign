import Foundation

/*
 * The words Teams and Zoom use, as patterns: what the mic button's name
 * says about mute, what a post-call survey says, which of its buttons only
 * close it and which are never pressed, and what a meeting window says
 * once the call is over. Ported from Teams Meeting Keys (teams-ui.json),
 * and like it overridable from a JSON file without a new build. Also
 * which Teams or Zoom window is which, by its title.
 *
 * Pure, so Checks/meeting tries them anywhere Swift runs.
 */

/// The meeting apps whose controls the app reads and presses.
enum MeetingApp: String, CaseIterable, Codable {
    case teams, zoom

    var label: String { self == .teams ? "Teams" : "Zoom" }

    /// Their bundle IDs, newest first: new Teams, then classic.
    var bundleIDs: [String] {
        switch self {
        case .teams: return ["com.microsoft.teams2", "com.microsoft.teams"]
        case .zoom: return ["us.zoom.xos"]
        }
    }

    init?(bundleID: String) {
        guard let app = MeetingApp.allCases.first(where: { $0.bundleIDs.contains(bundleID) }) else { return nil }
        self = app
    }
}

struct MeetingPatterns {
    /// A mic button's name and the mute state it implies. The button is
    /// named for what pressing it does, so "Unmute" means you're muted now.
    struct MuteRule {
        let pattern: NSRegularExpression
        let muted: Bool
    }

    var muteRules: [MuteRule]
    var survey: NSRegularExpression
    var dismiss: NSRegularExpression
    var never: NSRegularExpression
    var ended: NSRegularExpression

    /// What a patterns file holds (teams-ui.json's format). Anything left out
    /// keeps the shipped pattern.
    struct Config: Codable, Equatable {
        struct Rule: Codable, Equatable {
            var pattern: String
            var muted: Bool
        }
        var muteRules: [Rule]?
        var surveyText: String?
        var dismissButton: String?
        var neverPress: String?
        var meetingEnded: String?
    }

    static let shippedConfig = Config(
        muteRules: [
            .init(pattern: #"(?i)^\s*mute\b"#, muted: false),
            .init(pattern: #"(?i)\bturn off (your )?(mic|microphone)\b|\bturn (your )?(mic|microphone) off\b"#, muted: false),
            .init(pattern: #"(?i)\bunmute\b"#, muted: true),
            .init(pattern: #"(?i)\bturn on (your )?(mic|microphone)\b|\bturn (your )?(mic|microphone) on\b"#, muted: true),
            .init(pattern: #"(?i)\b(mic|microphone) (is )?(off|muted)\b"#, muted: true),
            .init(pattern: #"(?i)\b(mic|microphone) (is )?(on|live|unmuted)\b"#, muted: false),
            // Teams in French
            .init(pattern: #"(?i)^\s*(désactiver|couper) (le )?micro"#, muted: false),
            .init(pattern: #"(?i)^\s*(activer|rétablir) (le )?micro"#, muted: true)
        ],
        surveyText: #"(?i)call quality|rate my call|rate (your|this|the) (call|meeting)|how was (the|your|this) (call|meeting)"#
            + #"|how did (the|your|this) (call|meeting) go|thumbs (up|down)|how likely are you to recommend"#
            + #"|would you recommend (microsoft )?teams|tell us (about|how) (the|your) (call|meeting)"#
            + #"|how was (the )?(audio|video)( and (audio|video))?( quality)?"#,
        dismissButton: #"(?i)^\s*(dismiss|close|skip|not now|no,? thanks|maybe later|cancel|close (this )?(dialog|survey|feedback|window|panel|pop-?up))\s*(\(.*\))?\s*$"#,
        neverPress: #"(?i)submit|send|thumbs|rejoin|leave|end (the )?(meeting|call)|end for everyone|stop|delete|remove|sign out|report|good|issue|audio|video|screen ?share"#,
        meetingEnded: #"(?i)^\s*rejoin\b|you left the (meeting|call)|the (meeting|call) (has )?ended|\bcall ended\b|\bmeeting ended\b"#
    )

    static let shipped = compile(shippedConfig).patterns

    /// Compiles a config. A pattern that doesn't compile keeps the shipped
    /// one, and is named in `problems` so it can be shown.
    static func compile(_ c: Config) -> (patterns: MeetingPatterns, problems: [String]) {
        let def = shippedConfig
        var problems: [String] = []

        func one(_ name: String, _ src: String?, _ fallback: String) -> NSRegularExpression {
            let source = (src ?? "").isEmpty ? fallback : src!
            do { return try NSRegularExpression(pattern: source) } catch {
                problems.append("\(name): doesn't compile (using the default)")
                return try! NSRegularExpression(pattern: fallback)
            }
        }

        let survey = one("surveyText", c.surveyText, def.surveyText!)
        let dismiss = one("dismissButton", c.dismissButton, def.dismissButton!)
        let never = one("neverPress", c.neverPress, def.neverPress!)
        let ended = one("meetingEnded", c.meetingEnded, def.meetingEnded!)

        var rules: [MuteRule] = []
        let given = (c.muteRules ?? []).isEmpty ? def.muteRules! : c.muteRules!
        for (i, r) in given.enumerated() {
            guard let re = try? NSRegularExpression(pattern: r.pattern) else {
                problems.append("muteRules[\(i)]: doesn't compile (skipped)")
                continue
            }
            rules.append(MuteRule(pattern: re, muted: r.muted))
        }
        if rules.isEmpty {
            rules = def.muteRules!.map { MuteRule(pattern: try! NSRegularExpression(pattern: $0.pattern), muted: $0.muted) }
        }
        return (MeetingPatterns(muteRules: rules, survey: survey, dismiss: dismiss, never: never, ended: ended), problems)
    }

    /// Reads a patterns file. A file that's missing gives the shipped
    /// patterns; one that isn't valid JSON says so.
    static func load(_ url: URL) -> (patterns: MeetingPatterns, problems: [String]) {
        guard let data = try? Data(contentsOf: url) else { return (shipped, []) }
        guard let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return (shipped, ["\(url.lastPathComponent) isn't valid JSON (using the defaults)"])
        }
        return compile(config)
    }

    /// The mute state a mic button's name implies, or nil when it says nothing about it.
    func muted(byLabel label: String) -> Bool? {
        muteRules.first(where: { Self.matches($0.pattern, label) })?.muted
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: Zoom (fixed: these are menu titles, not things to tune)

    /// Zoom's Meeting menu item, there only in a meeting: "Mute audio", "Unmute audio" or "Join audio".
    static let zoomMuteItem = try! NSRegularExpression(pattern: #"(?i)^\s*((un)?mute|join) audio\b"#)
    static let zoomMeetingWindow = try! NSRegularExpression(pattern: #"(?i)\bzoom (meeting|webinar)\b"#)
    static let zoomMainWindow = try! NSRegularExpression(pattern: #"(?i)^\s*zoom( workplace)?\s*$"#)
    static let zoomLeaveButton = try! NSRegularExpression(pattern: #"(?i)^\s*leave( the)? meeting\s*$"#)
    static let zoomEndForAll = try! NSRegularExpression(pattern: #"(?i)end (the )?meeting for all"#)
    /// "Assign a new host", what Zoom asks a host who leaves.
    static let zoomAssignAndLeave = try! NSRegularExpression(pattern: #"(?i)^\s*assign and leave\s*$"#)
}

// MARK: - Windows

/// What a meeting app's window is, by its title.
enum MeetingWindowKind: String {
    case empty, main, compact, meeting, other
}

enum MeetingWindows {
    /// The first part of the main Teams window's title: "Chat | Mickey | Microsoft Teams".
    static let mainSections: Set<String> = [
        "activity", "chat", "teams", "teams and channels", "calendar", "calls", "onedrive", "files", "apps",
        "copilot", "communities", "assignments", "approvals", "planner", "shifts", "people", "viva engage",
        "viva insights", "search", "settings", "help", "notifications", "microsoft teams"
    ]

    /// Teams' main window from its meeting windows, by title.
    static func teamsKind(_ title: String) -> MeetingWindowKind {
        let t = title.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .empty }
        let first = (t.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        if mainSections.contains(first) { return .main }
        let lower = t.lowercased()
        if lower.replacingOccurrences(of: " ", with: "").contains("|calendar|") { return .main }
        if lower.contains("compact view") { return .compact }
        return .meeting
    }

    static func kind(_ app: MeetingApp, title: String, subrole: String) -> MeetingWindowKind {
        if app == .teams { return teamsKind(title) }
        if MeetingPatterns.matches(MeetingPatterns.zoomMeetingWindow, title) { return .meeting }
        if MeetingPatterns.matches(MeetingPatterns.zoomMainWindow, title), subrole.isEmpty || subrole == "AXStandardWindow" {
            return .main
        }
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        return .other
    }

    /// The window a keyboard shortcut goes to: the one named by the hint,
    /// else the first meeting window, else (Teams) a compact meeting view.
    static func pick(_ app: MeetingApp, titles: [String], hint: String) -> String? {
        let usable = titles.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let h = hint.trimmingCharacters(in: .whitespaces).lowercased()
        if !h.isEmpty, let t = usable.first(where: { $0.lowercased().contains(h) }) { return t }
        if let t = usable.first(where: { kind(app, title: $0, subrole: "") == .meeting }) { return t }
        if app == .teams, let t = usable.first(where: { teamsKind($0) == .compact }) { return t }
        return nil
    }
}
