import AppKit
import ApplicationServices

/*
 * MeetingEngine's view of the Mac: macOS Accessibility, the layer screen
 * readers use. Each element's attributes come back in one round trip
 * (AXUIElementCopyMultipleAttributeValues), which is what lets a walk of
 * Teams' meeting window finish. Also the keyboard shortcut a press falls
 * back to: Teams' meeting window brought forward, ⌘⇧M sent, your app given
 * back (Teams Meeting Keys' press.applescript, without AppleScript).
 *
 * Every call blocks until the app answers (at most 1.5 s), so this is only
 * used on MeetingWorker's queue and MuteDetector's.
 */
final class AXMeetingBackend: MeetingBackend {
    /// An AXUIElement, as the engine holds it.
    final class Ref {
        let element: AXUIElement
        init(_ element: AXUIElement) { self.element = element }
    }

    private static let readNames = ["AXRole", "AXSubrole", "AXDOMIdentifier", "AXDescription", "AXTitle", "AXHelp",
                                    "AXValue", "AXEnabled", "AXMenuItemMarkChar"]
    private let readAttributes = readNames as CFArray
    private let nodeAttributes = (readNames + ["AXChildren"]) as CFArray
    private let systemWide = AXUIElementCreateSystemWide()

    init() {
        // a slow or hung app mustn't hold anything up for the 6 s default (this sets it for every element)
        AXUIElementSetMessagingTimeout(systemWide, 1.5)
    }

    private func ax(_ e: AnyObject) throws -> AXUIElement {
        guard let r = e as? Ref else { throw MeetingAXError.invalid }
        return r.element
    }

    private static func failure(_ code: AXError) -> MeetingAXError {
        switch code {
        case .invalidUIElement: return .invalid
        case .cannotComplete: return .busy
        case .apiDisabled: return .untrusted
        default: return .failed(code.rawValue)
        }
    }

    private func copy(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v
    }

    private func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = copy(e, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    // MARK: MeetingBackend

    func trusted() -> Bool { AXIsProcessTrusted() }

    func findApp(_ app: MeetingApp) -> Int32 {
        for id in app.bundleIDs {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) {
                return running.processIdentifier
            }
        }
        return 0
    }

    func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    func application(_ pid: Int32) -> AnyObject { Ref(AXUIElementCreateApplication(pid)) }

