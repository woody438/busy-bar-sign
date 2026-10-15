import Foundation

/*
 * MeetingEngine against a scripted Teams and Zoom: Teams Meeting Keys'
 * helper tests (helper/engine_test.go), carried across, plus its window
 * rules (tests/windows.test.mjs) and its teams-ui.json, which must still
 * load as a patterns file.
 *
 *   swiftc Sources/Meeting/MeetingPatterns.swift Sources/Meeting/MeetingTree.swift \
 *     Sources/Meeting/MeetingEngine.swift Checks/meeting/main.swift -o meeting && ./meeting
 */

// MARK: - A scripted accessibility tree

final class FakeEl {
    var attrs: MeetingAttrs
    var children: [FakeEl] = []
    var actions: [String] = []
    var gone = false
    var closeButton: FakeEl?
    var onAction: ((String) -> Void)?
    weak var parent: FakeEl?

    init(_ attrs: MeetingAttrs, _ kids: [FakeEl]) {
        self.attrs = attrs
        if attrs.role == "AXButton" || attrs.role == "AXMenuItem" { actions = ["AXPress"] }
        add(kids)
    }

    func add(_ kids: [FakeEl]) {
        for k in kids { k.parent = self }
        children += kids
    }

    var isGone: Bool {
        var p: FakeEl? = self
        while let x = p { if x.gone { return true }; p = x.parent }
        return false
    }
}

final class FakeApp {
    let pid: Int32
    init(_ pid: Int32) { self.pid = pid }
}

final class FakeBackend: MeetingBackend {
    var isTrusted = true
    var pid: Int32 = 4242
    var zoomPid: Int32 = 0
    var front: Int32 = 777
    var teamsWindows: [FakeEl] = []
    var zoomWindows: [FakeEl] = []
    var zoomMenu: FakeEl?
    var performed: [String] = []
    var escapes = 0
    var activated: [Int32] = []
    var enables = 0
    var finds = 0
    var busy: [FakeEl] = []

    func el(_ a: MeetingAttrs, _ kids: FakeEl...) -> FakeEl { FakeEl(a, kids) }
    func button(_ id: String, _ label: String) -> FakeEl { FakeEl(MeetingAttrs(role: "AXButton", id: id, desc: label), []) }
    func text(_ s: String) -> FakeEl { FakeEl(MeetingAttrs(role: "AXStaticText", value: s), []) }
    func group(_ kids: FakeEl...) -> FakeEl { FakeEl(MeetingAttrs(role: "AXGroup"), kids) }
    func dialog(_ kids: FakeEl...) -> FakeEl { FakeEl(MeetingAttrs(role: "AXGroup", subrole: "AXApplicationDialog"), kids) }
    func window(_ title: String, _ kids: FakeEl...) -> FakeEl {
        let w = FakeEl(MeetingAttrs(role: "AXWindow", subrole: "AXStandardWindow", title: title), kids)
        let close = button("", "close button")
        close.attrs.subrole = "AXCloseButton"
        w.closeButton = close
        return w
    }

    private func fake(_ e: AnyObject) throws -> FakeEl {
        guard let x = e as? FakeEl, !x.isGone else { throw MeetingAXError.invalid }
        return x
    }

