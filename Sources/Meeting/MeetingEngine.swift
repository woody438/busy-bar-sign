import Foundation

/*
 * Follows meetings in Teams and Zoom through Accessibility — whether you're
 * in one, muted, and able to leave — presses their own mute and leave
 * controls, and closes the "rate your call" survey that follows. A Swift
 * port of the helper in Woody's Teams Meeting Keys plugin (teamsax), whose
 * tests Checks/meeting carries across.
 *
 *   Teams  its meeting window's toolbar: the HTML ids microphone-button and
 *          hangup-button, read as Chromium exposes them (AXDOMIdentifier)
 *   Zoom   its menu bar: Meeting ▸ Mute audio / Unmute audio / Join audio,
 *          there only in a meeting
 *
 * Every method runs on one thread (MeetingKeys' queue); Tick says when to
 * come back. Nothing here touches a meeting window that is still live
 * except its mute and leave buttons, and a popup is only pressed when its
 * text reads as a survey, and then only on a button that just closes it.
 */

/// One meeting app, as the keys see it.
struct MeetingAppState: Equatable {
    var running = false
    var inMeeting = false
    /// nil: in a meeting but the mute state can't be read (or Zoom's audio isn't joined).
    var muted: Bool?
    var canLeave = false
    var window = ""
    var muteLabel = ""
}

/// Both apps, and which one the keys act on.
struct MeetingSnapshot: Equatable {
    var trusted = false
    /// The most recently joined meeting, or nil when there's none.
    var active: MeetingApp?
    var apps: [MeetingApp: MeetingAppState] = [:]

    var current: MeetingAppState? { active.flatMap { apps[$0] } }
}

/// A popup met after a call, and what was done about it.
struct MeetingPopup: Equatable {
    var app: MeetingApp
    var matched: Bool
    var action: String
    var window: String
    var text: String
}

/// How a press of an app's own control went. `delivered` means it reached
/// the app even if its effect wasn't seen yet: the keyboard shortcut must
/// not then follow at once, or mute would toggle twice.
struct MeetingPress: Equatable {
    var ok = false
    var delivered = false
    var app: MeetingApp?
    var error = ""
}

/// What a key asks for. `end` is the Leave key held: Zoom's "End meeting for
/// all" when you host it; anything else just leaves.
enum MeetingControl: String { case mute, leave, end }

final class MeetingEngine {
    static let micID = "microphone-button"
    static let hangupID = "hangup-button"

    // seconds
    static let pollInMeeting = 0.5
    static let pollIdle = 2.0
    static let pollUntrusted = 3.0
    static let discoverEvery = 2.0
    static let slowWalkEvery = 4.0
    static let slowWalkBig = 15.0      // windows too big to be a lobby (a popped-out chat)
    static let pidCheckEvery = 5.0
    static let trustCheck = 30.0
    static let flyoutGrace = 20.0
    static let surveyWatch = 75.0
    static let surveyScanGap = 1.5
    static let confirmWatch = 4.0
    static let restoreDelay = 0.35
    static let verifyStep = 0.1
    static let verifySteps = 10
    static let bigWindow = 1500
    static let maxPopupLines = 60
    static let meetingWalkCap = 5000
    static let surveyWalkCap = 5000
    static let menuWalkCap = 1200

    let backend: MeetingBackend
    var patterns: MeetingPatterns
    var dismissSurveys = true
    var now: () -> Date = Date.init
    var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var onState: (MeetingSnapshot) -> Void = { _ in }
    var onPopup: (MeetingPopup) -> Void = { _ in }
    var log: (String) -> Void = { _ in }

    private(set) var trusted = false
    private var trustCheckedAt = Date.distantPast
    let trackers: [Tracker]
    private var attempts: [String: Int] = [:]
    private var reported = Set<String>()
    private var lastPublished: MeetingSnapshot?