    /// AXManualAccessibility is the quiet way to ask Chromium for its tree;
    /// AXEnhancedUserInterface, VoiceOver's switch, only when asked for, as it
    /// can make window managers misbehave.
    func enable(_ app: AnyObject, full: Bool) {
        guard let e = try? ax(app) else { return }
        AXUIElementSetAttributeValue(e, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if full { AXUIElementSetAttributeValue(e, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    func windows(_ app: AnyObject) throws -> [AnyObject] {
        let e = try ax(app)
        var v: CFTypeRef?
        let code = AXUIElementCopyAttributeValue(e, "AXWindows" as CFString, &v)
        guard code == .success else { throw Self.failure(code) }
        return ((v as? [AXUIElement]) ?? []).map(Ref.init)
    }

    func node(_ e: AnyObject) throws -> (MeetingAttrs, [AnyObject]) {
        try read(try ax(e), children: true)
    }

    func read(_ e: AnyObject) throws -> MeetingAttrs {
        try read(try ax(e), children: false).0
    }

    private func read(_ e: AXUIElement, children: Bool) throws -> (MeetingAttrs, [AnyObject]) {
        var out: CFArray?
        let code = AXUIElementCopyMultipleAttributeValues(e, children ? nodeAttributes : readAttributes, [], &out)
        guard code == .success else { throw Self.failure(code) }
        guard let out else { throw MeetingAXError.invalid }
        let values = out as NSArray as [AnyObject]
        // an attribute the element lacks comes back as an AXValue holding the error
        func at(_ i: Int) -> AnyObject? {
            guard i < values.count, CFGetTypeID(values[i]) != AXValueGetTypeID() else { return nil }
            return values[i]
        }
        var a = MeetingAttrs()
        a.role = at(0) as? String ?? ""
        a.subrole = at(1) as? String ?? ""
        a.id = at(2) as? String ?? ""
        a.desc = at(3) as? String ?? ""
        a.title = at(4) as? String ?? ""
        a.help = at(5) as? String ?? ""
        if let v = at(6) {
            if let s = v as? String { a.value = s } else if let n = v as? NSNumber { a.number = n.doubleValue }
        }
        if let v = at(7) as? NSNumber { a.enabled = v.boolValue }
        a.mark = at(8) as? String ?? ""
        let kids = children ? ((at(9) as? [AXUIElement]) ?? []).map { Ref($0) as AnyObject } : []
        return (a, kids)
    }

    func actions(_ e: AnyObject) -> [String] {
        guard let e = try? ax(e) else { return [] }
        var names: CFArray?
        guard AXUIElementCopyActionNames(e, &names) == .success, let names else { return [] }
        return (names as NSArray) as? [String] ?? []
    }

    func perform(_ e: AnyObject, _ action: String) throws {
        let code = AXUIElementPerformAction(try ax(e), action as CFString)
        guard code == .success else { throw Self.failure(code) }
    }

    func closeButton(_ window: AnyObject) -> AnyObject? {
        guard let w = try? ax(window), let b = element(w, "AXCloseButton") else { return nil }
        return Ref(b)
    }

    func menuBar(_ app: AnyObject) -> AnyObject? {
        guard let a = try? ax(app), let bar = element(a, "AXMenuBar") else { return nil }
        return Ref(bar)
    }

    /// Escape to that process only, so it can't land in whatever you're typing in.
    func postEscape(_ pid: Int32) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard pid > 0, let down = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false) else { return false }
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    func frontmostPID() -> Int32 {
        guard let app = element(systemWide, "AXFocusedApplication") else { return 0 }
        var pid: pid_t = 0
        return AXUIElementGetPid(app, &pid) == .success ? pid : 0
    }

    /// Brings an app back to the front after a meeting app raised itself.
    func activate(_ pid: Int32) {
        guard pid > 0 else { return }
        // Busy Bar Sign itself (its settings were in front): Accessibility asked of our own
        // process is answered right here, on this thread, and AppKit crashes off the main one
        if pid == getpid() {
            DispatchQueue.main.async { MainActor.assumeIsolated { NSApp.activate() } }
            return
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXFrontmost" as CFString, kCFBooleanTrue)
        if let w = element(app, "AXFocusedWindow") { AXUIElementPerformAction(w, "AXRaise" as CFString) }
    }

    // MARK: - The keyboard shortcut

    enum ShortcutFailure: Error, Equatable {
        case notRunning(MeetingApp)
        case noMeeting(MeetingApp, windows: [String])
        case focus(MeetingApp)
        case window(MeetingApp, String)

        var message: String {
            switch self {
            case .notRunning(let app): return "\(app.label) isn't running."
            case .noMeeting(let app, let windows):
                let list = windows.map { $0.isEmpty ? "(untitled)" : $0 }.joined(separator: " / ")
                return "No \(app.label) meeting window found. Windows: \(list.isEmpty ? "none" : list)"
            case .focus(let app): return "\(app.label) didn't come to the front within a second. Nothing was sent."
            case .window(let app, let title): return "Couldn't bring \(app.label)'s “\(title)” forward. Nothing was sent."
            }
        }
        var noMeetingThere: Bool {
            switch self {
            case .notRunning, .noMeeting: return true
            default: return false
            }
        }
    }

    /// The app's own shortcut: Teams ⌘⇧M / ⌘⇧H, Zoom ⌘⇧A / ⌘W (ending for
    /// everyone is Zoom's ⌘W too, then the other button in its prompt).
    private static func key(_ control: MeetingControl, _ app: MeetingApp) -> (code: CGKeyCode, shift: Bool) {
        switch (app, control) {
        case (.teams, .mute): return (46, true)     // M
        case (.teams, .leave), (.teams, .end): return (4, true)     // H
        case (.zoom, .mute): return (0, true)       // A
        case (.zoom, .leave), (.zoom, .end): return (13, false)    // W, then its prompt
        }
    }

    private func titledWindows(_ app: AXUIElement) -> [(element: AXUIElement, title: String)] {
        guard let list = copy(app, "AXWindows") as? [AXUIElement] else { return [] }
        return list.map { ($0, copy($0, "AXTitle") as? String ?? "") }
    }

    private func waitForFront(_ pid: Int32) -> Bool {
        for _ in 0..<20 {
            if frontmostPID() == pid { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return frontmostPID() == pid
    }

    /// Brings the meeting window forward, sends the shortcut, and gives focus
    /// back to the app you were in, on every path. The meeting window's title
    /// when it went.
    func sendShortcut(_ control: MeetingControl, to app: MeetingApp, hint: String) -> Result<String, ShortcutFailure> {
        let pid = findApp(app)
        guard pid != 0 else { return .failure(.notRunning(app)) }
        let appElement = AXUIElementCreateApplication(pid)
        let front = frontmostPID()
        let restore = front != pid ? front : 0
        defer { if restore > 0 { activate(restore) } }

        var wins = titledWindows(appElement)
        var target = MeetingWindows.pick(app, titles: wins.map(\.title), hint: hint)
        if target == nil && front != pid {
            // a full-screen meeting on another desktop only shows in the list once the app's in front
            AXUIElementSetAttributeValue(appElement, "AXFrontmost" as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.3)
            wins = titledWindows(appElement)
            target = MeetingWindows.pick(app, titles: wins.map(\.title), hint: hint)
        }
        guard let title = target else { return .failure(.noMeeting(app, windows: wins.map(\.title))) }

        // raise (and un-minimise) the meeting window first, so it's the one that comes forward
        var minimised = false
        if let w = wins.first(where: { $0.title == title })?.element {
            if (copy(w, "AXMinimized") as? NSNumber)?.boolValue == true {
                AXUIElementSetAttributeValue(w, "AXMinimized" as CFString, kCFBooleanFalse)
                minimised = true
            }
            AXUIElementPerformAction(w, "AXRaise" as CFString)
        }
        AXUIElementSetAttributeValue(appElement, "AXFrontmost" as CFString, kCFBooleanTrue)
        guard waitForFront(pid) else { return .failure(.focus(app)) }
        if minimised { Thread.sleep(forTimeInterval: 0.5) }

        // make sure the meeting window really is the one the keystroke will reach
        let (code, shift) = Self.key(control, app)
        var focused = false
        for _ in 0..<10 {
            if let w = titledWindows(appElement).first(where: { $0.title == title })?.element {
                AXUIElementPerformAction(w, "AXRaise" as CFString)
                AXUIElementSetAttributeValue(w, "AXMain" as CFString, kCFBooleanTrue)
                let focusedTitle = element(appElement, "AXFocusedWindow").flatMap { copy($0, "AXTitle") as? String }
                // plain ⌘ shortcuts (Zoom's ⌘W) act on the focused window, so they need the stricter check
                if focusedTitle == title || (shift && (copy(w, "AXMain") as? NSNumber)?.boolValue == true) {
                    focused = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard focused else { return .failure(.window(app, title)) }

        Thread.sleep(forTimeInterval: 0.1)
        guard frontmostPID() == pid else { return .failure(.focus(app)) }
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = shift ? [.maskCommand, .maskShift] : [.maskCommand]
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.15)
        return .success(title)
    }
}
