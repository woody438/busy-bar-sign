import Foundation

/*
 * The Stream Deck's Camera key: turns your camera on or off in the call
 * you're in. macOS has no switch that turns the camera off for whichever app
 * is using it, so the key presses the call app's own camera control through
 * Accessibility, as the Mute key presses its mute:
 *
 *   Teams     the meeting window's camera button (its HTML id video-button,
 *             or a button named "Turn camera on" / "Turn camera off");
 *             MeetingKeys sends its shortcut, ⌘⇧O, if that doesn't take
 *   Zoom      its Meeting menu's Start Video / Stop Video (or the meeting
 *             window's own button); MeetingKeys sends ⌘⇧V if that doesn't take
 *   FaceTime  the call window's "Camera" button, shown under the pointer as
 *             the Leave key shows FaceTime's End
 *   WhatsApp, Google Meet in a browser, and any other call app on the mic:
 *             a control named for the camera ("Turn off camera", "Stop
 *             video", "Camera") in the app's windows or menu bar; no shortcut
 *
 * A press is done once the Mac's camera starts or stops (CameraProbe, the
 * signal that lights the green light by the lens), or the control's name
 * flips (Turn camera off to Turn camera on). What it never presses: a
 * control named for camera settings, options, effects or backgrounds, for
 * choosing or switching a camera, or for a call ("Start video call" in a
 * chat would start one), and never a menu button (its options).
 *
 * Runs on MeetingWorker's queue: every Accessibility call blocks. Foundation
 * only but for the backend and the camera reading, so Checks/camerakey
 * scripts Teams, Zoom, FaceTime, WhatsApp and Meet.
 */

/// What a control's name says about the camera: on now (pressing turns it
/// off), off now, or just "Camera", a toggle whose state is read from it.
enum CameraLabels {
    enum Reading: Equatable { case on, off, toggle }

    /// Words that mean a control is about something else: settings, effects,
    /// choosing a camera, or starting a call.
    static let never: Set<String> = [
        "setting", "settings", "option", "options", "effect", "effects", "background", "backgrounds", "blur",
        "filter", "filters", "choose", "select", "switch", "preview", "share", "sharing", "studio", "portrait",
        "center", "centre", "stage", "reaction", "reactions", "gesture", "gestures", "mirror", "resolution", "quality",
        "spotlight", "pin", "layout", "gallery", "speaker", "call", "calls", "meeting", "record", "recording",
        "capture", "screen", "photo", "snapshot", "more", "device", "devices", "source", "sources", "hd", "facetime"
    ]

    /// Named for what pressing it does: the camera's on now.
    static let turnsOff: Set<String> = [
        "turn off camera", "turn camera off", "turn off your camera", "turn your camera off", "turn off video",
        "turn video off", "stop video", "stop my video", "stop camera", "disable camera", "disable video", "hide video"
    ]
    /// ...the camera's off now.
    static let turnsOn: Set<String> = [
        "turn on camera", "turn camera on", "turn on your camera", "turn your camera on", "turn on video",
        "turn video on", "start video", "start my video", "start camera", "enable camera", "enable video", "show video"
    ]
    /// Named for the camera alone: a toggle, read by whether it shows it's on.
    static let toggles: Set<String> = [
        "camera", "video", "camera on", "camera off", "video on", "video off", "toggle camera", "toggle video"
    ]

    /// A name as compared: lower case, without a shortcut in brackets ("Turn
    /// off camera (⌘ + e)", "Turn camera off (⌘⇧O)") or after a comma, and
    /// with anything but letters as single spaces.
    static func normalise(_ label: String) -> String {
        var s = label.lowercased()
        for cut in ["(", ",", " – ", " - ", "\n"] {
            if let r = s.range(of: cut) { s = String(s[..<r.lowerBound]) }
        }
        let letters = s.unicodeScalars.map { CharacterSet.letters.contains($0) ? Character($0) : " " }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    /// What a control's name says, or nil if it isn't the camera's on/off control.
    static func reading(_ label: String) -> Reading? {
        let n = normalise(label)
        guard !n.isEmpty, !n.split(separator: " ").contains(where: { never.contains(String($0)) }) else { return nil }
        if turnsOff.contains(n) { return .on }
        if turnsOn.contains(n) { return .off }
        if toggles.contains(n) { return .toggle }
        return nil
    }
}

/// Where the Camera key presses: a Teams or Zoom meeting (in the window the
/// meeting keys found), or another call app on the mic.
enum CameraTarget: Equatable {
    case meeting(MeetingApp, window: String)
    /// `name` for messages; `hover`: its call buttons show only under the
    /// pointer (FaceTime).
    case app(name: String, hover: Bool)