    func trusted() -> Bool { isTrusted }
    func findApp(_ app: MeetingApp) -> Int32 { finds += 1; return app == .zoom ? zoomPid : pid }
    func alive(_ p: Int32) -> Bool { p != 0 && (p == pid || p == zoomPid) }
    func application(_ p: Int32) -> AnyObject { FakeApp(p) }
    func enable(_ app: AnyObject, full: Bool) { enables += 1 }
    func windows(_ app: AnyObject) throws -> [AnyObject] {
        let list = (app as? FakeApp)?.pid == zoomPid && zoomPid != 0 ? zoomWindows : teamsWindows
        return list.filter { !$0.gone }
    }
    func node(_ e: AnyObject) throws -> (MeetingAttrs, [AnyObject]) {
        if busy.contains(where: { $0 === e }) { throw MeetingAXError.busy }
        let x = try fake(e)
        return (x.attrs, x.children.filter { !$0.gone })
    }
    func read(_ e: AnyObject) throws -> MeetingAttrs { try fake(e).attrs }
    func actions(_ e: AnyObject) -> [String] { (try? fake(e))?.actions ?? [] }
    func perform(_ e: AnyObject, _ action: String) throws {
        if busy.contains(where: { $0 === e }) { throw MeetingAXError.busy }
        let x = try fake(e)
        guard x.actions.contains(action) else { throw MeetingAXError.failed(-25206) }
        performed.append("\(action) “\(x.attrs.label)”")
        x.onAction?(action)
    }
    func closeButton(_ window: AnyObject) -> AnyObject? { (try? fake(window))?.closeButton }
    func menuBar(_ app: AnyObject) -> AnyObject? {
        guard (app as? FakeApp)?.pid == zoomPid, zoomPid != 0, let m = zoomMenu, !m.gone else { return nil }
        return m
    }
    func postEscape(_ pid: Int32) -> Bool { escapes += 1; return true }
    func frontmostPID() -> Int32 { front }
    func activate(_ pid: Int32) { activated.append(pid) }
}

// MARK: - The harness

final class Harness {
    let f = FakeBackend()
    var t = Date(timeIntervalSince1970: 1_791_968_400)      // 15 Oct 2026, 09:00 UTC
    let e: MeetingEngine
    var states: [MeetingSnapshot] = []
    var popups: [MeetingPopup] = []

    init() {
        e = MeetingEngine(backend: f)
        e.now = { [unowned self] in self.t }
        e.wait = { _ in }
        e.onState = { [unowned self] in self.states.append($0) }
        e.onPopup = { [unowned self] in self.popups.append($0) }
    }

    /// Ticks for `d` seconds of fake time, honouring the waits the engine asks for.
    func run(_ d: TimeInterval) {
        let end = t.addingTimeInterval(d)
        while t < end { t = t.addingTimeInterval(e.tick()) }
    }

    var last: MeetingSnapshot { states.last ?? MeetingSnapshot() }
    var teams: MeetingAppState { last.apps[.teams] ?? MeetingAppState() }
    var zoom: MeetingAppState { last.apps[.zoom] ?? MeetingAppState() }

    /// A main window and a meeting window with the toolbar.
    @discardableResult
    func meeting(_ micLabel: String) -> (win: FakeEl, mic: FakeEl, hang: FakeEl) {
        let main = f.window("Chat | Mickey Curbishley | Microsoft Teams", f.group(f.text("Hello from chat"), f.button("", "Send")))
        let mic = f.button("microphone-button", micLabel)
        let hang = f.button("hangup-button", "Leave (⌘+Shift+H)")
        let toolbar = f.group(f.button("video-button", "Turn camera on"), mic, f.button("share-button", "Share"), hang)
        let win = f.window("Eagle Dragon crew | Microsoft Teams", f.group(f.group(toolbar), f.text("Participants")))
        f.teamsWindows = [main, win]
        return (win, mic, hang)
    }

    /// Zoom in a meeting: its Meeting menu carries "Mute audio" / "Unmute audio".
    @discardableResult
    func zoomMeeting(_ title: String) -> (item: FakeEl, win: FakeEl) {
        f.zoomPid = 5151
        let item = f.el(MeetingAttrs(role: "AXMenuItem", title: title, enabled: true))
        let meetingMenu = f.el(MeetingAttrs(role: "AXMenuBarItem", title: "Meeting"),
                               f.el(MeetingAttrs(role: "AXMenu"), f.el(MeetingAttrs(role: "AXMenuItem", title: "Fullscreen")), item))
        f.zoomMenu = f.el(MeetingAttrs(role: "AXMenuBar"), f.el(MeetingAttrs(role: "AXMenuBarItem", title: "zoom.us")), meetingMenu)
        let win = f.window("Zoom Meeting", f.group(f.button("", "Leave")))
        f.zoomWindows = [f.window("Zoom Workplace", f.text("chat with Bob")), win]
        return (item, win)
    }
}

