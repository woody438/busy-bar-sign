import Foundation

/*
 * The Mute and Leave keys in FaceTime and WhatsApp (CallAppKeys), against a
 * scripted FaceTime and WhatsApp: which control each key presses, that it's
 * checked to have taken, that focus is handed back, and what's never pressed
 * — a chat's "Mute" for notifications, a group's "Leave", anything outside a
 * call. The trees are modelled on Apple's FaceTime guide (a Mute button and
 * an End / Leave Call button in the call window) and WhatsApp's call window;
 * the real ones are what Settings ▸ Call apps ▸ Inspect shows on a Mac.
 *
 *   swiftc Sources/Meeting/MeetingPatterns.swift Sources/Meeting/MeetingTree.swift \
 *     Sources/Meeting/MeetingEngine.swift Sources/MuteLabels.swift Sources/Meeting/CallAppKeys.swift \
 *     Checks/callkeys/main.swift -o callkeys && ./callkeys
 */

// MARK: - A scripted accessibility tree

final class El {
    var attrs: MeetingAttrs
    var children: [El] = []
    var gone = false
    var onPress: (() -> Void)?
    weak var parent: El?

    init(_ attrs: MeetingAttrs, _ kids: [El] = []) {
        self.attrs = attrs
        add(kids)
    }

    func add(_ kids: [El]) {
        for k in kids { k.parent = self }
        children += kids
    }

    var isGone: Bool {
        var p: El? = self
        while let x = p { if x.gone { return true }; p = x.parent }
        return false
    }
}

final class AppRef {
    let pid: Int32
    init(_ pid: Int32) { self.pid = pid }
}

final class Fake: MeetingBackend {
    var wins: [Int32: [El]] = [:]
    var menus: [Int32: El] = [:]
    var front: Int32 = 777                  // the app you're typing in
    var pressed: [String] = []
    var activated: [Int32] = []
    var busyOnce: El?

    func trusted() -> Bool { true }
    func findApp(_ app: MeetingApp) -> Int32 { 0 }
    func alive(_ pid: Int32) -> Bool { wins[pid] != nil }
    func application(_ pid: Int32) -> AnyObject { AppRef(pid) }
    func enable(_ app: AnyObject, full: Bool) {}
    func windows(_ app: AnyObject) throws -> [AnyObject] {
        guard let pid = (app as? AppRef)?.pid else { throw MeetingAXError.invalid }
        return (wins[pid] ?? []).filter { !$0.gone }
    }
    private func el(_ e: AnyObject) throws -> El {
        guard let x = e as? El, !x.isGone else { throw MeetingAXError.invalid }
        return x
    }
    func node(_ e: AnyObject) throws -> (MeetingAttrs, [AnyObject]) {
        let x = try el(e)
        return (x.attrs, x.children.filter { !$0.gone })
    }
    func read(_ e: AnyObject) throws -> MeetingAttrs { try el(e).attrs }
    func actions(_ e: AnyObject) -> [String] { ["AXPress"] }
    func perform(_ e: AnyObject, _ action: String) throws {
        let x = try el(e)
        pressed.append(x.attrs.label)
        x.onPress?()
        if let b = busyOnce, b === x { busyOnce = nil; throw MeetingAXError.busy }
    }
    func closeButton(_ window: AnyObject) -> AnyObject? { nil }
    func menuBar(_ app: AnyObject) -> AnyObject? {
        guard let pid = (app as? AppRef)?.pid, let m = menus[pid], !m.gone else { return nil }
        return m
    }
    func postEscape(_ pid: Int32) -> Bool { false }
    func frontmostPID() -> Int32 { front }
    func activate(_ pid: Int32) { activated.append(pid) }
}

func button(_ label: String, role: String = "AXButton") -> El { El(MeetingAttrs(role: role, desc: label)) }
func text(_ s: String) -> El { El(MeetingAttrs(role: "AXStaticText", value: s)) }
func group(_ kids: El...) -> El { El(MeetingAttrs(role: "AXGroup"), kids) }
func window(_ title: String, _ kids: El...) -> El { El(MeetingAttrs(role: "AXWindow", subrole: "AXStandardWindow", title: title), kids) }
func menuBar(_ menus: (String, [El])...) -> El {
    El(MeetingAttrs(role: "AXMenuBar"), menus.map { name, items in
        El(MeetingAttrs(role: "AXMenuBarItem", title: name), [El(MeetingAttrs(role: "AXMenu"), items)])
    })
}
func menuItem(_ title: String, ticked: Bool = false) -> El {
    El(MeetingAttrs(role: "AXMenuItem", title: title, enabled: true, mark: ticked ? "✓" : ""))
}