    var name: String {
        switch self {
        case .meeting(let app, _): return app.label
        case .app(let name, _): return name
        }
    }
}

/// How a press of the Camera key went.
struct CameraKeyResult: Equatable {
    var ok = false
    /// It reached the app, whether or not its effect was seen.
    var delivered = false
    /// What the camera is now, once it was seen to change (or nil).
    var camera: Bool?
    var message = ""
}

final class CameraKey {
    // seconds
    static let searchTime = 3.0
    static let verify = 2.5
    static let verifyStep = 0.1
    static let restoreDelay = 0.35
    static let revealWait = 0.35
    static let windowWalkCap = 5000
    static let menuWalkCap = 1500
    static let windowsLooked = 6
    /// Teams' camera button, as Chromium exposes its HTML id.
    static let teamsID = "video-button"
    static let roles: Set<String> = ["AXButton", "AXCheckBox", "AXToggle", "AXMenuItem"]

    let backend: MeetingBackend
    /// Whether any camera on the Mac is streaming now (CameraProbe); nil if it can't be told.
    var cameraRunning: () -> Bool? = { nil }
    var now: () -> Date = Date.init
    var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    init(backend: MeetingBackend) { self.backend = backend }

    /// A camera control found in an app.
    struct Control {
        let element: AnyObject
        let label: String
        let reading: CameraLabels.Reading
        let window: String          // "" for the menu bar
        /// What it says the camera is: from its name, or a toggle's on/off; nil if it doesn't say.
        let on: Bool?
        /// How sure: Teams' own id, a name saying on or off, a bare toggle, a menu item.
        let rank: Int
    }

    struct Found {
        var controls: [Control] = []
        /// The names of the buttons seen, for when nothing's found.
        var seen: [String] = []
        var best: Control? { controls.min { $0.rank < $1.rank } }
    }

    // MARK: - Finding

    /// The camera controls in an app's windows (the meeting's first) and its menu bar.
    func find(_ appElement: AnyObject, _ target: CameraTarget) -> Found {
        var out = Found()
        let deadline = now().addingTimeInterval(Self.searchTime)
        var wins: [(element: AnyObject, title: String)] = ((try? backend.windows(appElement)) ?? []).map { w in
            (element: w, title: (try? backend.read(w))?.title ?? "")
        }
        if case .meeting(_, let hint) = target, !hint.isEmpty {
            wins = wins.filter { $0.title == hint } + wins.filter { $0.title != hint }     // the meeting's window first
        }
        for (window, title) in wins.prefix(Self.windowsLooked) {
            if now() >= deadline { break }
            _ = MeetingNode.walk(backend, window, maxNodes: Self.windowWalkCap) { n in
                if let c = self.control(n, window: title.isEmpty ? "window" : title) { out.controls.append(c) }
                else if n.attrs.role == "AXButton", !n.attrs.label.isEmpty, out.seen.count < 40 { out.seen.append(n.attrs.label) }
                return false
            }
            // a meeting's own control by id: no need to look further
            if out.controls.contains(where: { $0.rank == 0 }) { return out }
        }
        if let bar = backend.menuBar(appElement), now() < deadline {
            _ = MeetingNode.walk(backend, bar, maxNodes: Self.menuWalkCap, maxDepth: 5) { n in
                if n.attrs.role == "AXMenuItem", n.attrs.isEnabled, let c = self.control(n, window: "") { out.controls.append(c) }
                return false
            }
        }
        return out
    }

    /// A node as a camera control, if it's one that may be pressed.
    private func control(_ n: MeetingNode, window: String) -> Control? {
        let a = n.attrs
        guard Self.roles.contains(a.role), a.isEnabled else { return nil }
        let byID = a.id == Self.teamsID
        var reading: CameraLabels.Reading?, label = ""
        for name in [a.desc, a.title, a.help] where !name.isEmpty {
            if let r = CameraLabels.reading(name) { reading = r; label = name; break }
        }
        if byID && reading == nil { reading = .toggle; label = a.label.isEmpty ? Self.teamsID : a.label }
        guard let reading else { return nil }
        // in the menu bar, only an item that says on or off: "Camera" there lists the cameras
        if window.isEmpty && reading == .toggle { return nil }
        let on: Bool?
        switch reading {
        case .on: on = true
        case .off: on = false
        case .toggle: on = a.number != nil || a.selected != nil ? a.isOn : nil
        }
        let rank = byID ? 0 : window.isEmpty ? 3 : reading == .toggle ? 2 : 1
        return Control(element: n.element, label: label, reading: reading, window: window, on: on, rank: rank)
    }

    // MARK: - Pressing