    init(backend: MeetingBackend, patterns: MeetingPatterns = .shipped) {
        self.backend = backend
        self.patterns = patterns
        trackers = MeetingApp.allCases.map(Tracker.init)
    }

    /// One meeting app's process and what's known of its meeting.
    final class Tracker {
        let app: MeetingApp
        var pid: Int32 = 0
        var pidCheckedAt = Date.distantPast
        var element: AnyObject?

        var mute: AnyObject?        // Teams: the toolbar buttons; Zoom: the Meeting-menu item
        var leave: AnyObject?
        var inMeeting = false
        var startedAt = Date.distantPast
        var muted: Bool?
        var label = ""
        var canLeave = false
        var window = ""
        var toolbarSeen = Date.distantPast

        var nextDiscovery = Date.distantPast
        var slowWalk: [String: Date] = [:]
        var askedFull = false       // Teams asked as VoiceOver asks (AXEnhancedUserInterface)

        var surveyUntil = Date.distantPast
        var nextSurveyScan = Date.distantPast
        var confirmUntil = Date.distantPast   // Zoom: answer its "Leave meeting?" prompt till then
        var endForAll = false                 // with "End meeting for all", if it offers it
        var assignNext = false                // "Leave meeting" pressed: then "Assign a new host", if it asks

        init(_ app: MeetingApp) { self.app = app }
    }

    func tracker(_ app: MeetingApp) -> Tracker { trackers.first { $0.app == app }! }

    /// The app the keys act on: the most recently joined meeting.
    var active: Tracker? {
        trackers.filter(\.inMeeting).max { $0.startedAt < $1.startedAt }
    }

    // MARK: - Ticking

    /// One round of work; returns how long to wait before the next.
    @discardableResult
    func tick() -> TimeInterval {
        let now = self.now()
        if !trusted || now.timeIntervalSince(trustCheckedAt) >= Self.trustCheck {
            let was = trusted
            trusted = backend.trusted()
            trustCheckedAt = now
            if was && !trusted { log("lost Accessibility permission") }
        }
        guard trusted else {
            for t in trackers { reset(t, pid: 0) }
            publish()
            return Self.pollUntrusted
        }
        var busy = false
        for t in trackers where tickApp(t, now) { busy = true }
        publish()
        return busy ? Self.pollInMeeting : Self.pollIdle
    }

    /// Updates one app; true when it wants fast polling.
    private func tickApp(_ t: Tracker, _ now: Date) -> Bool {
        if now.timeIntervalSince(t.pidCheckedAt) >= Self.pidCheckEvery || (t.pid != 0 && !backend.alive(t.pid)) {
            t.pidCheckedAt = now
            let pid = backend.findApp(t.app)
            if pid != t.pid { reset(t, pid: pid) }
        }
        guard t.pid != 0 else { return false }

        if t.mute != nil { readControls(t, now) }
        if t.mute == nil && now >= t.nextDiscovery {
            discover(t, now)
            t.nextDiscovery = now.addingTimeInterval(Self.discoverEvery)
        } else if t.app == .teams && t.mute != nil && t.leave == nil && now >= t.nextDiscovery {
            // Teams can redraw its hang-up button mid-call while the mute button reads on
            t.nextDiscovery = now.addingTimeInterval(findLeave(t) ? Self.discoverEvery : Self.slowWalkEvery)
        }
        if now < t.confirmUntil { confirmZoomLeave(t, now) }

        let surveyActive = now < t.surveyUntil
        if surveyActive && dismissSurveys && !t.inMeeting && now >= t.nextSurveyScan {
            _ = scanPopups(t, act: true)
            t.nextSurveyScan = self.now().addingTimeInterval(Self.surveyScanGap)
        }
        return t.inMeeting || surveyActive || now < t.confirmUntil
    }

