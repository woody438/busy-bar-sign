import Foundation

/*
 * FaceTime and WhatsApp from the Stream Deck's Mute and Leave keys. Neither
 * has a toolbar to find by id (Teams) or a Meeting menu (Zoom), so their
 * call controls are found by what they say (MuteLabels, LeaveLabels) and
 * pressed through Accessibility, as MeetingEngine presses Teams' buttons:
 *
 *   Mute   the mic control in the call's window, else the menu bar's:
 *          FaceTime's "Mute", WhatsApp's "Mute Microphone"; done once a mute
 *          control's reading flips
 *   Leave  a control named for the call ("End call", "Leave Call", "Hang
 *          up") in any of the app's windows or its menu bar, or in FaceTime a
 *          lone "End", "Leave" or "Close" (its ✕) beside that mic control;
 *          done once that button has gone or greyed out, or the menu's mute
 *          item has — not when buttons merely hide
 *
 * FaceTime shows its call buttons only while the pointer is over its window
 * (Accessibility sees only its self-view and greyed-out window buttons
 * otherwise, and its menus have no End). So in a FaceTime call the Leave key
 * shows them first: a pointer move sent to FaceTime alone, and if that isn't
 * enough, its window brought forward and the pointer moved over it for about
 * a second, then the pointer and your app put back.
 *
 * What it never presses: a lone "End" or "Leave" away from a mic control, or
 * in WhatsApp at all (a group's "Leave"), and in WhatsApp any "Mute" outside
 * the call's window — its chats have a "Mute" for notifications. No keyboard
 * shortcut is sent either: one sent blind to the wrong window could start a
 * call. Found nothing, the key says so, and Settings ▸ Call apps ▸ Inspect
 * lists what the app showed.
 *
 * Runs on MeetingWorker's queue (and MuteDetector's, to read): every
 * Accessibility call blocks. Pure but for the backend, so Checks/callkeys
 * scripts both apps.
 */

/// The call apps the Mute and Leave keys reach by what their controls say.
enum LabelledCallApp: String, CaseIterable, Equatable {
    case facetime, whatsapp

    var label: String { self == .facetime ? "FaceTime" : "WhatsApp" }

    /// The app whose windows hold the call's controls.
    var appBundleIDs: [String] {
        switch self {
        case .facetime: return ["com.apple.FaceTime"]
        case .whatsapp: return ["net.whatsapp.WhatsApp", "com.whatsapp.WhatsApp"]
        }
    }

    /// By what holds the mic: FaceTime's audio runs in avconferenced.
    init?(bundleID: String) {
        switch bundleID {
        case "com.apple.FaceTime", "com.apple.avconferenced": self = .facetime
        case "net.whatsapp.WhatsApp", "com.whatsapp.WhatsApp": self = .whatsapp
        default: return nil
        }
    }

    /// Whether a menu-bar mute item is the call's: any of FaceTime's (its
    /// Video menu's "Mute"); in WhatsApp only one that names the mic ("Mute
    /// Microphone") — its plain "Mute" is a chat's.
    func menuMute(_ label: String) -> Bool {
        if self == .facetime { return true }
        return MuteLabels.normalise(label).split(separator: " ").contains { $0 == "mic" || $0 == "microphone" }
    }
    /// Whether the call's buttons show only while the pointer is over its
    /// window: FaceTime's do (its window shows Accessibility nothing else).
    var hoverControls: Bool { self == .facetime }
    /// Whether a mic control counts only in a window that can also end the
    /// call: WhatsApp's chats have a "Mute" of their own, for notifications.
    var muteNeedsLeave: Bool { self == .whatsapp }
    /// Whether a lone "End" or "Leave" beside a mic control ends the call:
    /// FaceTime's does; in WhatsApp only a button named for the call counts,
    /// so a chat's "Mute" and a group's "Leave" are never taken for a call.
    var bareLeave: Bool { self == .facetime }
}

