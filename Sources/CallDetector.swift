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

    /// Apps the user has told us to ignore from the menu, by bundle ID.
    @Published private(set) var userIgnored: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "ignoredBundleIDs") ?? [])

    /// How long a signal must hold before the sign follows it. The long tail on
    /// the way down stops the sign flickering when an app briefly drops the mic.
    private let onDelay:  TimeInterval = 2
    private let offDelay: TimeInterval = 10
    /// Polls land a second apart; this stops timer jitter turning "2 s" into 3.
    private let slack:    TimeInterval = 0.25

    private var candidateSince: TimeInterval?
    private var candidate = false
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

    private func evaluate(force: Bool = false) {
        if let until = dndUntil, Date() >= until { setDND(nil) }       // time's up

        let raw = sample()
        if detection != raw { detection = raw }

        let target: Bool
        switch override {
        case .onCall: target = true
        case .free:   target = false
        case .auto:   target = raw.onCall
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