var checks = 0
var failures = 0
func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
    checks += 1
    if !ok { failures += 1; print("FAIL", what()) }
}

// MARK: - The checks

do { // untrusted, then not running
    let h = Harness()
    h.f.isTrusted = false
    h.run(5)
    expect(!h.last.trusted && !h.teams.running && h.last.active == nil, "untrusted: \(h.last)")
    h.f.isTrusted = true
    h.f.pid = 0
    h.run(35)
    expect(h.last.trusted && !h.teams.running, "not running: \(h.last)")
}

do { // live mute state, a press, and a disabled hang-up
    let h = Harness()
    let (_, mic, hang) = h.meeting("Unmute mic (⌘+Shift+M)")
    h.run(3)
    expect(h.teams.inMeeting && h.teams.muted == true && h.teams.canLeave && h.teams.window == "Eagle Dragon crew | Microsoft Teams",
           "muted in a meeting: \(h.teams)")
    expect(h.last.active == .teams, "Teams is the active meeting")
    mic.attrs.desc = "Mute mic (⌘+Shift+M)"
    h.e.pressed()
    expect(h.teams.muted == false, "live straight after a press: \(h.teams)")
    hang.attrs.enabled = false
    h.run(1)
    expect(!h.teams.canLeave, "a disabled hang-up can't leave")
}

do { // what mic-button names say
    let p = MeetingPatterns.shipped
    let cases: [(String, Bool?)] = [
        ("Unmute mic (⌘+Shift+M)", true), ("Unmute", true), ("Mute mic", false), ("Mute (⌘+Shift+M)", false),
        ("Turn off mic", false), ("Turn mic off", false), ("Turn on microphone", true), ("Mic is off", true),
        ("Microphone muted", true), ("Mic on", false), ("Mic", nil), ("", nil), ("Mikrofon wieder aktivieren", nil),
        ("Désactiver le micro", false), ("Activer le micro", true), ("Rétablir le micro (⌘+Maj+M)", true)
    ]
    for (label, want) in cases { expect(p.muted(byLabel: label) == want, "“\(label)” reads \(String(describing: p.muted(byLabel: label)))") }
}

do { // a flyout hides the toolbar: keep the reading; the window closing ends it at once
    let h = Harness()
    let (win, mic, hang) = h.meeting("Mute mic")
    h.run(2)
    expect(h.teams.inMeeting, "in a meeting")
    mic.gone = true; hang.gone = true
    h.run(10)
    expect(h.teams.inMeeting && h.teams.muted == false, "a flyout keeps the last state: \(h.teams)")
    mic.gone = false; hang.gone = false
    h.run(3)
    expect(h.teams.inMeeting, "toolbar back")
    win.gone = true
    h.run(3)
    expect(!h.teams.inMeeting, "meeting window closed: over")
}

do { // Rejoin on screen ends the meeting at once
    let h = Harness()
    let (win, mic, hang) = h.meeting("Mute mic")
    h.run(2)
    mic.gone = true; hang.gone = true
    win.add([h.f.button("", "Rejoin")])
    h.run(3)
    expect(!h.teams.inMeeting, "Rejoin ends the meeting")
}

