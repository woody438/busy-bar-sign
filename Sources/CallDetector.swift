import Combine
import Foundation

enum Override: String, CaseIterable, Identifiable {
    case auto, onCall, free
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto:   return "Automatic"
        case .onCall: return "Force ON A CALL"
        case .free:   return "Force FREE"
        }
    }
}

enum DetectionPolicy: String, CaseIterable, Identifiable {
    /// Anything holding the mic counts, except apps we know aren't calls.
    /// Catches meeting apps we've never heard of — the default.
    case anyExceptIgnored
    /// Only apps on the known-call list count. Fewer false positives,
    /// but a new meeting app won't light the sign until it's added.
    case knownCallAppsOnly

    var id: String { rawValue }
    var label: String {
        switch self {
        case .anyExceptIgnored:  return "Any app except ignored"
        case .knownCallAppsOnly: return "Known call apps only"
        }
    }
}

/// Which apps count. Bundle IDs marked "verify" are best guesses; the menu's
/// Microphone section shows the real ID of anything holding the mic, and can
/// ignore it on the spot.
enum KnownApps {
    /// Third-party apps that hold the microphone but aren't calls. Dictation is
    /// the one that matters most — without this the sign lights on every
    /// sentence.
    static let ignored: Set<String> = [
        "com.wisprflow.flow", "com.wispr.flow", "com.electron.wispr-flow",       // Wispr Flow (verify)
        "com.superduper.superwhisper", "com.goodsnooze.MacWhisper",
        "com.prakashjoshipax.VoiceInk", "com.talonvoice.Talon",
        "ai.krisp.krispMac", "com.krisp.app",                                     // Krisp holds the real mic while on
        "com.ableton.live", "com.avid.ProTools", "com.cockos.reaper",
        "org.audacityteam.audacity", "com.bitwig.BitwigStudio",
        "com.obsproject.obs-studio",
        "com.rogueamoeba.audiohijack", "com.rogueamoeba.soundsource"
    ]

    /// Dictation tools by name, in case their bundle ID isn't one we know.
    static let dictationNames = ["wispr", "whisper", "voiceink", "talon", "krisp"]

    /// Apple's own processes don't count — Siri, Dictation, Live Captions,
    /// Sound Recognition (which listens all the time) — except these, which
    /// are calls. FaceTime's audio runs in avconferenced; Safari's in WebKit.
    static let appleCalls: Set<String> = [
        "com.apple.FaceTime", "com.apple.avconferenced",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"
    ]
    static let appleCallPaths: Set<String> = ["/usr/libexec/avconferenced"]

    /// Used by the "Known call apps only" policy.
    static let calls: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams", "com.microsoft.teams2",
        "com.apple.FaceTime", "com.apple.avconferenced",
        "com.apple.Safari", "com.apple.WebKit.GPU",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser", "company.thebrowser.Browser",
        "com.tinyspeck.slackmacgap",
        "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark",
        "com.hnc.Discord", "com.ringcentral.glip",
        "com.logmein.GoToMeeting", "com.gotomeeting.GoToMeeting",
        "com.bluejeansnet.Blue", "com.loom.desktop",
        "net.whatsapp.WhatsApp", "com.whatsapp.WhatsApp",
        "com.skype.skype", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop"
    ]
}

/// Paths to executables, and the app bundle they belong to.
enum AppPath {
    /// The outermost .app in a path, so a helper resolves to its app:
    /// ".../Google Chrome.app/Contents/Frameworks/.../Google Chrome Helper.app/Contents/MacOS/x"
    /// gives ".../Google Chrome.app".
    static func outermostApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func isSystem(_ path: String) -> Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/Library/Apple/")
    }
}

/// A call app you've added under Settings ▸ Call apps: it counts as a call
/// however Detect is set, and is never ignored.
struct CallApp: Codable, Hashable, Identifiable {
    let id: String          // its bundle ID
    let name: String
}

/// Something holding the microphone, and whether it counts as a call.
struct MicHolder: Equatable, Hashable {
    let name: String
    let bundleID: String?
    let counts: Bool
}

struct Detection: Equatable {
    var onCall = false
    var holders: [MicHolder] = []
    var cameraActive = false
    var attributed = true      // false when we fell back to device-level

    var callApps: [String] { unique(holders.filter(\.counts).map(\.name)) }
    var otherApps: [String] { unique(holders.filter { !$0.counts }.map(\.name)) }

    /// One line describing what the detector sees.
    var sourceLine: String {
        let cam = cameraActive ? "cam active" : "cam idle"
        guard onCall else {
            return otherApps.isEmpty ? "Mic idle · \(cam)"
                                     : "Mic idle · ignored: \(otherApps.joined(separator: ", ")) · \(cam)"
        }
        guard attributed else { return "Mic active (unattributed) · \(cam)" }
        let who = callApps.isEmpty ? "microphone" : callApps.joined(separator: ", ")
        return "Source — \(who) · mic active · \(cam)"
    }