    /// Presses the camera control in `target` (process `pid`), hands focus back
    /// to the app you were in, and checks it took.
    func press(_ target: CameraTarget, pid: Int32) -> CameraKeyResult {
        let appElement = backend.application(pid)
        if case .app = target { backend.enable(appElement, full: false) }  // a Chromium or Electron app shows its tree when asked
        let previous = backend.frontmostPID()
        let wasRunning = cameraRunning()
        var found = find(appElement, target)
        var r = CameraKeyResult()

        // FaceTime's call buttons show only under the pointer: show them, and put the pointer back after
        var movedFrom: CGPoint?, raised = false
        if found.best == nil, case .app(_, true) = target {
            let shown = reveal(appElement, target, pid)
            found = shown.found
            movedFrom = shown.movedFrom
            raised = shown.raised
        }
        func handBack(pressed: Bool) {
            if let from = movedFrom { backend.movePointer(to: from); movedFrom = nil }
            if (pressed || raised) && previous != 0 && previous != pid {
                wait(Self.restoreDelay)
                backend.activate(previous)
            }
        }
        guard let control = found.best else {
            handBack(pressed: false)
            let seen = found.seen.isEmpty ? "" : " It showed: \(found.seen.prefix(12).map { "“\($0)”" }.joined(separator: ", "))."
            r.message = "No camera button found in \(target.name).\(seen) Settings ▸ Call apps ▸ Inspect lists what it shows."
            return r
        }
        let name = "\(target.name)'s “\(control.label)”\(control.window.isEmpty ? " (menu bar)" : "")"

        do { try backend.perform(control.element, "AXPress") } catch MeetingAXError.busy {
            r.delivered = true                       // timed out waiting, but it may still land
        } catch {
            handBack(pressed: false)
            r.message = "Couldn't press \(name): \(error)."
            return r
        }
        r.delivered = true
        handBack(pressed: true)

        // done once the camera starts or stops, or the control's name flips
        let changed: Bool? = seen(within: Self.verify) { () -> Bool? in
            if let was = wasRunning, let running = self.cameraRunning(), running != was { return running }
            if let before = control.on, let after = self.reread(control), after != before { return after }
            return nil
        }
        if let on = changed {
            r.ok = true
            r.camera = on
            r.message = "Pressed \(name): camera \(on ? "on" : "off")."
        } else {
            r.message = "Pressed \(name), but the camera didn't change."
        }
        return r
    }

    /// A control's camera reading now, by its name (or a toggle's state); nil if gone or silent.
    private func reread(_ c: Control) -> Bool? {
        guard let a = try? backend.read(c.element), !a.role.isEmpty else { return nil }
        for name in [a.desc, a.title, a.help] where !name.isEmpty {
            switch CameraLabels.reading(name) {
            case .on?: return true
            case .off?: return false
            case .toggle?: return a.number != nil || a.selected != nil ? a.isOn : nil
            case nil: continue
            }
        }
        return nil
    }

    /// Shows FaceTime's call buttons: a pointer move sent to FaceTime alone;
    /// if they still don't show, its window brought forward and the pointer
    /// moved over it. Where the pointer was, to put it back.
    private func reveal(_ appElement: AnyObject, _ target: CameraTarget, _ pid: Int32)
        -> (found: Found, movedFrom: CGPoint?, raised: Bool) {
        let framed = ((try? backend.windows(appElement)) ?? []).compactMap { w in backend.frame(w).map { (w, $0) } }
        guard let biggest = framed.max(by: { $0.1.size.width * $0.1.size.height < $1.1.size.width * $1.1.size.height }) else {
            return (find(appElement, target), nil, false)
        }
        let (window, frame) = biggest
        let centre = { (r: CGRect) in CGPoint(x: r.origin.x + r.size.width / 2, y: r.origin.y + r.size.height / 2) }
        backend.nudge(pid, at: centre(frame))
        wait(Self.revealWait)
        var found = find(appElement, target)
        guard found.best == nil, let from = backend.pointer() else { return (found, nil, false) }

        let raised = backend.bringForward(window, pid: pid)
        let spot = centre(backend.frame(window) ?? frame)       // brought forward, it may be on another desktop
        backend.movePointer(to: spot)
        wait(Self.revealWait)
        backend.movePointer(to: CGPoint(x: spot.x + 2, y: spot.y))
        wait(Self.revealWait)
        found = find(appElement, target)
        return (found, from, raised)
    }

    /// The first non-nil answer of `check`, asked until `within` seconds have passed.
    private func seen<T>(within: TimeInterval, _ check: () -> T?) -> T? {
        let end = now().addingTimeInterval(within)
        while true {
            if let v = check() { return v }
            if now() >= end { return nil }
            wait(Self.verifyStep)
        }
    }

    /// What the Camera key would press in an app, as text, for Settings ▸ Call apps ▸ Inspect.
    func report(_ target: CameraTarget, pid: Int32) -> String {
        guard pid != 0 else { return "" }
        let found = find(backend.application(pid), target)
        var out = "\n\(target.name), the Camera key:\n"
        if let best = found.best {
            out += "  presses “\(best.label)” in \(best.window.isEmpty ? "the menu bar" : "“\(best.window)”")"
            out += best.on.map { $0 ? " (camera on)\n" : " (camera off)\n" } ?? "\n"
        } else {
            out += "  no camera button found\n"
        }
        return out
    }
}