do { // the survey in the post-call window is dismissed, and focus handed back
    let h = Harness()
    let (win, mic, hang) = h.meeting("Mute mic")
    h.run(2)
    mic.gone = true; hang.gone = true
    let f = h.f
    let dismiss = f.button("", "Dismiss")
    let survey = f.dialog(f.text("How was the call quality?"), f.button("", "Thumbs up"), f.button("", "Thumbs down"),
                          f.el(MeetingAttrs(role: "AXCheckBox", desc: "Audio")), f.button("", "Submit"), dismiss)
    dismiss.onAction = { _ in survey.gone = true }
    win.add([f.button("", "Rejoin"), survey])
    h.e.left(nil)
    h.run(5)
    expect(f.performed == ["AXPress “Dismiss”"], "one Dismiss press: \(f.performed)")
    expect(f.activated == [777], "focus handed back: \(f.activated)")
    expect(h.popups.first.map { $0.matched && $0.action == "pressed “Dismiss”" } ?? false, "popup reported: \(h.popups)")
}

do { // never Submit or Thumbs; Escape as the last resort; the main window never closed
    let h = Harness()
    let f = h.f
    let main = f.window("Calendar | Calendar | Microsoft Teams")
    let survey = f.dialog(f.text("Rate your call"), f.button("", "Thumbs up"), f.button("", "Submit"), f.button("", "Close and submit"))
    main.add([f.group(survey)])
    f.teamsWindows = [main]
    h.e.left(nil)
    h.run(6)
    expect(!f.performed.contains { $0.lowercased().contains("submit") || $0.contains("Thumbs") }, "pressed a forbidden button: \(f.performed)")
    expect(f.escapes > 0, "Escape as the last resort")
    expect(!main.gone, "main window never closed")
}

do { // a survey in a window of its own is closed with its close button
    let h = Harness()
    let f = h.f
    let pop = f.window("", f.text("How likely are you to recommend Microsoft Teams to a friend or colleague?"), f.button("", "0"), f.button("", "10"))
    pop.closeButton?.onAction = { _ in pop.gone = true }
    f.teamsWindows = [f.window("Activity | Microsoft Teams"), pop]
    h.e.left(nil)
    h.run(4)
    expect(pop.gone, "survey window closed: \(f.performed)")
}

do { // an unknown popup is reported once and left alone
    let h = Harness()
    let f = h.f
    let main = f.window("Chat | Bob | Microsoft Teams")
    main.add([f.dialog(f.text("Recording saved to OneDrive"), f.button("", "OK"))])
    f.teamsWindows = [main]
    h.e.left(nil)
    h.run(10)
    expect(f.performed.isEmpty && f.escapes == 0, "unknown popup left alone: \(f.performed) esc \(f.escapes)")
    expect(h.popups.filter { !$0.matched }.count == 1, "one unrecognised-popup report: \(h.popups)")
}

do { // a live meeting window is never touched, even in a survey watch
    let h = Harness()
    let (win, _, _) = h.meeting("Mute mic")
    win.add([h.f.dialog(h.f.text("How was the call quality?"), h.f.button("", "Dismiss"))])
    h.run(2)
    h.e.startSurveyWatch(h.e.tracker(.teams), h.t)
    h.run(5)
    expect(h.f.performed.isEmpty, "touched a live meeting window: \(h.f.performed)")
}

do { // closing surveys switched off
    let h = Harness()
    h.e.dismissSurveys = false
    let f = h.f
    f.teamsWindows = [f.window("Chat | Bob | Microsoft Teams", f.dialog(f.text("How was the call quality?"), f.button("", "Dismiss")))]
    h.e.left(nil)
    h.run(5)
    expect(f.performed.isEmpty, "dismissed with the setting off: \(f.performed)")
}

do { // Inspect and Capture say what's there, and never what's in a chat
    let h = Harness()
    h.meeting("Unmute mic")
    h.run(2)
    let out = h.e.inspect()
    for want in ["#microphone-button", "“Unmute mic”", "#hangup-button", "[meeting]", "[main]", "muted: yes"] {
        expect(out.contains(want), "inspect lacks \(want):\n\(out)")
    }
    expect(!out.contains("Hello from chat"), "inspect shows chat")
    expect(!h.e.capture().contains("Hello from chat"), "capture shows chat")
}