    private func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

/// What the sign shows. A call outranks Do Not Disturb, which carries on
/// underneath it: when the call ends the sign goes back to Do Not Disturb
/// with whatever time is left, or to FREE if it ran out meanwhile.
enum Sign: Equatable {
    case call, dnd, free
}

/// Polls the audio and camera state once a second and debounces it into a
/// stable on/off the wall can be trusted to show. Also keeps the Do Not
/// Disturb timer.
@MainActor
final class CallDetector: ObservableObject {

    @Published private(set) var isOnCall = false
    @Published private(set) var detection = Detection()
    @Published private(set) var changedAt = Date()

    @Published var override: Override = .auto { didSet { evaluate(force: true) } }
    @Published var policy: DetectionPolicy = .anyExceptIgnored { didSet { evaluate() } }

    /// When Do Not Disturb ends, or nil when it's off. Kept across relaunches.
    @Published private(set) var dndUntil: Date? = CallDetector.savedDND()
    /// How long Do Not Disturb lasts when it's turned on.
    var dndLength: TimeInterval = 30 * 60

    var sign: Sign { isOnCall ? .call : (dndUntil != nil ? .dnd : .free) }

    /// The microphone on its own — debounced the same way, whatever the
    /// override says — and the stretches it was in use over the last day,
    /// for the calendar rules: whether you joined a call, and when you left.
    @Published private(set) var micOn = false
    @Published private(set) var micSessions: [MicSession] = []