extension MeetingAttrs {
    /// Whether the control shows it's on: a menu item's tick (never its
    /// highlight — AXSelected is just the pointer over it), a toggle's value,
    /// a selected button.
    var isOn: Bool {
        switch role {
        case "AXMenuItem": return !mark.isEmpty
        case "AXCheckBox", "AXToggle", "AXRadioButton": return number == 1
        default: return number == 1 || selected == true
        }
    }

    /// What the control says about the mic, by its name: the description
    /// (aria-label in web content), the title (native apps), then the tooltip.
    var muteReading: (muted: Bool, label: String)? {
        for name in [desc, title, help] where !name.isEmpty {
            if let muted = MuteLabels.reading(label: name, role: role, checked: isOn) { return (muted, name) }
        }
        return nil
    }

    /// Whether the control hangs up, by its name.
    var leaveReading: (kind: LeaveLabels.Kind, label: String)? {
        for name in [desc, title, help] where !name.isEmpty {
            if let kind = LeaveLabels.reading(label: name, role: role) { return (kind, name) }
        }
        return nil
    }
}

/// What a call app shows of its call.
struct CallControls {
    struct Control {
        let element: AnyObject
        let label: String
        let window: String          // "" for the menu bar
        var muted = false           // mute controls only
    }

    /// The mic controls that may be pressed, best first: the call window's, then the menu bar's.
    var mute: [Control] = []
    /// What the Leave key presses.
    var leave: Control?
    /// An enabled mute item in the menu bar: FaceTime's and WhatsApp's are there only in a call.
    var menuMic = false
    /// The buttons a small window (a call's, not a list of chats) showed, by name, for when nothing's found.
    var seen: [String] = []
    /// False when a walk ran out of time or the app stopped answering.
    var complete = true
}

/// From the struct's own fields: with Foundation alone (Checks/callkeys) CGRect has
/// none of CoreGraphics' helpers, such as its width or middle.
private extension CGRect {
    var centre: CGPoint { CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2) }
    var area: CGFloat { size.width * size.height }
}

/// How a press in FaceTime or WhatsApp went.
struct CallKeyResult: Equatable {
    var ok = false
    /// It reached the app, whether or not its effect was seen.
    var delivered = false
    /// Mute: what the app says now, once it was seen to change.
    var muted: Bool?
    var message = ""
}

final class CallAppKeys {
    // seconds
    static let searchTime = 2.0
    static let restoreDelay = 0.35
    static let verifyStep = 0.1
    static let muteVerify = 1.5
    static let leaveVerify = 3.0
    static let windowWalkCap = 3000
    static let menuWalkCap = 1500
    static let reportLines = 40
    static let revealWait = 0.35        // for FaceTime's buttons to appear under the pointer
    static let windowChrome: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"]

    static let muteRoles: Set<String> = ["AXButton", "AXCheckBox", "AXMenuItem", "AXMenuButton", "AXRadioButton", "AXToggle"]

    let backend: MeetingBackend
    var now: () -> Date = Date.init
    var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    init(backend: MeetingBackend) { self.backend = backend }

    // MARK: - Finding