do { // window titles
    let cases: [(String, MeetingWindowKind)] = [
        ("Calendar | Calendar | Microsoft Teams", .main), ("Chat | Jane Smith | Microsoft Teams", .main),
        ("Activity | Microsoft Teams", .main), ("Teams and channels | General | Microsoft Teams", .main),
        ("OneDrive | Microsoft Teams", .main), ("Microsoft Teams", .main), ("Something | Calendar | Microsoft Teams", .main),
        ("Calendar review | Microsoft Teams", .meeting), ("Teams sync – Eagle Dragon | Microsoft Teams", .meeting),
        ("Chatham House prep | Microsoft Teams", .meeting), ("Weekly LP review", .meeting),
        ("Meeting compact view | Microsoft Teams", .compact), ("", .empty), ("   ", .empty)
    ]
    for (title, want) in cases { expect(MeetingWindows.teamsKind(title) == want, "“\(title)” is \(MeetingWindows.teamsKind(title))") }
    expect(MeetingWindows.kind(.zoom, title: "Zoom Meeting", subrole: "AXStandardWindow") == .meeting, "Zoom Meeting")
    expect(MeetingWindows.kind(.zoom, title: "Zoom Workplace", subrole: "AXStandardWindow") == .main, "Zoom Workplace")
    expect(MeetingWindows.kind(.zoom, title: "Zoom", subrole: "AXFloatingWindow") == .other, "Zoom's feedback window")
}

do { // which window a shortcut goes to
    let pick = { (titles: [String], hint: String) in MeetingWindows.pick(.teams, titles: titles, hint: hint) }
    expect(pick(["Chat | Mickey | Microsoft Teams", "Eagle Dragon crew | Microsoft Teams", "Other meeting | Microsoft Teams"], "")
           == "Eagle Dragon crew | Microsoft Teams", "front-most meeting window")
    expect(pick(["Calendar | Calendar | Microsoft Teams", "Meeting compact view | Microsoft Teams"], "") == "Meeting compact view | Microsoft Teams", "compact view")
    expect(pick(["Calendar | Calendar | Microsoft Teams", ""], "") == nil, "nothing")
    let wins = ["Chat | Bob | Microsoft Teams", "Weekly | Microsoft Teams", "Client call | Microsoft Teams"]
    expect(pick(wins, "CLIENT") == "Client call | Microsoft Teams", "hint wins")
    expect(pick(wins, "nomatch") == "Weekly | Microsoft Teams", "a hint that matches nothing")
    expect(MeetingWindows.pick(.zoom, titles: ["Zoom Workplace", "Zoom Meeting"], hint: "") == "Zoom Meeting", "Zoom's meeting window")
}

do { // patterns that don't compile fall back; Teams Meeting Keys' file loads as it is
    var c = MeetingPatterns.shippedConfig
    c.surveyText = "("
    c.muteRules = [.init(pattern: "[", muted: true)]
    let (p, problems) = MeetingPatterns.compile(c)
    expect(problems.count == 2, "two problems: \(problems)")
    expect(MeetingPatterns.matches(p.survey, "call quality") && p.muted(byLabel: "Unmute") != nil, "defaults after bad patterns")

    let file = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Checks/meeting/teams-ui.json")
    let loaded = MeetingPatterns.load(file)
    expect(loaded.problems.isEmpty, "teams-ui.json: \(loaded.problems)")
    expect(loaded.patterns.muted(byLabel: "Unmute mic") == true && loaded.patterns.muted(byLabel: "Mute mic") == false, "teams-ui.json's rules")
    let bad = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-ui-bad.json")
    try? Data("{ not json".utf8).write(to: bad)
    expect(MeetingPatterns.load(bad).problems.count == 1, "a file that isn't JSON is named")
    expect(MeetingPatterns.load(URL(fileURLWithPath: "/nonexistent/meeting-ui.json")).problems.isEmpty, "no file: the defaults")
}