let facetime: Int32 = 3001
let whatsapp: Int32 = 3002

final class Harness {
    let f = Fake()
    let keys: CallAppKeys
    var t = Date(timeIntervalSince1970: 1_793_620_800)      // 2 Nov 2026

    init() {
        keys = CallAppKeys(backend: f)
        keys.now = { [unowned self] in self.t }
        keys.wait = { [unowned self] in self.t = self.t.addingTimeInterval($0) }
    }

    /// FaceTime in a call: its window's controls (a toggle "Mute" that keeps
    /// its name), and its Video menu.
    @discardableResult
    func faceTimeCall(end endLabel: String = "End", mute role: String = "AXCheckBox") -> (mic: El, end: El, controls: El, menuMute: El) {
        let mic = button("Mute", role: role)
        mic.attrs.number = 0
        mic.onPress = { mic.attrs.number = mic.attrs.number == 1 ? 0 : 1 }
        let end = button(endLabel)
        let controls = group(button("Show Sidebar"), mic, button("Camera"), button("Share Screen"), end)
        end.onPress = { controls.gone = true }
        f.wins[facetime] = [window("FaceTime", group(text("Mickey Curbishley"), text("00:42")), controls)]
        let menuMute = menuItem("Mute")
        f.menus[facetime] = menuBar(("FaceTime", [menuItem("Settings…"), menuItem("Quit FaceTime")]),
                                    ("Video", [menuItem("Camera"), menuMute, menuItem("Enter Full Screen")]))
        return (mic, end, controls, menuMute)
    }

    /// WhatsApp with a chat window — a "Mute" for notifications and a group's
    /// "Leave" among its chats — and, on a call, its call window.
    @discardableResult
    func whatsApp(call: Bool, endLabel: String = "End call") -> (chatMute: El, chatLeave: El, mic: El?, end: El?) {
        let chatMute = button("Mute")
        let chatLeave = button("Leave")
        let chats = (0..<60).map { button("Chat with Alice \($0)") }
        let list = El(MeetingAttrs(role: "AXGroup"), chats)
        let chat = window("WhatsApp", list, group(button("Voice call"), button("Video call"), chatMute, chatLeave))
        f.wins[whatsapp] = [chat]
        f.menus[whatsapp] = menuBar(("Chat", [menuItem("Mute"), menuItem("Archive")]), ("Call", [menuItem("Voice call")]))
        guard call else { return (chatMute, chatLeave, nil, nil) }
        let mic = button("Mute")
        mic.onPress = { mic.attrs.desc = mic.attrs.desc == "Mute" ? "Unmute" : "Mute" }
        let end = button(endLabel)
        let callWin = window("WhatsApp call", text("End-to-end encrypted"), text("Mickey Curbishley"),
                             group(button("Camera"), mic, button("Speaker"), end))
        end.onPress = { callWin.gone = true }
        f.wins[whatsapp] = [chat, callWin]
        return (chatMute, chatLeave, mic as El?, end as El?)
    }
}

var checks = 0
var failures = 0
func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
    checks += 1
    if !ok { failures += 1; print("FAIL", what()) }
}

// MARK: - FaceTime

do { // Mute: the call window's toggle, checked to have flipped, your app given back
    let h = Harness()
    let call = h.faceTimeCall()
    let r = h.keys.press(.mute, in: .facetime, pid: facetime)
    expect(r.ok && r.muted == true && call.mic.attrs.number == 1, "FaceTime mute: \(r)")
    expect(h.f.pressed == ["Mute"], "pressed only the call's Mute: \(h.f.pressed)")
    expect(h.f.activated == [777], "your app given back: \(h.f.activated)")
    let back = h.keys.press(.mute, in: .facetime, pid: facetime)
    expect(back.ok && back.muted == false && call.mic.attrs.number == 0, "and unmuted again: \(back)")
}

do { // Leave: its End button, checked to have gone; a held key (end) just leaves too
    for what in [MeetingControl.leave, .end] {
        let h = Harness()
        let call = h.faceTimeCall()
        let r = h.keys.press(what, in: .facetime, pid: facetime)
        expect(r.ok && call.controls.gone && h.f.pressed == ["End"], "FaceTime \(what): \(r), pressed \(h.f.pressed)")
        expect(r.message.contains("left the call"), "says it left: \(r.message)")
    }
}

do { // a Group FaceTime's "Leave Call", and a bare "Leave"
    for label in ["Leave Call", "Leave"] {
        let h = Harness()
        let call = h.faceTimeCall(end: label)
        let r = h.keys.press(.leave, in: .facetime, pid: facetime)
        expect(r.ok && call.controls.gone && h.f.pressed == [label], "FaceTime “\(label)”: \(r)")
    }
}