    /// The call's mute and leave controls in an app.
    func find(_ appElement: AnyObject, _ app: LabelledCallApp) -> CallControls {
        var out = CallControls()
        let deadline = now().addingTimeInterval(Self.searchTime)
        // call windows: a mic control beside something that ends the call
        var calls: [(mics: [CallControls.Control], leaves: [CallControls.Control], named: Bool)] = []
        var otherMutes: [CallControls.Control] = [], menuMutes: [CallControls.Control] = []
        var namedLeaves: [CallControls.Control] = []

        let windows: [AnyObject]
        do { windows = try backend.windows(appElement) } catch {
            out.complete = false
            windows = []
        }
        for w in windows {
            if now() > deadline { out.complete = false; break }
            let title = (try? backend.read(w))?.title ?? ""
            var late = false
            let (tree, _, truncated) = MeetingNode.walk(backend, w, maxNodes: Self.windowWalkCap) { _ in
                late = self.now() > deadline
                return late
            }
            if truncated || late { out.complete = false }

            var mics: [CallControls.Control] = []
            var bare: [CallControls.Control] = [], named: [CallControls.Control] = []
            var buttons: [String] = []
            tree.each { n in
                guard n.expanded else { return true }
                if ["AXButton", "AXCheckBox"].contains(n.attrs.role), !Self.windowChrome.contains(n.attrs.subrole), !n.attrs.label.isEmpty {
                    buttons.append(n.attrs.label)
                }
                guard n.attrs.isEnabled else { return true }
                if Self.muteRoles.contains(n.attrs.role), let r = n.attrs.muteReading {
                    mics.append(.init(element: n.element, label: r.label, window: title, muted: r.muted))
                } else if let r = n.attrs.leaveReading {
                    let c = CallControls.Control(element: n.element, label: r.label, window: title)
                    if r.kind == .call { named.append(c) } else if app.bareLeave { bare.append(c) }
                }
                return true
            }
            if buttons.count <= Self.reportLines { out.seen += buttons }
            if !mics.isEmpty && !(bare.isEmpty && named.isEmpty) {
                calls.append((mics, named + bare, !named.isEmpty))
            } else {
                if !app.muteNeedsLeave { otherMutes += mics }
                namedLeaves += named
            }
        }
        // more than one: the one whose button says it ends the call first
        calls = calls.filter { $0.named } + calls.filter { !$0.named }

        if let bar = backend.menuBar(appElement) {
            var late = false
            let (tree, _, truncated) = MeetingNode.walk(backend, bar, maxNodes: Self.menuWalkCap, maxDepth: 5) { _ in
                late = self.now() > deadline
                return late
            }
            if truncated || late { out.complete = false }
            tree.each { n in
                guard n.expanded, n.attrs.isEnabled, n.attrs.role == "AXMenuItem" else { return true }
                if let r = n.attrs.muteReading, app.menuMute(r.label) {
                    menuMutes.append(.init(element: n.element, label: r.label, window: "", muted: r.muted))
                    out.menuMic = true
                } else if let r = n.attrs.leaveReading, r.kind == .call {
                    namedLeaves.append(.init(element: n.element, label: r.label, window: ""))
                }
                return true
            }
        }

        out.mute = calls.flatMap { $0.mics } + otherMutes + menuMutes
        out.leave = calls.first?.leaves.first ?? namedLeaves.first
        return out
    }

    // MARK: - Pressing