do { // a popup that won't close: one press, one Escape, then quiet
    let h = Harness()
    let f = h.f
    let main = f.window("Chat | Bob | Microsoft Teams")
    main.add([f.dialog(f.text("How was the call quality?"), f.button("", "Dismiss"))])
    f.teamsWindows = [main]
    h.e.left(nil)
    h.run(60)
    expect(f.performed.count == 1 && f.escapes == 1, "one press and one Escape: \(f.performed) esc \(f.escapes)")
    expect(h.popups.count == 2, "two popup reports: \(h.popups)")
}

do { // Zoom's mute state, from its Meeting menu
    let h = Harness()
    h.f.pid = 0
    let (item, _) = h.zoomMeeting("Unmute audio")
    h.run(3)
    expect(h.last.active == .zoom && h.zoom.inMeeting && h.zoom.muted == true && h.zoom.window == "Zoom Meeting", "zoom: \(h.last)")
    item.attrs.title = "Mute audio"
    h.run(1)
    expect(h.zoom.muted == false, "zoom live: \(h.zoom)")
    item.gone = true
    h.run(3)
    expect(!h.zoom.inMeeting && h.last.active == nil, "zoom meeting over: \(h.last)")
}

do { // the keys act on the most recently joined meeting
    let h = Harness()
    h.meeting("Unmute mic")
    h.run(3)
    expect(h.last.active == .teams, "Teams active")
    h.zoomMeeting("Mute audio")
    h.run(6)
    expect(h.last.active == .zoom && h.teams.inMeeting && h.zoom.inMeeting, "Zoom active, both in meetings: \(h.last)")
}

do { // pressing Teams' own mute button
    let h = Harness()
    let (_, mic, _) = h.meeting("Unmute mic")
    h.run(2)
    mic.onAction = { _ in mic.attrs.desc = "Mute mic" }
    let r = h.e.press(.mute)
    expect(r.ok && r.app == .teams, "press: \(r)")
    expect(h.f.activated == [777], "focus handed back: \(h.f.activated)")
    expect(h.teams.muted == false, "state updated: \(h.teams)")
}

do { // a press with no effect asks for the shortcut
    let h = Harness()
    h.meeting("Unmute mic")
    h.run(2)
    let r = h.e.press(.mute)
    expect(!r.ok && r.delivered && r.error == "no effect seen yet", "delivered but unconfirmed: \(r)")
}

do { // pressing Teams' leave ends the meeting and watches for the survey
    let h = Harness()
    let (win, _, hang) = h.meeting("Mute mic")
    h.run(2)
    hang.onAction = { _ in win.children.forEach { $0.gone = true } }
    let r = h.e.press(.leave)
    expect(r.ok, "leave: \(r)")
    expect(!h.teams.inMeeting, "out of the meeting")
    expect(h.t < h.e.tracker(.teams).surveyUntil, "survey watch started")
}

do { // Zoom: mute through its menu; leave through the shortcut
    let h = Harness()
    h.f.pid = 0
    let (item, _) = h.zoomMeeting("Mute audio")
    h.run(3)
    item.onAction = { _ in item.attrs.title = "Unmute audio" }
    let r = h.e.press(.mute)
    expect(r.ok && r.app == .zoom, "zoom mute: \(r)")
    let l = h.e.press(.leave)
    expect(!l.ok && l.error == "use the shortcut", "zoom leave: \(l)")
}

do { // Zoom's "Leave meeting?": confirmed for an attendee, left to the host
    for host in [false, true] {
        let h = Harness()
        h.f.pid = 0
        let (_, win) = h.zoomMeeting("Mute audio")
        h.run(3)
        let f = h.f
        let pop = f.el(MeetingAttrs(role: "AXPopover"), f.button("", "Leave meeting"))
        if host { pop.add([f.button("", "End meeting for all")]) }
        win.add([pop, f.button("", "Leave meeting")])     // a toolbar button of the same name must not be pressed
        h.e.left(.zoom)
        h.run(2)
        let pressed = f.performed.filter { $0 == "AXPress “Leave meeting”" }.count
        expect(pressed == (host ? 0 : 1), "\(host ? "host" : "attendee"): \(f.performed)")
    }
}