do { // the controls hidden: mute through the Video menu's ticked "Mute"; leave has nothing to press
    let h = Harness()
    let call = h.faceTimeCall()
    call.controls.gone = true
    call.menuMute.onPress = { call.menuMute.attrs.mark = call.menuMute.attrs.mark.isEmpty ? "✓" : "" }
    let r = h.keys.press(.mute, in: .facetime, pid: facetime)
    expect(r.ok && r.muted == true && h.f.pressed == ["Mute"] && !call.menuMute.attrs.mark.isEmpty, "menu mute: \(r)")
    expect(r.message.contains("menu bar"), "says it was the menu bar's: \(r.message)")
    h.f.pressed = []
    let leave = h.keys.press(.leave, in: .facetime, pid: facetime)
    expect(!leave.ok && !leave.delivered && h.f.pressed.isEmpty && leave.message.contains("Inspect"), "nothing to leave with: \(leave)")
}

do { // the menu's "End Call", when the window's controls are hidden
    let h = Harness()
    let call = h.faceTimeCall()
    call.controls.gone = true
    let endItem = menuItem("End Call")
    endItem.onPress = { endItem.gone = true }
    h.f.menus[facetime] = menuBar(("Video", [menuItem("Mute"), endItem]))
    let r = h.keys.press(.leave, in: .facetime, pid: facetime)
    expect(r.ok && h.f.pressed == ["End Call"], "menu End Call: \(r)")
}

do { // a "Mute" that never shows a change: pressed, but not claimed
    let h = Harness()
    let call = h.faceTimeCall(mute: "AXButton")
    call.mic.onPress = {}
    call.mic.attrs.number = nil
    let r = h.keys.press(.mute, in: .facetime, pid: facetime)
    expect(!r.ok && r.delivered && r.muted == nil && r.message.contains("didn't change"), "no change seen: \(r)")
    expect(h.f.pressed == ["Mute"], "pressed once, not again: \(h.f.pressed)")
}

do { // an End that doesn't end it: not claimed
    let h = Harness()
    let call = h.faceTimeCall()
    call.end.onPress = {}
    let r = h.keys.press(.leave, in: .facetime, pid: facetime)
    expect(!r.ok && r.delivered && r.message.contains("still shows"), "call still there: \(r)")
    expect(h.f.pressed == ["End"], "pressed once: \(h.f.pressed)")
}

do { // the app slow to answer the press: it may still land, and is checked
    let h = Harness()
    let call = h.faceTimeCall()
    h.f.busyOnce = call.mic
    let r = h.keys.press(.mute, in: .facetime, pid: facetime)
    expect(r.ok && r.delivered && r.muted == true, "a busy press that landed: \(r)")
}

do { // FaceTime in front already: nothing to hand back
    let h = Harness()
    h.faceTimeCall()
    h.f.front = facetime
    _ = h.keys.press(.mute, in: .facetime, pid: facetime)
    expect(h.f.activated.isEmpty, "no focus juggling when FaceTime was in front: \(h.f.activated)")
}

do { // FaceTime's window with no call (a list of recents): nothing pressed
    let h = Harness()
    h.f.wins[facetime] = [window("FaceTime", group(button("New FaceTime"), button("Create Link"), button("Mickey Curbishley")))]
    h.f.menus[facetime] = menuBar(("Video", [menuItem("Camera")]))
    for what in [MeetingControl.mute, .leave] {
        let r = h.keys.press(what, in: .facetime, pid: facetime)
        expect(!r.ok && !r.delivered, "no call, \(what): \(r)")
    }
    expect(h.f.pressed.isEmpty, "pressed nothing: \(h.f.pressed)")
}

do { // a lone "End" away from any mic control is never pressed
    let h = Harness()
    h.f.wins[facetime] = [window("FaceTime", group(button("End"), button("Camera")))]
    let r = h.keys.press(.leave, in: .facetime, pid: facetime)
    expect(!r.delivered && h.f.pressed.isEmpty, "lone End pressed: \(h.f.pressed)")
}

// MARK: - WhatsApp