    /// Presses the call's own mute or leave control in `app` (process `pid`),
    /// hands focus back to the app you were in, and checks it took.
    func press(_ what: MeetingControl, in app: LabelledCallApp, pid: Int32) -> CallKeyResult {
        let appElement = backend.application(pid)
        backend.enable(appElement, full: false)  // a Chromium or Electron build shows its tree only when asked
        let previous = backend.frontmostPID()
        var before = find(appElement, app)
        var r = CallKeyResult()

        // FaceTime's End button is there only under the pointer: in a call (its menu's Mute
        // is on), show it — and put the pointer and your app back once it's pressed
        var movedFrom: CGPoint?, raised = false
        if what != .mute, before.leave == nil, app.hoverControls, before.menuMic {
            let revealed = reveal(appElement, app, pid)
            before = revealed.controls
            movedFrom = revealed.movedFrom
            raised = revealed.raised
        }
        func handBack(pressed: Bool) {
            if let from = movedFrom { backend.movePointer(to: from); movedFrom = nil }
            // an app may come forward on a press: put yours back on top
            if (pressed || raised) && previous != 0 && previous != pid {
                wait(Self.restoreDelay)
                backend.activate(previous)
            }
        }
        let shown = before.seen.isEmpty ? "" : " It showed: \(before.seen.prefix(12).map { "“\($0)”" }.joined(separator: ", "))."

        let target: CallControls.Control
        switch what {
        case .mute:
            guard let first = before.mute.first else {
                r.message = "No mute button found in \(app.label)'s call.\(shown) Settings ▸ Call apps ▸ Inspect lists what \(app.label) shows."
                return r
            }
            target = first
        case .leave, .end:                       // neither app ends a call for everyone: a hold just leaves
            guard let leave = before.leave else {
                handBack(pressed: false)
                r.message = "No button that ends the call found in \(app.label).\(shown) Settings ▸ Call apps ▸ Inspect lists what \(app.label) shows."
                return r
            }
            target = leave
        }
        let name = "\(app.label)'s “\(target.label)”\(target.window.isEmpty ? " (menu bar)" : "")"

        do { try backend.perform(target.element, "AXPress") } catch MeetingAXError.busy {
            r.delivered = true                   // timed out waiting, but it may still land
        } catch {
            handBack(pressed: false)
            r.message = "Couldn't press \(name): \(error)."
            return r
        }
        r.delivered = true
        handBack(pressed: true)

        if what == .mute {
            let was = before.mute.map(\.muted)
            let after = seen(within: Self.muteVerify) { () -> [Bool]? in
                let readings = self.find(appElement, app).mute.map(\.muted)
                return self.changed(was, readings) ? readings : nil
            }
            if let after {
                r.ok = true
                // what the sign reads: the first control, as MuteDetector reads it
                r.muted = after.first
                if let shown = after.first, shown != was.first {
                    r.message = "Pressed \(name): \(shown ? "muted" : "mic live")."
                } else {
                    r.message = "Pressed \(name); \(app.label) shows it changed elsewhere (its menu), not on that button, so the sign can't."
                }
            } else {
                r.message = "Pressed \(name), but its mute didn't change."
            }
        } else {
            // the button itself going (or greying out), or the app's menu-bar Mute greying out
            // (there only in a call) — never just buttons hiding as the pointer leaves the window
            let inCall = before.menuMic
            let left = seen(within: Self.leaveVerify) { () -> Bool? in
                if self.ended(target.element) { return true }
                return inCall && !self.menuMicOn(appElement, app) ? true : nil
            }
            if left != nil {
                r.ok = true
                r.message = "Pressed \(name): left the call."
            } else {
                r.message = "Pressed \(name), but the call still shows."
            }
        }
        return r
    }

    /// Shows FaceTime's call buttons: two small pointer moves sent to FaceTime
    /// alone, which leave your pointer where it is; if its buttons still don't
    /// show, its window brought forward and the pointer moved over it. Where
    /// the pointer was, to put it back.
    private func reveal(_ appElement: AnyObject, _ app: LabelledCallApp, _ pid: Int32)
        -> (controls: CallControls, movedFrom: CGPoint?, raised: Bool) {
        let framed = ((try? backend.windows(appElement)) ?? []).compactMap { w in backend.frame(w).map { (w, $0) } }
        guard let biggest = framed.max(by: { $0.1.area < $1.1.area }) else {
            return (find(appElement, app), nil, false)
        }
        let (window, frame) = biggest
        backend.nudge(pid, at: frame.centre)
        wait(Self.revealWait)
        var found = find(appElement, app)
        guard found.leave == nil, let from = backend.pointer() else { return (found, nil, false) }

        let raised = backend.bringForward(window, pid: pid)
        let spot = (backend.frame(window) ?? frame).centre          // brought forward, it may be on another desktop
        backend.movePointer(to: spot)
        wait(Self.revealWait)
        backend.movePointer(to: CGPoint(x: spot.x + 2, y: spot.y))
        wait(Self.revealWait)
        found = find(appElement, app)
        return (found, from, raised)
    }

