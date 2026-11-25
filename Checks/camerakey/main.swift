import Foundation

/*
 * The Camera key (CameraKey), against scripted Teams, Zoom, FaceTime,
 * WhatsApp and Google Meet: which control it presses in each, that it's
 * checked to have taken (the camera starting or stopping, or the control's
 * name flipping), that focus and the pointer are handed back, and what it
 * never presses — camera options and settings, a chat's "Start video call",
 * a camera's name in a menu. The trees are modelled on what each app's
 * camera control is called; the real ones are what Settings ▸ Call apps ▸
 * Inspect shows on a Mac.
 *
 *   swiftc Sources/Meeting/MeetingPatterns.swift Sources/Meeting/MeetingTree.swift \
 *     Sources/Meeting/MeetingEngine.swift Sources/MuteLabels.swift Sources/Meeting/CallAppKeys.swift \
 *     Sources/Meeting/CameraKey.swift Checks/camerakey/main.swift -o camerakey && ./camerakey
 */

// MARK: - A scripted accessibility tree (as Checks/callkeys')

final class El {
    var attrs: MeetingAttrs
    var children: [El] = []
    var gone = false
    var hidden = false          // left out of its parent's children till the pointer's over the window (FaceTime)
    var frame: CGRect?
    var onPress: (() -> Void)?
    weak var parent: El?

    init(_ attrs: MeetingAttrs, _ kids: [El] = []) {
        self.attrs = attrs
        for k in kids { k.parent = self }
        children = kids
    }
}

final class AppRef {
    let pid: Int32
    init(_ pid: Int32) { self.pid = pid }
}

final class Fake: MeetingBackend {
    var wins: [Int32: [El]] = [:]
    var menus: [Int32: El] = [:]
    var front: Int32 = 777
    var pressed: [String] = []
    var activated: [Int32] = []
    var cursor = CGPoint(x: 2400, y: 1300)
    var moves = 0
    var nudges = 0
    var onNudge: (() -> Void)?
    var onPointer: (() -> Void)?

    func trusted() -> Bool { true }
    func findApp(_ app: MeetingApp) -> Int32 { 0 }
    func alive(_ pid: Int32) -> Bool { wins[pid] != nil }
    func application(_ pid: Int32) -> AnyObject { AppRef(pid) }
    func enable(_ app: AnyObject, full: Bool) {}
    func axSwitch(_ app: AnyObject, _ which: MeetingAXSwitch) -> Bool? { nil }
    func setAXSwitch(_ app: AnyObject, _ which: MeetingAXSwitch, _ on: Bool) {}
    func windows(_ app: AnyObject) throws -> [AnyObject] {
        guard let pid = (app as? AppRef)?.pid else { throw MeetingAXError.invalid }
        return (wins[pid] ?? []).filter { !$0.gone }
    }
    private func el(_ e: AnyObject) throws -> El {
        guard let x = e as? El, !x.gone else { throw MeetingAXError.invalid }
        return x
    }
    func node(_ e: AnyObject) throws -> (MeetingAttrs, [AnyObject]) {
        let x = try el(e)
        return (x.attrs, x.children.filter { !$0.gone && !$0.hidden })
    }
    func read(_ e: AnyObject) throws -> MeetingAttrs { try el(e).attrs }
    func actions(_ e: AnyObject) -> [String] { ["AXPress"] }
    func perform(_ e: AnyObject, _ action: String) throws {
        let x = try el(e)
        pressed.append(x.attrs.label)
        x.onPress?()
    }
    func closeButton(_ window: AnyObject) -> AnyObject? { nil }
    func menuBar(_ app: AnyObject) -> AnyObject? {
        guard let pid = (app as? AppRef)?.pid else { return nil }
        return menus[pid]
    }
    func postEscape(_ pid: Int32) -> Bool { false }
    func frontmostPID() -> Int32 { front }
    func activate(_ pid: Int32) { activated.append(pid); front = pid }
    func frame(_ e: AnyObject) -> CGRect? { (try? el(e))?.frame }
    func nudge(_ pid: Int32, at point: CGPoint) { nudges += 1; onNudge?() }
    func pointer() -> CGPoint? { cursor }
    func movePointer(to point: CGPoint) { cursor = point; moves += 1; onPointer?() }
    func bringForward(_ window: AnyObject, pid: Int32) -> Bool { front = pid; return true }
}

