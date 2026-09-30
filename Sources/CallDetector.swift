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

/// Apps that hold the microphone but are never a call. Dictation is the one
/// that matters most here — without this the sign flickers on every utterance.
enum KnownApps {
    static let ignored: Set<String> = [
        "com.wisprflow.flow", "com.wispr.flow",
        "com.apple.SpeechRecognitionCore", "com.apple.siri", "com.apple.VoiceMemos",
        "com.apple.Dictation", "com.apple.assistantd",
        "com.apple.Music", "com.apple.QuickTimePlayerX",
        "com.apple.logic10", "com.ableton.live", "com.avid.ProTools",
        "com.rogueamoeba.audiohijack", "com.krisp.app"
    ]

    static let calls: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams", "com.microsoft.teams2",
        "com.apple.FaceTime",
        "com.google.Chrome", "com.google.Chrome.beta", "com.apple.Safari",
        "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser",
        "com.tinyspeck.slackmacgap",
        "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark",
        "com.hnc.Discord", "com.ringcentral.glip", "com.gotomeeting.GoToMeeting",
        "com.bluejeansnet.Blue", "com.loom.desktop", "com.whatsapp.WhatsApp"
    ]
}

struct Detection: Equatable {
    var onCall = false
    var micApps: [String] = []
    var cameraActive = false
    var attributed = true      // false when we fell back to device-level

    /// The line that runs along the bottom of the display.
    var sourceLine: String {
        guard onCall else {
            return micApps.isEmpty ? "Mic idle · cam idle"
                                   : "Mic idle · ignored: \(micApps.joined(separator: ", "))"
        }
        let who = micApps.isEmpty ? "microphone" : micApps.joined(separator: ", ")
        let cam = cameraActive ? "cam active" : "cam off"
        return attributed ? "Source — \(who) · mic active · \(cam)"
                          : "Mic active (unattributed) · \(cam)"
    }
}

/// Polls the audio and camera state once a second and debounces it into a
/// stable on/off the wall can be trusted to show.
@MainActor
final class CallDetector: ObservableObject {

    @Published private(set) var isOnCall = false
    @Published private(set) var detection = Detection()
    @Published private(set) var changedAt = Date()

    @Published var override: Override = .auto { didSet { evaluate(force: true) } }
    @Published var policy: DetectionPolicy = .anyExceptIgnored

    /// How long a signal must hold before the sign follows it. The long tail on
    /// the way down stops the sign flickering when an app briefly drops the mic.
    private let onDelay:  TimeInterval = 2
    private let offDelay: TimeInterval = 10

    private var candidateSince: Date?
    private var candidate = false
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate(force: true)
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func evaluate(force: Bool = false) {
        let raw = sample()
        detection = raw

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
            candidateSince = Date()
        }
        let needed = candidate ? onDelay : offDelay
        if candidate != isOnCall,
           let since = candidateSince,
           Date().timeIntervalSince(since) >= needed {
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

        let users = AudioProbe.activeInputProcesses()
        if AudioProbe.supportsProcessAttribution {
            let relevant = users.filter { qualifies($0) }
            result.micApps = relevant.map(\.name)
            result.onCall = !relevant.isEmpty
            if result.micApps.isEmpty, !users.isEmpty {
                result.micApps = users.map(\.name)   // shown as "ignored: …"
            }
        } else {
            // No attribution available: fall back to the device-level signal.
            result.attributed = false
            result.onCall = AudioProbe.anyInputRunning()
        }
        return result
    }

    private func qualifies(_ user: MicUser) -> Bool {
        guard let bundle = user.bundleID else {
            return policy == .anyExceptIgnored
        }
        if KnownApps.ignored.contains(bundle) { return false }
        switch policy {
        case .anyExceptIgnored:  return true
        case .knownCallAppsOnly: return KnownApps.calls.contains(bundle)
        }
    }
}