    /// Forgets everything tied to an app's previous process.
    private func reset(_ t: Tracker, pid: Int32) {
        dropControls(t)
        t.element = nil
        t.inMeeting = false
        t.muted = nil
        t.label = ""
        t.canLeave = false
        t.window = ""
        t.pid = pid
        t.nextDiscovery = .distantPast
        t.slowWalk = [:]
        t.askedFull = false
        if pid != 0 {
            let app = backend.application(pid)
            t.element = app
            if t.app == .teams { backend.enable(app, full: false) }   // Chromium builds its tree on request
            log("attached to \(t.app.label) (pid \(pid))")
        }
    }

    private func dropControls(_ t: Tracker) {
        t.mute = nil
        t.leave = nil
    }

    /// Re-reads an app's controls, found already.
    private func readControls(_ t: Tracker, _ now: Date) {
        guard let mute = t.mute else { return }
        let a: MeetingAttrs
        do {
            a = try backend.read(mute)
        } catch MeetingAXError.busy {
            return                                  // busy: keep what we have
        } catch MeetingAXError.untrusted {
            trustCheckedAt = .distantPast           // permission withdrawn: look again next tick
            return
        } catch {
            dropControls(t)
            t.nextDiscovery = .distantPast          // look again straight away
            return
        }
        if a.role.isEmpty {
            dropControls(t)
            t.nextDiscovery = .distantPast
            return
        }
        applyMute(t, a)
        t.toolbarSeen = now
        if t.app == .zoom {
            if !a.isEnabled || !MeetingPatterns.matches(MeetingPatterns.zoomMuteItem, a.title) {
                dropControls(t)
                meetingEnded(t, now, why: "Zoom's Meeting menu changed")
            }
            return
        }
        if let leave = t.leave {
            do {
                let h = try backend.read(leave)
                if h.role.isEmpty { t.leave = nil; t.canLeave = false } else { t.canLeave = h.isEnabled }
            } catch MeetingAXError.busy {
            } catch {
                t.leave = nil
                t.canLeave = false
            }
        }
    }

    private func applyMute(_ t: Tracker, _ a: MeetingAttrs) {
        if t.app == .zoom {
            t.label = a.title
            let lower = a.title.trimmingCharacters(in: .whitespaces).lowercased()
            if lower.hasPrefix("unmute") { t.muted = true }
            else if lower.hasPrefix("mute") { t.muted = false }
            else { t.muted = nil }                  // "Join audio": in the meeting, audio not connected
            t.canLeave = true
            return
        }
        t.label = a.label
        t.muted = a.isEnabled ? patterns.muted(byLabel: t.label) : nil
    }

    // MARK: - Finding meetings

    struct Window {
        let element: AnyObject
        let title: String
        let subrole: String
        let kind: MeetingWindowKind
    }

    func windows(_ t: Tracker) -> [Window] {
        guard let app = t.element else { return [] }
        let list: [AnyObject]
        do { list = try backend.windows(app) } catch {
            if error as? MeetingAXError == .untrusted { trustCheckedAt = .distantPast }
            if error as? MeetingAXError == .invalid {
                log("\(t.app.label)'s application element went stale; attaching again")
                reset(t, pid: t.pid)
            }
            return []
        }
        return list.map { w in
            let a = (try? backend.read(w)) ?? MeetingAttrs()
            return Window(element: w, title: a.title, subrole: a.subrole, kind: MeetingWindows.kind(t.app, title: a.title, subrole: a.subrole))
        }
    }

    private func meetingStarted(_ t: Tracker, _ now: Date, window: String) {
        if !t.inMeeting {
            log("\(t.app.label) meeting found: “\(window)”")
            t.startedAt = now
        }
        t.inMeeting = true
        t.window = window
        t.toolbarSeen = now
        t.surveyUntil = .distantPast
    }

    private func discover(_ t: Tracker, _ now: Date) {
        if t.app == .teams { discoverTeams(t, now) } else { discoverZoom(t, now) }
    }

