import AppKit
import ApplicationServices

/*
 * Whether you're muted, read from the call app itself through macOS
 * Accessibility — the way MuteMe and MuteDeck read Teams since Microsoft
 * retired its device API on 30 June 2026. Teams and Zoom keep the mic open
 * while you're muted, so Core Audio can't tell; their mute button can.
 *
 * Only the apps CallDetector counts as your call are read, so dictation
 * tools and anything you've told it to ignore never are. While you're on a
 * call it finds the app's mute control once (a search of its windows and
 * menu bar, off the main thread, within a time budget), then re-reads that
 * one control each second. A control that's gone is searched for again.
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

    private let queue = DispatchQueue(label: "com.woodall.BusyBarSign.mute", qos: .utility)
    private let probe = MuteProbe()                 // used only on `queue`
    private var busy = false

    init() {
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
        guard !busy else { return }
        let targets = apps.compactMap { id -> MuteProbe.Target? in
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
        if reading != found { reading = found }
        let next = found == nil ? looking : nil
        if lookingIn != next { lookingIn = next }
    }

    private func reset() {
        if reading != nil { reading = nil }
        if lookingIn != nil { lookingIn = nil }
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

/// The Accessibility work, on MuteDetector's queue only.
final class MuteProbe {
    struct Target { let pid: pid_t; let name: String }

    private var cached: (pid: pid_t, element: AXUIElement)?
    private var searched: [pid_t: Date] = [:]
    private let roles: Set<String> = ["AXButton", "AXCheckBox", "AXMenuItem", "AXMenuButton", "AXRadioButton", "AXToggle"]

    func forget() {
        cached = nil
        searched = [:]
    }

    func read(_ targets: [Target]) -> MuteReading? {
        for target in targets {
            if let c = cached, c.pid == target.pid {
                if let r = reading(of: c.element) { return MuteReading(muted: r.muted, app: target.name, label: r.label) }
                cached = nil                         // gone or relabelled: look again now
                searched[target.pid] = nil
            }
            // search an app at most every 3 seconds
            if let last = searched[target.pid], Date().timeIntervalSince(last) < 3 { continue }
            searched[target.pid] = Date()
            let app = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            // Chromium and Electron apps (Chrome for Meet, Slack) only expose their
            // web content to Accessibility when asked
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if let found = search(app) {
                cached = (target.pid, found.0)
                return MuteReading(muted: found.1.muted, app: target.name, label: found.1.label)
            }
        }
        return nil
    }

    /// A breadth-first look through the app's windows — the focused one first —
    /// then its menu bar, for the first control that reads as a mic mute.
    private func search(_ app: AXUIElement) -> (AXUIElement, (muted: Bool, label: String))? {
        var roots: [AXUIElement] = []
        if let w = element(app, "AXFocusedWindow") { roots.append(w) }
        roots += (value(app, "AXWindows") as? [AXUIElement]) ?? []
        if let bar = element(app, "AXMenuBar") { roots.append(bar) }

        let deadline = Date().addingTimeInterval(1.5)
        var queue = roots.map { ($0, 0) }
        var head = 0, seen = 0
        while head < queue.count, seen < 8000, Date() < deadline {
            let (e, depth) = queue[head]
            head += 1
            seen += 1
            if let role = value(e, "AXRole") as? String, roles.contains(role), let r = reading(of: e, role: role) {
                return (e, r)
            }
            if depth < 60, let children = value(e, "AXChildren") as? [AXUIElement] {
                queue += children.map { ($0, depth + 1) }
            }
        }
        return nil
    }

    /// What one control says, by its label (aria-label in web content, title in native apps, then tooltip).
    private func reading(of e: AXUIElement, role known: String? = nil) -> (muted: Bool, label: String)? {
        guard let role = known ?? (value(e, "AXRole") as? String) else { return nil }
        let mark = value(e, "AXMenuItemMarkChar") as? String
        let checked = !(mark ?? "").isEmpty
        for attribute in ["AXDescription", "AXTitle", "AXHelp"] {
            guard let label = value(e, attribute) as? String, !label.isEmpty else { continue }
            if let muted = MuteLabels.reading(label: label, role: role, checked: checked) { return (muted, label) }
        }
        return nil
    }

    private func value(_ e: AXUIElement, _ attribute: String) -> AnyObject? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v
    }

    private func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(e, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
}