func button(_ label: String, role: String = "AXButton", id: String = "") -> El {
    El(MeetingAttrs(role: role, id: id, desc: label))
}
func window(_ title: String, _ kids: [El]) -> El { El(MeetingAttrs(role: "AXWindow", title: title), kids) }

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "ok  " : "FAIL") \(what)")
    if !ok { failures += 1 }
}

/// A Camera key on a fake Mac whose camera is on or off.
func key(_ fake: Fake, camera: Bool) -> (CameraKey, () -> Void) {
    var running = camera
    let k = CameraKey(backend: fake)
    k.cameraRunning = { running }
    var clock = Date(timeIntervalSince1970: 1_000_000)
    k.now = { clock }
    k.wait = { clock = clock.addingTimeInterval($0) }
    return (k, { running.toggle() })
}

// MARK: - The names

let names: [(String, CameraLabels.Reading?)] = [
    ("Turn camera off (Ctrl+Shift+O)", .on), ("Turn camera on", .off), ("Turn off camera (⌘ + e)", .on),
    ("Turn on camera (⌘ + e)", .off), ("Stop Video", .on), ("Start Video", .off), ("Camera", .toggle), ("Video", .toggle),
    ("Camera options", nil), ("Video Settings…", nil), ("Start video call", nil), ("FaceTime HD Camera", nil),
    ("Choose camera", nil), ("Background effects", nil), ("More video options", nil), ("Share screen", nil),
    ("Turn on microphone (⌘ + d)", nil), ("Mute", nil)
]
for (label, want) in names {
    let got = CameraLabels.reading(label)
    check(got == want, "“\(label)” reads as \(want.map { "\($0)" } ?? "not a camera control") (\(got.map { "\($0)" } ?? "nil"))")
}

// MARK: - Teams: its camera button by id, beside "Camera options"

do {
    let fake = Fake()
    let (k, flip) = key(fake, camera: true)
    let cam = button("Turn camera off", id: "video-button")
    cam.onPress = { cam.attrs.desc = "Turn camera on"; flip() }
    fake.wins[101] = [window("Chat | Microsoft Teams", [button("Start video call")]),
                      window("Weekly sync | Microsoft Teams", [button("Camera options"), cam,
                                                              button("Mute", id: "microphone-button"),
                                                              button("Leave", id: "hangup-button")])]
    let r = k.press(.meeting(.teams, window: "Weekly sync | Microsoft Teams"), pid: 101)
    check(r.ok && r.camera == false, "Teams: pressed, camera off (\(r.message))")
    check(fake.pressed == ["Turn camera off"], "Teams: only its camera button pressed (\(fake.pressed))")
    check(fake.activated == [777], "Teams: your app handed back")
}

// MARK: - Zoom: its Meeting menu's Stop Video, never Video Settings

do {
    let fake = Fake()
    let (k, flip) = key(fake, camera: true)
    let stop = button("Stop Video", role: "AXMenuItem")
    stop.attrs.title = "Stop Video"; stop.attrs.desc = ""
    stop.onPress = { stop.attrs.title = "Start Video"; flip() }
    let settings = button("Video Settings…", role: "AXMenuItem")
    fake.wins[102] = [window("Zoom Meeting", [])]
    fake.menus[102] = El(MeetingAttrs(role: "AXMenuBar"), [El(MeetingAttrs(role: "AXMenuBarItem", title: "Meeting"),
        [El(MeetingAttrs(role: "AXMenu"), [button("Mute Audio", role: "AXMenuItem"), stop, settings])])])
    let r = k.press(.meeting(.zoom, window: "Zoom Meeting"), pid: 102)
    check(r.ok && r.camera == false, "Zoom: pressed, camera off (\(r.message))")
    check(fake.pressed == ["Stop Video"], "Zoom: Stop Video pressed, nothing else (\(fake.pressed))")
}

// MARK: - FaceTime: its Camera button shows only under the pointer