    /// Looks for the meeting toolbar in Teams' meeting windows.
    private func discoverTeams(_ t: Tracker, _ now: Date) {
        let wins = windows(t)
        let candidates = wins.filter { $0.kind == .meeting } + wins.filter { $0.kind == .compact }
        let stillThere = !t.window.isEmpty && wins.contains { $0.title == t.window }
        var endedSeen = false

        for w in candidates.prefix(4) {
            if let next = t.slowWalk[w.title], now < next { continue }
            var mic: MeetingNode?, hang: MeetingNode?
            var web = false
            let (tree, read, _) = MeetingNode.walk(backend, w.element, maxNodes: Self.meetingWalkCap) { n in
                if n.attrs.role == "AXWebArea" { web = true }
                if n.attrs.id == Self.micID { mic = n }
                if n.attrs.id == Self.hangupID { hang = n }
                return mic != nil && hang != nil
            }
            if let mic {
                dropControls(t)
                t.mute = mic.element
                t.canLeave = false
                if let hang {
                    t.leave = hang.element
                    t.canLeave = hang.attrs.isEnabled
                }
                meetingStarted(t, now, window: w.title)
                applyMute(t, mic.attrs)
                t.slowWalk[w.title] = nil
                return
            }
            tree.each { n in
                if n.expanded && MeetingPatterns.matches(patterns.ended, n.attrs.label) { endedSeen = true; return false }
                return true
            }
            t.slowWalk[w.title] = now.addingTimeInterval(read >= Self.bigWindow ? Self.slowWalkBig : Self.slowWalkEvery)
            // No web content in a meeting window — only its title-bar buttons — means Chromium
            // (Teams is built on it) hasn't built the page's tree: ask as VoiceOver does
            if read < 10 || !web, let app = t.element {
                if !t.askedFull {
                    log("asking Teams to show its meeting controls to Accessibility (AXEnhancedUserInterface)")
                    t.askedFull = true
                }
                backend.enable(app, full: true)
            }
        }

        if t.inMeeting {
            if stillThere && !endedSeen && now.timeIntervalSince(t.toolbarSeen) < Self.flyoutGrace {
                return                              // a menu or popup is covering the toolbar: keep the last reading
            }
            meetingEnded(t, now, why: "toolbar gone")
        }
    }

    /// Looks for Teams' hang-up button again in the meeting window, the mute
    /// button still found: the one there was redrawn, or wasn't drawn yet.
    /// True if it walked a small window (or found it), so it can look again soon.
    private func findLeave(_ t: Tracker) -> Bool {
        guard let w = windows(t).first(where: { $0.title == t.window }) else { return true }
        var hang: MeetingNode?
        let (_, read, _) = MeetingNode.walk(backend, w.element, maxNodes: Self.meetingWalkCap) { n in
            if n.attrs.id == Self.hangupID { hang = n }
            return hang != nil
        }
        guard let hang else { return read < Self.bigWindow }
        t.leave = hang.element
        t.canLeave = hang.attrs.isEnabled
        log("found Teams' leave button again")
        return true
    }

    /// Reads Zoom's Meeting menu: "Mute audio" / "Unmute audio" is there only in a meeting.
    private func discoverZoom(_ t: Tracker, _ now: Date) {
        guard let app = t.element, let bar = backend.menuBar(app) else {
            if t.inMeeting { meetingEnded(t, now, why: "no menu bar") }
            return
        }
        var item: MeetingNode?
        _ = MeetingNode.walk(backend, bar, maxNodes: Self.menuWalkCap, maxDepth: 4) { n in
            if n.attrs.role == "AXMenuItem", MeetingPatterns.matches(MeetingPatterns.zoomMuteItem, n.attrs.title), n.attrs.isEnabled {
                item = n
                return true
            }
            return false
        }
        guard let item else {
            if t.inMeeting { meetingEnded(t, now, why: "Meeting menu gone") }
            return
        }
        t.mute = item.element
        let window = windows(t).first { $0.kind == .meeting }?.title ?? "Zoom Meeting"
        meetingStarted(t, now, window: window)
        applyMute(t, item.attrs)
    }