do { // Zoom's feedback window is closed; its main window never is
    let h = Harness()
    h.f.pid = 0
    let (item, _) = h.zoomMeeting("Mute audio")
    h.run(3)
    let f = h.f
    item.gone = true
    let feedback = f.window("Zoom", f.text("How was the audio and video?"), f.button("", "Thumbs up"), f.button("", "Thumbs down"))
    feedback.attrs.subrole = "AXFloatingWindow"
    feedback.closeButton?.onAction = { _ in feedback.gone = true }
    f.zoomWindows.append(feedback)
    h.run(5)
    expect(feedback.gone, "feedback window closed: \(f.performed)")
    expect(!f.zoomWindows[0].gone, "Zoom's main window left alone")
}

do { // what counts as delivered
    let h = Harness()
    let none = h.e.press(.mute)
    expect(!none.delivered && none.error == "no meeting", "no meeting: \(none)")
    let (_, mic, _) = h.meeting("Unmute mic")
    h.run(2)
    h.f.busy = [mic]
    let r = h.e.press(.mute)
    expect(!r.ok && r.delivered, "a timed-out press may still land: \(r)")
}

do { // Zoom with "Join audio": in a meeting, mute unknown, never pressed
    let h = Harness()
    h.f.pid = 0
    h.zoomMeeting("Join audio")
    h.run(3)
    expect(h.zoom.inMeeting && h.last.active == .zoom && h.zoom.muted == nil, "join audio: \(h.zoom)")
    expect(!h.e.press(.mute).delivered, "Join audio is never pressed")
}

do { // a live window that never said the call ended is never closed
    let h = Harness()
    let (win, mic, hang) = h.meeting("Mute mic")
    h.run(2)
    let f = h.f
    mic.gone = true; hang.gone = true
    win.add([f.button("", "Thumbs up"), f.text("call quality looks fine"), f.button("", "Close")])
    h.run(40)
    expect(!h.teams.inMeeting, "the (false) end is seen")
    expect(f.performed.isEmpty && f.escapes == 0 && !win.gone, "touched a window that never said the call ended: \(f.performed)")
}

do { // a big window isn't a survey
    let h = Harness()
    let f = h.f
    let chat = f.window("")
    chat.add((0..<80).map { f.text("message \($0)") } + [f.text("how was the call quality yesterday?"), f.button("", "Close")])
    f.teamsWindows = [f.window("Chat | Bob | Microsoft Teams"), chat]
    h.e.left(nil)
    h.run(6)
    expect(f.performed.isEmpty && !chat.gone, "a big window treated as a survey: \(f.performed)")
}

do { // a walk stops at the first element that doesn't answer
    let f = FakeBackend()
    let kids = (0..<50).map { f.button("", "b\($0)") }
    let root = f.window("W")
    root.add(kids)
    f.busy = [kids[0]]
    let (_, read, truncated) = MeetingNode.walk(f, root, maxNodes: 1000)
    expect(truncated && read <= 3, "walk stops when busy: read \(read)")
}

do { // the process list isn't asked every tick
    let h = Harness()
    h.f.pid = 0
    h.zoomMeeting("Mute audio")
    h.f.zoomPid = 0
    h.run(20)
    expect(h.f.finds <= 12, "findApp \(h.f.finds) times in 20 s")
}

do { // bundle IDs
    expect(MeetingApp(bundleID: "com.microsoft.teams2") == .teams && MeetingApp(bundleID: "us.zoom.xos") == .zoom
           && MeetingApp(bundleID: "com.google.Chrome") == nil, "bundle IDs")
}

if failures > 0 {
    print("meeting engine: \(failures) of \(checks) checks failed")
    exit(1)
}
print("meeting engine: \(checks) checks passed")