do {
    let fake = Fake()
    let (k, flip) = key(fake, camera: true)
    let cam = El(MeetingAttrs(role: "AXCheckBox", desc: "Camera", number: 1))
    let mic = El(MeetingAttrs(role: "AXCheckBox", desc: "Microphone", number: 0))
    cam.hidden = true; mic.hidden = true
    cam.onPress = { cam.attrs.number = 0; flip() }
    let call = window("FaceTime", [cam, mic, button("End")])
    call.frame = CGRect(origin: CGPoint(x: 100, y: 100), size: CGSize(width: 800, height: 600))
    call.children.last?.hidden = true
    fake.wins[103] = [call]
    fake.menus[103] = El(MeetingAttrs(role: "AXMenuBar"), [El(MeetingAttrs(role: "AXMenuBarItem", title: "Video"),
        [El(MeetingAttrs(role: "AXMenu"), [button("FaceTime HD Camera", role: "AXMenuItem")])])])
    fake.onNudge = { for c in call.children { c.hidden = false } }
    let before = fake.cursor
    let r = k.press(.app(name: "FaceTime", hover: true), pid: 103)
    check(r.ok && r.camera == false, "FaceTime: shown by a nudge, pressed, camera off (\(r.message))")
    check(fake.pressed == ["Camera"], "FaceTime: its Camera button, never the camera's name in its menu (\(fake.pressed))")
    check(fake.nudges == 1 && fake.moves == 0 && fake.cursor.x == before.x && fake.cursor.y == before.y,
          "FaceTime: the pointer left where it was")
}

// MARK: - WhatsApp: "Turn off camera" in the call, never a chat's "Start video call"

do {
    let fake = Fake()
    let (k, flip) = key(fake, camera: true)
    let cam = button("Turn off camera")
    cam.onPress = { cam.attrs.desc = "Turn on camera"; flip() }
    fake.wins[104] = [window("WhatsApp", [button("Start video call"), button("Mute")]),
                      window("Video call", [cam, button("Mute microphone"), button("End call")])]
    let r = k.press(.app(name: "WhatsApp", hover: false), pid: 104)
    check(r.ok && r.camera == false, "WhatsApp: pressed, camera off (\(r.message))")
    check(fake.pressed == ["Turn off camera"], "WhatsApp: only the call's camera button (\(fake.pressed))")
}

// MARK: - Google Meet in Chrome: "Turn on camera (⌘ + e)", not its options

do {
    let fake = Fake()
    let (k, flip) = key(fake, camera: false)
    let cam = button("Turn on camera (⌘ + e)")
    cam.onPress = { cam.attrs.desc = "Turn off camera (⌘ + e)"; flip() }
    fake.wins[105] = [window("Meet - abc-defg-hij - Google Chrome", [
        button("Turn off microphone (⌘ + d)"), button("Video settings"), cam, button("More options"), button("Leave call")])]
    let r = k.press(.app(name: "Google Chrome", hover: false), pid: 105)
    check(r.ok && r.camera == true, "Meet: pressed, camera on (\(r.message))")
    check(fake.pressed == ["Turn on camera (⌘ + e)"], "Meet: only its camera button (\(fake.pressed))")
}

// MARK: - Nothing to press, and a press that doesn't take

do {
    let fake = Fake()
    let (k, _) = key(fake, camera: false)
    fake.wins[106] = [window("WhatsApp", [button("Start video call"), button("Camera options")])]
    let r = k.press(.app(name: "WhatsApp", hover: false), pid: 106)
    check(!r.ok && !r.delivered && fake.pressed.isEmpty, "nothing that's the camera's on/off: nothing pressed (\(r.message))")
}
do {
    let fake = Fake()
    let (k, _) = key(fake, camera: true)
    fake.wins[107] = [window("Video call", [button("Turn off camera")])]       // pressing it does nothing
    let r = k.press(.app(name: "WhatsApp", hover: false), pid: 107)
    check(!r.ok && r.delivered, "a press that doesn't change the camera: reported as not done (\(r.message))")
}

print(failures == 0 ? "\nall camera key checks passed" : "\n\(failures) camera key checks failed")
exit(failures == 0 ? 0 : 1)