    private func meetingEnded(_ t: Tracker, _ now: Date, why: String) {
        log("\(t.app.label) meeting ended (\(why))")
        dropControls(t)
        t.inMeeting = false
        t.muted = nil
        t.label = ""
        t.canLeave = false
        t.window = ""
        startSurveyWatch(t, now)
    }

    func startSurveyWatch(_ t: Tracker, _ now: Date) {
        t.surveyUntil = now.addingTimeInterval(Self.surveyWatch)
        t.nextSurveyScan = now.addingTimeInterval(0.8)
        attempts = [:]
    }

    // MARK: - Pressing

    /// After the leave shortcut went to an app (nil: the active one).
    /// `endForAll`: answer Zoom's prompt with "End meeting for all" if it offers it.
    func left(_ app: MeetingApp?, endForAll: Bool = false) {
        let now = self.now()
        let t = app.map(tracker) ?? active ?? tracker(.teams)
        if t.app == .zoom {                         // Zoom asks "Leave meeting?" first
            t.confirmUntil = now.addingTimeInterval(Self.confirmWatch)
            t.endForAll = endForAll
            t.assignNext = false
        }
        if t.inMeeting && t.app == .teams {
            meetingEnded(t, now, why: "leave key")
        } else if !t.inMeeting {
            startSurveyWatch(t, now)
        }
        t.nextDiscovery = now.addingTimeInterval(Self.verifyStep)
        publish()
    }

    /// After the mute shortcut was sent: read again now, and always publish.
    func pressed() {
        let now = self.now()
        for t in trackers {
            if t.mute != nil { readControls(t, now) } else { t.nextDiscovery = .distantPast }
        }
        publish(force: true)
    }

    /// Presses the active meeting's own mute or leave control, checks it
    /// took, and hands focus back to the app you were in.
    func press(_ what: MeetingControl) -> MeetingPress {
        guard let t = active else { return MeetingPress(error: "no meeting") }
        var r = MeetingPress(app: t.app)
        let target: AnyObject?
        switch (what, t.app) {
        case (.mute, .zoom) where t.muted == nil:
            r.error = "Zoom audio not joined"
            return r
        case (.mute, _):
            target = t.mute
        case (.leave, .teams), (.end, .teams):     // Teams: ending for everyone isn't done; leave
            target = t.leave
        case (.leave, .zoom), (.end, .zoom):
            r.error = "use the shortcut"            // Zoom's leave goes through ⌘W and its confirmation
            return r
        }
        guard let target else {
            r.error = "control not found"
            return r
        }

        let before = t.muted
        let previous = backend.frontmostPID()
        do { try backend.perform(target, "AXPress") } catch MeetingAXError.busy {
            r.delivered = true                      // timed out waiting, but it may still land
            r.error = "app busy"
            return r
        } catch {
            r.error = "press failed: \(error)"
            return r
        }
        r.delivered = true
        // Teams brings its window forward a moment after a press: put your app back on top
        if previous != 0 && previous != t.pid {
            wait(Self.restoreDelay)
            backend.activate(previous)
        }

        // did it work? Mute must flip; leave must take the toolbar away
        for _ in 0..<Self.verifySteps where !r.ok {
            let now = self.now()
            if what == .mute {
                if t.mute == nil { discover(t, now) }   // the button was rebuilt: find it again
                if t.mute != nil { readControls(t, now) }
                r.ok = before == nil || (t.muted != nil && t.muted != before)
            } else {
                do {
                    r.ok = try backend.read(target).role.isEmpty
                } catch {
                    r.ok = error as? MeetingAXError == .invalid
                }
            }
            if !r.ok { wait(Self.verifyStep) }
        }
        guard r.ok else {
            r.error = "no effect seen yet"
            publish()
            return r
        }
        if what != .mute { left(t.app, endForAll: what == .end) }
        publish()
        return r
    }