do { // Mute and Leave: the call window's, never the chat's "Mute" or a group's "Leave"
    let h = Harness()
    let w = h.whatsApp(call: true)
    let r = h.keys.press(.mute, in: .whatsapp, pid: whatsapp)
    expect(r.ok && r.muted == true && w.mic?.attrs.desc == "Unmute", "WhatsApp mute: \(r)")
    expect(h.f.pressed == ["Mute"] && w.chatMute.attrs.desc == "Mute", "pressed the call's Mute only: \(h.f.pressed)")
    let unmute = h.keys.press(.mute, in: .whatsapp, pid: whatsapp)
    expect(unmute.ok && unmute.muted == false, "WhatsApp unmute: \(unmute)")
    h.f.pressed = []
    let leave = h.keys.press(.leave, in: .whatsapp, pid: whatsapp)
    expect(leave.ok && h.f.pressed == ["End call"], "WhatsApp leave: \(leave), pressed \(h.f.pressed)")
}

do { // "Hang up" and "End Call" work as well
    for label in ["Hang up", "End Call"] {
        let h = Harness()
        h.whatsApp(call: true, endLabel: label)
        let r = h.keys.press(.leave, in: .whatsapp, pid: whatsapp)
        expect(r.ok && h.f.pressed == [label], "WhatsApp “\(label)”: \(r)")
    }
}

do { // WhatsApp's call window with a lone "End": not pressed (only a button named for the call)
    let h = Harness()
    h.whatsApp(call: true, endLabel: "End")
    for what in [MeetingControl.leave, .mute] {
        let r = h.keys.press(what, in: .whatsapp, pid: whatsapp)
        expect(!r.delivered, "WhatsApp lone End, \(what): \(r)")
    }
    expect(h.f.pressed.isEmpty, "pressed nothing: \(h.f.pressed)")
}

do { // no call (a voice message holds the mic): the chat's Mute, its Leave and the menus are never pressed
    let h = Harness()
    let w = h.whatsApp(call: false)
    for what in [MeetingControl.mute, .leave, .end] {
        let r = h.keys.press(what, in: .whatsapp, pid: whatsapp)
        expect(!r.ok && !r.delivered, "no WhatsApp call, \(what): \(r)")
    }
    expect(h.f.pressed.isEmpty && w.chatMute.attrs.desc == "Mute", "pressed nothing in the chats: \(h.f.pressed)")
}

// MARK: - Which app, readings, the report

do { // what holds the mic, as an app the keys reach
    expect(LabelledCallApp(bundleID: "com.apple.FaceTime") == .facetime, "FaceTime")
    expect(LabelledCallApp(bundleID: "com.apple.avconferenced") == .facetime, "FaceTime's audio daemon")
    expect(LabelledCallApp(bundleID: "net.whatsapp.WhatsApp") == .whatsapp && LabelledCallApp(bundleID: "com.whatsapp.WhatsApp") == .whatsapp,
           "WhatsApp")
    expect(LabelledCallApp(bundleID: "com.microsoft.teams2") == nil && LabelledCallApp(bundleID: "com.google.Chrome") == nil,
           "Teams and Chrome aren't")
}

do { // a "Mute" that keeps its name reads by its state
    var a = MeetingAttrs(role: "AXCheckBox", desc: "Mute")
    a.number = 1
    expect(a.muteReading?.muted == true, "a switched-on toggle is muted")
    a.number = 0
    expect(a.muteReading?.muted == false, "a switched-off toggle is live")
    var b = MeetingAttrs(role: "AXButton", title: "Mute")
    b.selected = true
    expect(b.muteReading?.muted == true, "a selected button is muted")
    let c = MeetingAttrs(role: "AXMenuItem", title: "Mute", mark: "✓")
    expect(c.muteReading?.muted == true, "a ticked menu item is muted")
    expect(MeetingAttrs(role: "AXButton", desc: "Unmute").muteReading?.muted == true, "Unmute: muted")
}

do { // Inspect: what each key would press, touching nothing; a chat list's names stay out
    let h = Harness()
    h.whatsApp(call: true)
    let report = h.keys.report(.whatsapp, pid: whatsapp)
    expect(report.contains("Mute key presses: “Mute” in “WhatsApp call”") && report.contains("Leave key presses: “End call” in “WhatsApp call”"),
           "report:\n\(report)")
    expect(!report.contains("Alice"), "chat names in the report:\n\(report)")
    expect(h.f.pressed.isEmpty, "the report pressed something: \(h.f.pressed)")
    expect(h.keys.report(.facetime, pid: 0).contains("not running"), "not running")
    h.faceTimeCall()
    let ft = h.keys.report(.facetime, pid: facetime)
    expect(ft.contains("Mute key presses: “Mute” in “FaceTime” (mic live)") && ft.contains("Leave key presses: “End” in “FaceTime”"),
           "FaceTime report:\n\(ft)")
}

if failures > 0 {
    print("call keys: \(failures) of \(checks) checks failed")
    exit(1)
}
print("call keys (FaceTime, WhatsApp): \(checks) checks passed")
