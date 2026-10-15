import AppKit
import ApplicationServices

/*
 * Whether you're muted, read from the call app itself through macOS
 * Accessibility — the way MuteMe and MuteDeck read Teams since Microsoft
 * retired its device API on 30 June 2026. Teams and Zoom keep the mic open
 * while you're muted, so Core Audio can't tell; their mute button can.
 *
 * Teams and Zoom are read by MeetingKeys, which finds Teams' mic button by
 * its id and reads Zoom's Meeting menu. Any other app CallDetector counts as
 * your call (Meet in a browser, Slack, Webex, FaceTime) is searched for a
 * control whose name reads as a mic mute (MuteLabels): its windows, then its
 * menu bar, off the main thread, within a budget, the control found then
 * re-read each second. Dictation tools are never read: CallDetector doesn't
 * count them.
 *
 * Nothing found, no permission, or anything unrecognised reads as a live
 * mic: the bar never tells the room it can talk unless the app says so.
 */
@MainActor
final class MuteDetector: ObservableObject {
    /// What the call app's mute control says now, or nil when there's no reading.
    @Published private(set) var reading: MuteReading?
    /// Whether macOS lets this app read other apps' controls.
    @Published private(set) var trusted = AXIsProcessTrusted()
    /// The call app being looked at while no control has been found in it.
    @Published private(set) var lookingIn: String?
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "showMute"); if !enabled { reset() } }
    }

    let meeting: MeetingKeys
    private let queue = DispatchQueue(label: "com.woodall.BusyBarSign.mute", qos: .utility)
    private let probe = MuteProbe()                 // used only on `queue`
    private var busy = false

    init(meeting: MeetingKeys) {
        self.meeting = meeting
        enabled = UserDefaults.standard.object(forKey: "showMute") as? Bool ?? true
    }

    /// Muted, as far as the bar is concerned: switched on, allowed, and the app says so.
    var muted: Bool { enabled && trusted && reading?.muted == true }

    /// Called once a second with whether the mic is in use and the bundle IDs
    /// of the apps holding it that count as a call.
    func update(onCall: Bool, apps: [String]) {
        let t = AXIsProcessTrusted()
        if trusted != t { trusted = t }
        guard enabled, trusted, onCall, !apps.isEmpty else { reset(); return }

        // Teams and Zoom: what the meeting keys read
        let meetingApps = apps.compactMap(MeetingApp.init(bundleID:))
        let snap = meeting.snapshot
        if let app = meetingApps.first(where: { snap.apps[$0]?.inMeeting == true }), let s = snap.apps[app] {
            set(s.muted.map { MuteReading(muted: $0, app: app.label, label: s.muteLabel) }, looking: app.label)
            return
        }
        let others = apps.filter { MeetingApp(bundleID: $0) == nil }
        if others.isEmpty {
            set(nil, looking: meetingApps.first?.label)       // its meeting isn't found (yet)
            return
        }

        // anything else: searched for
        guard !busy else { return }
        let targets = others.compactMap { id -> MuteProbe.Target? in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return nil }
            return MuteProbe.Target(pid: app.processIdentifier, name: app.localizedName ?? id)
        }
        guard !targets.isEmpty else { reset(); return }
        busy = true
        let probe = self.probe
        queue.async { [weak self] in
            let found = probe.read(targets)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(found, looking: targets.first?.name) }
            }
        }
    }

    private func finish(_ found: MuteReading?, looking: String?) {
        busy = false
        guard enabled, trusted else { return }
        set(found, looking: looking)
    }

    private func set(_ found: MuteReading?, looking: String?) {
        if reading != found { reading = found }
        let next = found == nil ? looking : nil
        if lookingIn != next { lookingIn = next }
    }

    private func reset() {
        set(nil, looking: nil)
        let probe = self.probe
        queue.async { probe.forget() }
    }

    /// Shows macOS's own request for Accessibility permission, and the pane it's granted in.
    func requestTrust() {
        let ask = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(ask) { trusted = true; return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Clears macOS's Accessibility entry for this app, then asks again. An
    /// entry left by a build signed differently (ad hoc, or before the project's
    /// certificate) doesn't match this one — switched on in the list, it still
    /// says no — and switching it off and on doesn't change that. tccutil only
    /// resets this app's own entry.
    func resetTrust() {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.woodall.BusyBarSign"]
        do {
            try reset.run()
            reset.waitUntilExit()
        } catch {
            NSLog("Busy Bar Sign: couldn't reset the Accessibility permission: %@", error.localizedDescription)
        }
        requestTrust()
    }

    /// The first time the app runs with this switched on, ask for the permission once.
    func askOnce() {
        guard enabled, !trusted, !UserDefaults.standard.bool(forKey: "askedAccessibility") else { return }
        UserDefaults.standard.set(true, forKey: "askedAccessibility")
        requestTrust()
    }

    /// One line for the controls: what's being read, and what it says.
    var statusLine: String {
        guard enabled else { return "Off" }
        guard trusted else { return "Needs Accessibility permission" }
        if let reading { return "\(reading.app) · “\(reading.label)” · \(reading.muted ? "muted" : "mic live")" }
        if let lookingIn { return "No mute button found in \(lookingIn) yet" }
        return "Not on a call"
    }
}

/// What a call app's mute control says.
struct MuteReading: Equatable {
    var muted: Bool
    var app: String
    var label: String
}

/// The search of apps other than Teams and Zoom, on MuteDetector's queue only.
final class MuteProbe {
    struct Target { let pid: pid_t; let name: String }

    private let ax = AXMeetingBackend()
    private var cached: (pid: pid_t, element: AnyObject)?
    private var searched: [pid_t: Date] = [:]
    private var asked = Set<pid_t>()
    private let roles: Set<String> = ["AXButton", "AXCheckBox", "AXMenuItem", "AXMenuButton", "AXRadioButton", "AXToggle"]

    func forget() {
        cached = nil
        searched = [:]
    }

    func read(_ targets: [Target]) -> MuteReading? {
        for target in targets {
            if let c = cached, c.pid == target.pid {
                if let a = try? ax.read(c.element), let r = reading(a) { return MuteReading(muted: r.muted, app: target.name, label: r.label) }
                cached = nil                         // gone or relabelled: look again now
                searched[target.pid] = nil
            }
            // search an app at most every 3 seconds
            if let last = searched[target.pid], Date().timeIntervalSince(last) < 3 { continue }
            searched[target.pid] = Date()
            let app = ax.application(target.pid)
            // Chromium and Electron apps (a browser for Meet, Slack) build their tree only when asked:
            // quietly first, then as a screen reader would
            ax.enable(app, full: asked.contains(target.pid))
            asked.insert(target.pid)
            if let found = search(app) {
                cached = (target.pid, found.element)
                return MuteReading(muted: found.muted, app: target.name, label: found.label)
            }
        }
        return nil
    }

    /// The app's windows, front first, then its menu bar, in document order,
    /// for the first control that reads as a mic mute.
    private func search(_ app: AnyObject) -> (element: AnyObject, muted: Bool, label: String)? {
        var roots = (try? ax.windows(app)) ?? []
        if let bar = ax.menuBar(app) { roots.append(bar) }
        let deadline = Date().addingTimeInterval(2)
        var budget = 6000
        for root in roots {
            var found: (element: AnyObject, muted: Bool, label: String)?
            let read = MeetingNode.walk(ax, root, maxNodes: budget) { n in
                if self.roles.contains(n.attrs.role), let r = self.reading(n.attrs) {
                    found = (n.element, r.muted, r.label)
                    return true
                }
                return Date() > deadline
            }.read
            if let found { return found }
            budget -= read
            if budget <= 0 || Date() > deadline { break }
        }
        return nil
    }

    /// What one control says, by its name (aria-label in web content, title in native apps, then tooltip).
    private func reading(_ a: MeetingAttrs) -> (muted: Bool, label: String)? {
        for label in [a.desc, a.title, a.help] where !label.isEmpty {
            if let muted = MuteLabels.reading(label: label, role: a.role, checked: !a.mark.isEmpty) { return (muted, label) }
        }
        return nil
    }
}