    /// Answers Zoom's "Leave meeting?" prompt: "Leave meeting" for a press of
    /// the Leave key, host or not; "End meeting for all" for a hold, when the
    /// prompt offers it (you're the host) — else a hold just leaves. A host
    /// who leaves is asked for a new host next: "Assign and leave" hands over
    /// to the one Zoom picked; with no one picked, it's left to you. Only the
    /// prompt's own buttons, never a toolbar button of the same name.
    private func confirmZoomLeave(_ t: Tracker, _ now: Date) {
        for w in windows(t) where w.kind != .main {
            var leave: MeetingNode?, end: MeetingNode?, assign: MeetingNode?
            let (tree, _, _) = MeetingNode.walk(backend, w.element, maxNodes: 2000)
            tree.each { n in
                guard n.expanded, n.attrs.role == "AXButton", w.kind != .meeting || n.inPopup else { return true }
                let l = n.attrs.label
                if end == nil, MeetingPatterns.matches(MeetingPatterns.zoomEndForAll, l) {
                    end = n
                } else if leave == nil, MeetingPatterns.matches(MeetingPatterns.zoomLeaveButton, l) {
                    leave = n
                } else if assign == nil, MeetingPatterns.matches(MeetingPatterns.zoomAssignAndLeave, l) {
                    assign = n
                }
                return true
            }
            if t.assignNext {
                guard let assign, assign.attrs.isEnabled else { continue }
                if (try? backend.perform(assign.element, "AXPress")) != nil {
                    log("left the Zoom meeting to the new host it picked")
                }
                t.confirmUntil = .distantPast
                return
            }
            guard let button = t.endForAll ? (end ?? leave) : leave else { continue }
            if (try? backend.perform(button.element, "AXPress")) != nil {
                log(button === end ? "ended the Zoom meeting for everyone" : "confirmed Zoom's Leave meeting prompt\(end == nil ? "" : " (as host)")")
            }
            if button === leave {                   // as host, Zoom asks for a new host next
                t.assignNext = true
                t.confirmUntil = now.addingTimeInterval(Self.confirmWatch)
            } else {
                t.confirmUntil = .distantPast
            }
            return
        }
    }

    // MARK: - State

    func snapshot() -> MeetingSnapshot {
        var s = MeetingSnapshot(trusted: trusted)
        for t in trackers {
            s.apps[t.app] = MeetingAppState(running: t.pid != 0, inMeeting: t.inMeeting, muted: t.muted,
                                            canLeave: t.canLeave, window: t.window, muteLabel: t.label)
        }
        s.active = active?.app
        return s
    }

    func publish(force: Bool = false) {
        let s = snapshot()
        if force || s != lastPublished {
            lastPublished = s
            onState(s)
        }
    }

    // MARK: - Popups after a call

    private final class Container {
        let node: MeetingNode
        let window: Window
        let whole: Bool         // a whole window that isn't the app's main one
        let text: String
        let lines: Int
        let key: String
        var survey = false

        init(_ node: MeetingNode, _ window: Window, whole: Bool) {
            self.node = node
            self.window = window
            self.whole = whole
            let texts = node.texts(limit: 300)
            text = texts.joined(separator: "\n")
            lines = texts.count
            key = window.title + "\u{0}" + text
        }
    }