    /// Apps the user has told us to ignore from the menu, by bundle ID.
    @Published private(set) var userIgnored: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "ignoredBundleIDs") ?? [])

    /// Call apps the user has added (Settings ▸ Call apps), by name.
    @Published private(set) var addedCallApps: [CallApp] = CallDetector.savedCallApps()

    /// How long a signal must hold before the sign follows it. The long tail on
    /// the way down stops the sign flickering when an app briefly drops the mic.
    private let onDelay:  TimeInterval = 2
    private let offDelay: TimeInterval = 10
    /// After the Leave key, the longest the call app may take letting go of
    /// the mic before it counts again: a new call, or a leave that didn't take.
    var leaveGrace: TimeInterval = 20
    /// Polls land a second apart; this stops timer jitter turning "2 s" into 3.
    private let slack:    TimeInterval = 0.25

    private var candidateSince: TimeInterval?
    private var candidate = false
    private var micCandidateSince: TimeInterval?
    private var micCandidate = false
    private var micStarted = false
    /// Until when (uptime) the mic is taken for the call just left, while the app lets go of it.
    private var leftUntil: TimeInterval?
    private var timer: Timer?

    /// Monotonic, so a clock change can't upset the debounce.
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        timer?.invalidate()
        // .common, so detection keeps running while the menu is open
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        evaluate(force: true)
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Do Not Disturb for `dndLength` from now.
    func startDND() { setDND(Date().addingTimeInterval(dndLength)) }
    /// Back to FREE (or ON A CALL, if a call is on).
    func endDND() { setDND(nil) }
    /// What a double-click on the bar does: on if it's off, off if it's on.
    func toggleDND() { dndUntil == nil ? startDND() : endDND() }

    /// The Leave key left the meeting: the call's over now, not once the
    /// debounce agrees. The mic session ends here, and the app still holding
    /// the mic as it lets go doesn't light the sign again — until it's let go,
    /// or for `leaveGrace` at most. Do Not Disturb ends, and Force ON A CALL
    /// goes back to Automatic: the sign moves straight on, to FREE or what's next.
    func callLeft() {
        leftUntil = uptime + leaveGrace
        micCandidate = false
        micCandidateSince = uptime
        if micOn { setMic(false, at: Date().timeIntervalSince1970 * 1000) }
        setDND(nil)
        if override == .onCall { override = .auto } else { evaluate(force: true) }
    }

    /// A Teams or Zoom meeting has started since the Leave key: the mic is that call's.
    func endLeaveGrace() {
        guard leftUntil != nil else { return }
        leftUntil = nil
        evaluate()
    }

    /// "Do Not Disturb (30 min)", for a menu item that turns it on.
    var dndStartLabel: String { "Do Not Disturb (\(Int(dndLength / 60)) min)" }

    /// "Do Not Disturb · 23 min left, until 14:32", or nil when it's off.
    func dndStatus(at now: Date = Date()) -> String? {
        guard let until = dndUntil else { return nil }
        let minutes = max(Int((until.timeIntervalSince(now) / 60).rounded(.up)), 0)
        let end = DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short)
        return "Do Not Disturb · \(minutes) min left, until \(end)"
    }

    private func setDND(_ until: Date?) {
        if dndUntil != until { dndUntil = until }
        UserDefaults.standard.set(until, forKey: "dndUntil")
    }

    private static func savedDND() -> Date? {
        guard let until = UserDefaults.standard.object(forKey: "dndUntil") as? Date, until > Date() else { return nil }
        return until
    }

    func setIgnored(_ bundleID: String, _ ignored: Bool) {
        if ignored { userIgnored.insert(bundleID) } else { userIgnored.remove(bundleID) }
        UserDefaults.standard.set(Array(userIgnored).sorted(), forKey: "ignoredBundleIDs")
        evaluate()
    }

    /// An app that's a call: it counts however Detect is set, and an ignore on it goes.
    func addCallApp(_ app: CallApp) {
        guard !addedCallApps.contains(where: { $0.id == app.id }) else { return }
        addedCallApps.append(app)
        addedCallApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveCallApps()
        if userIgnored.contains(app.id) { setIgnored(app.id, false) } else { evaluate() }
    }

    func removeCallApp(_ id: String) {
        addedCallApps.removeAll { $0.id == id }
        saveCallApps()
        evaluate()
    }

    private func saveCallApps() {
        UserDefaults.standard.set(try? JSONEncoder().encode(addedCallApps), forKey: "addedCallApps")
    }

    private static func savedCallApps() -> [CallApp] {
        guard let data = UserDefaults.standard.data(forKey: "addedCallApps") else { return [] }
        return (try? JSONDecoder().decode([CallApp].self, from: data)) ?? []
    }

    private func evaluate(force: Bool = false) {
        if let until = dndUntil, Date() >= until { setDND(nil) }       // time's up

        let raw = sample()
        if detection != raw { detection = raw }
        // just left a call: the app letting go of the mic is still that call
        if let until = leftUntil, !raw.onCall || uptime >= until - slack { leftUntil = nil }
        let heard = raw.onCall && leftUntil == nil
        trackMic(heard)

        let target: Bool
        switch override {
        case .onCall: target = true
        case .free:   target = false
        case .auto:   target = heard
        }

        if override != .auto || force {
            apply(target)
            return
        }

        // debounce
        if target != candidate {
            candidate = target
            candidateSince = uptime
        }
        let needed = candidate ? onDelay : offDelay
        if candidate != isOnCall,
           let since = candidateSince,
           uptime - since >= needed - slack {
            apply(candidate)
        }
    }

    /// The same debounce as the sign's, kept apart from the override. A
    /// session runs from when the mic was taken to when it was let go — the
    /// moments the debounce confirmed — not from when the debounce caught up.
    private func trackMic(_ on: Bool) {
        let nowMs = Date().timeIntervalSince1970 * 1000
        guard micStarted else {
            micStarted = true
            micCandidate = on
            if on { setMic(true, at: nowMs) }
            return
        }
        if on != micCandidate {
            micCandidate = on
            micCandidateSince = uptime
        }
        let needed = micCandidate ? onDelay : offDelay
        if micCandidate != micOn, let since = micCandidateSince, uptime - since >= needed - slack {
            setMic(micCandidate, at: nowMs - (uptime - since) * 1000)
        }
    }

    private func setMic(_ on: Bool, at ms: Double) {
        micOn = on
        var sessions = micSessions.filter { ($0.end ?? .infinity) > ms - 24 * 3600 * 1000 }
        if on {
            sessions.append(MicSession(start: ms, end: nil))
        } else if let last = sessions.indices.last, sessions[last].end == nil {
            sessions[last].end = ms
        }
        micSessions = sessions
    }

    private func apply(_ value: Bool) {
        guard value != isOnCall else { return }
        isOnCall = value
        changedAt = Date()
        candidate = value
        candidateSince = nil
    }

    private func sample() -> Detection {
        var result = Detection()
        result.cameraActive = CameraProbe.anyCameraRunning()

        if let users = AudioProbe.activeInputProcesses() {
            result.holders = users.map { MicHolder(name: $0.name, bundleID: $0.appBundleID ?? $0.rawBundleID,
                                                   counts: qualifies($0)) }
            result.onCall = result.holders.contains(where: \.counts)
        } else {
            // No attribution available: fall back to the device-level signal.
            result.attributed = false
            result.onCall = AudioProbe.anyInputRunning()
        }
        return result
    }

    private func qualifies(_ user: MicUser) -> Bool {
        let ids = [user.appBundleID, user.rawBundleID].compactMap { $0 }
        // one you've added is a call, whatever else it looks like
        if ids.contains(where: { id in addedCallApps.contains { $0.id == id } }) { return true }
        if ids.contains(where: { KnownApps.ignored.contains($0) || userIgnored.contains($0) }) { return false }
        let lowerName = user.name.lowercased()
        if KnownApps.dictationNames.contains(where: { lowerName.contains($0) }) { return false }

        // Apple's own processes only count if they're a call.
        let path = user.executablePath ?? ""
        let id = user.appBundleID
        if (id?.hasPrefix("com.apple.") ?? false) || (id == nil && AppPath.isSystem(path)) {
            return ids.contains(where: KnownApps.appleCalls.contains) || KnownApps.appleCallPaths.contains(path)
        }

        switch policy {
        case .anyExceptIgnored:  return true
        case .knownCallAppsOnly: return ids.contains(where: KnownApps.calls.contains)
        }
    }
}