    /// Whether the app's menu bar has an enabled mute item: its call is still on.
    private func menuMicOn(_ appElement: AnyObject, _ app: LabelledCallApp) -> Bool {
        guard let bar = backend.menuBar(appElement) else { return false }
        var on = false
        _ = MeetingNode.walk(backend, bar, maxNodes: Self.menuWalkCap, maxDepth: 5) { n in
            if n.attrs.role == "AXMenuItem", n.attrs.isEnabled, let r = n.attrs.muteReading, app.menuMute(r.label) { on = true }
            return on
        }
        return on
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

    /// Whether a mute control's reading changed, matched by place; a rebuilt
    /// set of controls by its first.
    private func changed(_ before: [Bool], _ after: [Bool]) -> Bool {
        if before.count == after.count { return before != after }
        guard let a = after.first else { return false }
        return a != before.first
    }

    /// Whether a pressed end button has gone from the app, or greyed out.
    private func ended(_ e: AnyObject) -> Bool {
        do {
            let a = try backend.read(e)
            return a.role.isEmpty || !a.isEnabled
        } catch {
            return error as? MeetingAXError == .invalid
        }
    }

    // MARK: - Diagnostics

    /// What an app shows, for Settings ▸ Call apps ▸ Inspect: its windows'
    /// controls, its menu-bar items that read as mute or leave, and what each
    /// key would press. Touches nothing.
    func report(_ app: LabelledCallApp, pid: Int32) -> String {
        guard pid != 0 else { return "### \(app.label): not running\n\n" }
        let appElement = backend.application(pid)
        backend.enable(appElement, full: false)
        let windows = (try? backend.windows(appElement)) ?? []
        var out = "### \(app.label): pid \(pid), \(windows.count) window(s)\n"
        let controls: Set<String> = ["AXButton", "AXCheckBox", "AXMenuButton", "AXRadioButton", "AXPopUpButton", "AXToggle"]
        for w in windows {
            let (tree, n, truncated) = MeetingNode.walk(backend, w, maxNodes: Self.windowWalkCap)
            var lines: [String] = [], reading: [String] = []
            tree.each { x in
                guard x.expanded, controls.contains(x.attrs.role) || !x.attrs.id.isEmpty else { return true }
                lines.append("  " + x.attrs.line)
                if x.attrs.muteReading != nil || x.attrs.leaveReading != nil { reading.append("  " + x.attrs.line) }
                return true
            }
            out += "== “\(tree.attrs.title)”: \(n) nodes\(truncated ? " (cut short)" : "")\n"
            // a call's window is small; a big one is a list of chats, whose names stay out of the report
            let shown = lines.count <= Self.reportLines ? lines : reading
            if lines.count > Self.reportLines { out += "  \(lines.count) controls: a big window (chats?), so only those that read as mute or leave\n" }
            out += shown.joined(separator: "\n") + (shown.isEmpty ? "" : "\n")
        }
        if let bar = backend.menuBar(appElement) {
            let tree = MeetingNode.walk(backend, bar, maxNodes: Self.menuWalkCap, maxDepth: 5).tree
            var lines: [String] = []
            tree.each { x in
                if x.expanded && x.attrs.role == "AXMenuItem" && (x.attrs.muteReading != nil || x.attrs.leaveReading != nil) {
                    lines.append("  " + x.attrs.line)
                }
                return true
            }
            out += "== menu bar: \(lines.isEmpty ? "nothing that reads as mute or leave" : "")\n" + lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        }
        let found = find(appElement, app)
        func place(_ c: CallControls.Control) -> String { c.window.isEmpty ? "the menu bar" : "“\(c.window)”" }
        let mute = found.mute.first.map { "“\($0.label)” in \(place($0)) (\($0.muted ? "muted" : "mic live"))" } ?? "nothing found"
        let leave = found.leave.map { "“\($0.label)” in \(place($0))" } ?? "nothing found"
        out += "Mute key presses: \(mute)\nLeave key presses: \(leave)\(found.complete ? "" : "\n(the search was cut short)")\n\n"
        return out
    }
}