    /// The dialogs and secondary windows of an app. Main windows only give
    /// their dialogs, so chat never ends up in a report.
    private func containers(_ t: Tracker, _ wins: [Window]) -> [Container] {
        var out: [Container] = []
        for w in wins {
            if t.inMeeting && w.title == t.window { continue }   // the live meeting window is never touched
            let tree = MeetingNode.walk(backend, w.element, maxNodes: Self.surveyWalkCap).tree
            if tree.find(id: Self.micID) != nil || tree.find(id: Self.hangupID) != nil { continue }   // a live Teams meeting
            // a meeting window counts only once it says the call is over ("Rejoin")
            if (w.kind == .meeting || w.kind == .compact) && !showsEnded(tree) { continue }

            var dialogs: [MeetingNode] = []
            tree.each { n in
                if n.expanded && n !== tree && n.isDialog { dialogs.append(n) }
                return true
            }
            // innermost first, so the dialog holding the text is the one acted on
            for d in dialogs.enumerated().sorted(by: { ($1.element.depth, $0.offset) < ($0.element.depth, $1.offset) }).map(\.element) {
                out.append(container(d, w, whole: false))
            }
            if w.kind != .main { out.append(container(tree, w, whole: true)) }
        }
        return out
    }

    private func container(_ n: MeetingNode, _ w: Window, whole: Bool) -> Container {
        let c = Container(n, w, whole: whole)
        // a survey is a small popup: a whole window full of text (a chat) isn't one
        c.survey = MeetingPatterns.matches(patterns.survey, c.text) && (!whole || c.lines <= Self.maxPopupLines)
        return c
    }

    private func showsEnded(_ tree: MeetingNode) -> Bool {
        var ended = false
        tree.each { n in
            if n.expanded && MeetingPatterns.matches(patterns.ended, n.attrs.label) { ended = true; return false }
            return true
        }
        return ended
    }

    /// A button that only closes the popup.
    private func dismissButton(_ c: Container) -> MeetingNode? {
        var found: MeetingNode?
        c.node.each { n in
            guard n.expanded, n.attrs.role == "AXButton" || n.attrs.role == "AXLink" else { return true }
            let label = n.attrs.label.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, n.attrs.isEnabled else { return true }
            if MeetingPatterns.matches(patterns.dismiss, label) && !MeetingPatterns.matches(patterns.never, label) {
                found = n
                return false
            }
            return true
        }
        return found
    }

    /// Looks for post-call surveys, and closes them when `act` is true.
    /// Returns a report of everything seen (Capture).
    func scanPopups(_ t: Tracker, act: Bool) -> String {
        let conts = containers(t, windows(t))
        var report = ""
        var handled: [MeetingNode] = []
        for c in conts {
            if handled.contains(where: { c.node.contains($0) }) { continue }
            let summary = c.node.summary(maxLines: 60)
            report += "== \(t.app.label) \(c.whole ? "window" : "dialog") “\(c.window.title)” (\(c.survey ? "looks like a survey" : "not recognised"))\n\(summary)\n"

            guard c.survey else {
                // small unrecognised popups are reported once; big windows (chat, settings) aren't popups
                if act && !reported.contains(c.key) && c.text.components(separatedBy: "\n").count <= Self.maxPopupLines {
                    reported.insert(c.key)
                    onPopup(MeetingPopup(app: t.app, matched: false, action: "left alone", window: c.window.title, text: summary))
                }
                continue
            }
            guard act else { continue }
            handled.append(c.node)
            guard let action = dismiss(t, c) else { continue }   // every way of closing it has been tried
            log("post-call popup in \(t.app.label) “\(c.window.title)”: \(action)")
            onPopup(MeetingPopup(app: t.app, matched: true, action: action, window: c.window.title, text: summary))
        }
        return report
    }

    /// Climbs a ladder of ever blunter ways to close a survey, one rung a
    /// scan, so a rung that worked is never followed by a blunter one. Nil
    /// once every rung's been tried, so a stubborn popup is reported once.
    private func dismiss(_ t: Tracker, _ c: Container) -> String? {
        let rung = attempts[c.key] ?? 0
        if rung < 0 { return nil }

        var previous = backend.frontmostPID()
        defer {
            if previous != 0 && previous != t.pid {
                wait(Self.restoreDelay)
                backend.activate(previous)
            }
        }

        var ladder: [(name: String, run: () -> Bool)] = []
        if let button = dismissButton(c) {
            ladder.append(("pressed “\(button.attrs.label)”", { (try? self.backend.perform(button.element, "AXPress")) != nil }))
        }
        if backend.actions(c.node.element).contains("AXCancel") {
            ladder.append(("cancelled the dialog", { (try? self.backend.perform(c.node.element, "AXCancel")) != nil }))
        }
        if c.whole {
            ladder.append(("closed the window", {
                guard let close = self.backend.closeButton(c.window.element) else { return false }
                return (try? self.backend.perform(close, "AXPress")) != nil
            }))
        }
        ladder.append(("pressed Escape", { self.backend.postEscape(t.pid) }))

        for i in rung..<ladder.count {
            attempts[c.key] = i == ladder.count - 1 ? -1 : i + 1   // the last resort is never repeated
            if ladder[i].run() { return ladder[i].name }
        }
        attempts[c.key] = -1
        previous = 0                                // nothing pressed, nothing to hand back
        return "couldn't close it"
    }

    // MARK: - Diagnostics

    /// Each app's meeting controls (or its windows, outside a meeting).
    func inspect() -> String {
        guard trusted else {
            return "Busy Bar Sign isn't allowed to use Accessibility yet: System Settings ▸ Privacy & Security ▸ Accessibility."
        }
        var out = ""
        for t in trackers {
            guard t.pid != 0 else {
                out += "### \(t.app.label): not running\n\n"
                continue
            }
            let wins = windows(t)
            out += "### \(t.app.label): pid \(t.pid), \(wins.count) window(s)\n"
            for w in wins { out += "  [\(w.kind.rawValue)] “\(w.title)”\n" }
            let muted = t.muted.map { $0 ? "yes" : "no" } ?? "unknown"
            out += "in meeting: \(t.inMeeting)  muted: \(muted)  label: “\(t.label)”  can leave: \(t.canLeave)\n"
            if t.app == .zoom {
                out += zoomMenuReport(t)
            } else {
                for w in wins where w.kind == .meeting || w.kind == .compact { out += controlsReport(w) }
            }
            out += "\n"
        }
        return out
    }

    private func controlsReport(_ w: Window) -> String {
        let (tree, n, truncated) = MeetingNode.walk(backend, w.element, maxNodes: Self.meetingWalkCap)
        var lines: [String] = []
        tree.each { x in
            if x.expanded && (!x.attrs.id.isEmpty || ["AXButton", "AXCheckBox", "AXPopUpButton"].contains(x.attrs.role)) {
                lines.append("  " + x.attrs.line)
            }
            return lines.count < 120
        }
        return "== “\(w.title)”: \(n) nodes\(truncated ? " (cut short)" : "")\n" + lines.joined(separator: "\n") + "\n"
    }

    private func zoomMenuReport(_ t: Tracker) -> String {
        guard let app = t.element, let bar = backend.menuBar(app) else { return "  (no menu bar)\n" }
        let tree = MeetingNode.walk(backend, bar, maxNodes: Self.menuWalkCap, maxDepth: 4).tree
        var out = "  Meeting menu:\n"
        var inMeetingMenu = false
        tree.each { n in
            guard n.expanded else { return true }
            if n.attrs.role == "AXMenuBarItem" { inMeetingMenu = n.attrs.title.lowercased() == "meeting" }
            if inMeetingMenu && n.attrs.role == "AXMenuItem" && !n.attrs.title.isEmpty {
                out += "    “\(n.attrs.title)”\(n.attrs.isEnabled ? "" : " [disabled]")\n"
            }
            return true
        }
        return out
    }

    /// Every dialog and secondary window, touching nothing.
    func capture() -> String {
        guard trusted else { return "Busy Bar Sign isn't allowed to use Accessibility yet." }
        let out = trackers.filter { $0.pid != 0 }.map { scanPopups($0, act: false) }.joined()
        return out.isEmpty ? "No dialogs or extra Teams or Zoom windows are open." : out
    }
}
