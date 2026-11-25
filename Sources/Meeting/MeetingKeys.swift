import AppKit
import Combine

/*
 * Teams and Zoom from the Stream Deck's Mute and Leave keys, and the
 * meeting's own mute reading for the sign: MeetingEngine, run on a queue of
 * its own, and what a key press does with it (Teams Meeting Keys' runner):
 *
 *   1. press the meeting's own button through Accessibility, and check it took;
 *   2. if it can't, or the press didn't show, send the app's shortcut to the
 *      meeting window (Teams ⌘⇧M / ⌘⇧H, Zoom ⌘⇧A / ⌘W) — but never straight
 *      after a press that reached the app, until it's had 2.5 s to show it,
 *      so mute can't toggle twice. An app that ignores its own button twice
 *      gets the shortcut for the rest of the session.
 *
 * With no Teams or Zoom meeting, a FaceTime or WhatsApp call on the mic gets
 * the press instead (CallAppKeys): its own mute or end button, found by what
 * it says, and no shortcut — Teams is never brought forward for it.
 *
 * The Camera key (CameraKey) works the same way: the Teams or Zoom meeting's
 * own camera control, then its shortcut (⌘⇧O, ⌘⇧V); with neither, the
 * camera control of the call app on the mic — FaceTime, WhatsApp, Google
 * Meet in a browser — found by what it says, and no shortcut.
 *
 * The patterns it reads Teams' labels and surveys with can be changed in
 * ~/Library/Application Support/Busy Bar Sign/meeting-ui.json (Teams
 * Meeting Keys' teams-ui.json works as it is).
 *
 * Settings ▸ Call apps ▸ Read Teams and Zoom meetings switches it off: then
 * nothing at all is asked of Teams or Zoom — not their windows, not their
 * shortcuts — and the keys stay dark in their meetings.
 */

/// How a key press went, for the key and the settings.
struct MeetingPressReport: Equatable {
    var ok: Bool
    var message: String
    var at = Date()
    /// FaceTime or WhatsApp: the mute the call app showed after the press,
    /// for the answer to the key before the sign's next reading.
    var muted: Bool?
    /// The Camera key: the camera, once it was seen to change.
    var camera: Bool?
}

/// The call the Camera key acts on when there's no Teams or Zoom meeting:
/// the call app on the mic (FaceTime, WhatsApp, a browser with Google Meet).
struct CameraCall: Equatable {
    var name: String
    var bundleIDs: [String]
    /// FaceTime: its call buttons show only under the pointer.
    var hover: Bool
}

/// A popup met after a call, and when.
struct MeetingPopupReport: Equatable {
    var popup: MeetingPopup
    var at = Date()
}

/// The engine and the runner, on their queue: every Accessibility call blocks.
final class MeetingWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.woodall.BusyBarSign.meeting", qos: .userInitiated)
    private let backend = AXMeetingBackend()
    private let engine: MeetingEngine
    private let callKeys: CallAppKeys
    private let cameraKey: CameraKey
    private var started = false
    private var reading: Bool
    private var looping = false
    private var misses: [MeetingApp: Int] = [:]
    /// Where the engine notes the switches it has on in Teams, by pid (MeetingEngine.noted).
    private static let notedKey = "meetingAXSwitches"

    /// Called on the queue.
    var onState: (MeetingSnapshot) -> Void = { _ in }
    var onPopup: (MeetingPopup) -> Void = { _ in }

    init(patterns: MeetingPatterns, dismissSurveys: Bool, reading: Bool) {
        engine = MeetingEngine(backend: backend, patterns: patterns)
        callKeys = CallAppKeys(backend: backend)
        cameraKey = CameraKey(backend: backend)
        self.reading = reading
        // a press is done once the Mac's camera starts or stops: the green light's signal
        cameraKey.cameraRunning = { CameraProbe.anyCameraRunning() }
        engine.dismissSurveys = dismissSurveys
        engine.log = { NSLog("Busy Bar Sign meeting keys: %@", $0) }
        // what a copy that quit without putting back (a crash) left on in Teams
        let kept = UserDefaults.standard.dictionary(forKey: Self.notedKey) as? [String: [String]] ?? [:]
        var noted: [Int32: [MeetingAXSwitch]] = [:]
        for (pid, names) in kept {
            if let p = Int32(pid) { noted[p] = names.compactMap { MeetingAXSwitch(rawValue: $0) } }
        }
        engine.noted = noted
        engine.onNoted = { noted in
            var out: [String: [String]] = [:]
            for (pid, switches) in noted { out[String(pid)] = switches.map { $0.rawValue } }
            UserDefaults.standard.set(out, forKey: MeetingWorker.notedKey)
        }
    }

    func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            self.engine.onState = { [unowned self] in self.onState($0) }
            self.engine.onPopup = { [unowned self] in self.onPopup($0) }
            if self.reading {
                self.looping = true
                self.loop()
            } else {
                self.engine.stop()                  // says so: no meeting for the keys
            }
        }
    }

    private func loop() {
        guard reading else {
            looping = false
            return
        }
        let wait = engine.tick()
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.loop() }
    }

    func configure(patterns: MeetingPatterns? = nil, dismissSurveys: Bool? = nil, reading: Bool? = nil) {
        queue.async {
            if let patterns { self.engine.patterns = patterns }
            if let dismissSurveys { self.engine.dismissSurveys = dismissSurveys }
            if let reading, reading != self.reading {
                self.reading = reading
                if reading {
                    self.engine.resume()
                    if self.started && !self.looping {
                        self.looping = true
                        self.loop()
                    }
                } else {
                    self.engine.stop()              // puts back what it switched on in Teams
                }
            }
        }
    }

    /// The meeting apps on the mic now: one that's just taken it is looked at straight away.
    func hint(onMic apps: Set<MeetingApp>) {
        queue.async { self.engine.hint(onMic: apps) }
    }

    /// Before the app quits: puts back what was switched on in Teams, waiting
    /// for the queue at most two seconds.
    func shutdown() {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.engine.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    /// `call`: the FaceTime or WhatsApp call on the mic, pressed when there's no Teams or Zoom meeting.
    func press(_ what: MeetingControl, call: LabelledCallApp?, then done: @escaping (MeetingPressReport) -> Void) {
        queue.async { done(self.run(what, call: call)) }
    }

    func inspect(then done: @escaping (String) -> Void) {
        queue.async {
            var text = self.engine.inspect()
            if self.backend.trusted() {
                for app in LabelledCallApp.allCases { text += self.callKeys.report(app, pid: Self.pid(of: app)) }
                // what the Camera key would press in each
                let snap = self.engine.snapshot()
                for app in MeetingApp.allCases where self.reading && snap.apps[app]?.inMeeting == true {
                    text += self.cameraKey.report(.meeting(app, window: snap.apps[app]?.window ?? ""), pid: self.backend.findApp(app))
                }
                for app in LabelledCallApp.allCases {
                    text += self.cameraKey.report(.app(name: app.label, hover: app.hoverControls), pid: Self.pid(of: app))
                }
            }
            done(text)
        }
    }

    /// The Camera key: the camera in the Teams or Zoom meeting, else in `call`, the call app on the mic.
    func pressCamera(call: CameraCall?, then done: @escaping (MeetingPressReport) -> Void) {
        queue.async { done(self.runCamera(call: call)) }
    }
    func capture(then done: @escaping (String) -> Void) { queue.async { done(self.engine.capture()) } }

    private func report(_ ok: Bool, _ message: String) -> MeetingPressReport {
        engine.log("\(ok ? "" : "not done: ")\(message)")
        return MeetingPressReport(ok: ok, message: message)
    }

    private func run(_ what: MeetingControl, call: LabelledCallApp?) -> MeetingPressReport {
        guard backend.trusted() else {
            return report(false, "Busy Bar Sign isn't allowed to use Accessibility: System Settings ▸ Privacy & Security ▸ Accessibility.")
        }
        let snap = engine.snapshot()
        let app = snap.active
        let before = snap.current?.muted

        // FaceTime or WhatsApp on the mic, and no Teams or Zoom meeting: its own buttons, no shortcut
        if app == nil, let call {
            let pid = Self.pid(of: call)
            guard pid != 0 else { return report(false, "\(call.label) isn't running, so there's nothing to press.") }
            let r = callKeys.press(what, in: call, pid: pid)
            var out = report(r.ok, r.message)
            out.muted = r.muted
            return out
        }

        // Teams and Zoom aren't read: nothing's asked of them, not even their shortcut
        guard reading else {
            return report(false, "Busy Bar Sign isn't reading Teams or Zoom meetings: Settings ▸ Call apps ▸ Read Teams and Zoom meetings.")
        }

        // 1. the meeting's own button
        if let app, misses[app, default: 0] < 2 {
            let r = engine.press(what)
            if r.ok || (r.delivered && effectSeen(what, app, before, within: 2.5)) {
                misses[app] = 0
                return report(true, "Pressed \(app.label)'s own \(what == .mute ? "mute" : "leave") button.")
            }
            if r.delivered {
                misses[app, default: 0] += 1
                if misses[app] == 2 { engine.log("\(app.label) ignored its own button twice; using its shortcut from now on") }
            }
            engine.log("\(what.rawValue): the button didn't do it (\(r.error)); sending the shortcut")
        }

        // 2. the keyboard shortcut, to the meeting window
        var to = app ?? .teams
        let hint = snap.apps[to]?.window ?? ""
        var result = backend.sendShortcut(what, to: to, hint: hint)
        if case .failure(let f) = result, app == nil, f.noMeetingThere {
            let zoom = backend.sendShortcut(what, to: .zoom, hint: "")
            if case .failure(.notRunning(_)) = zoom {} else { result = zoom; to = .zoom }
        }
        switch result {
        case .failure(let f):
            return report(false, f.message)
        case .success(let window):
            if what != .mute {
                engine.left(to, endForAll: what == .end)
                if what == .end && to == .zoom {
                    return report(true, "Sent Zoom's shortcut to “\(window)”; ending it for everyone if you're the host.")
                }
            } else if let before, !effectSeen(.mute, to, before, within: 1.5) {
                return report(false, "Sent \(to.label)'s shortcut to “\(window)”, but its mute didn't change. Is that the meeting?")
            }
            return report(true, "Sent \(to.label)'s shortcut to “\(window)”.")
        }
    }

    private func runCamera(call: CameraCall?) -> MeetingPressReport {
        guard backend.trusted() else {
            return report(false, "Busy Bar Sign isn't allowed to use Accessibility: System Settings ▸ Privacy & Security ▸ Accessibility.")
        }
        let snap = engine.snapshot()

        // a Teams or Zoom meeting: its own camera control, then its shortcut
        if let app = snap.active {
            guard reading else {
                return report(false, "Busy Bar Sign isn't reading Teams or Zoom meetings: Settings ▸ Call apps ▸ Read Teams and Zoom meetings.")
            }
            let hint = snap.apps[app]?.window ?? ""
            let pid = backend.findApp(app)
            var tried = ""
            if pid != 0 {
                let r = cameraKey.press(.meeting(app, window: hint), pid: pid)
                if r.ok {
                    var out = report(true, r.message)
                    out.camera = r.camera
                    return out
                }
                tried = r.message + " "
                engine.log("camera: \(r.message) Sending the shortcut.")
            }
            // a press that reached the app has had its 2.5 s to show: the shortcut can't toggle it twice
            let was = CameraProbe.anyCameraRunning()
            switch backend.sendCameraShortcut(to: app, hint: hint) {
            case .failure(let f):
                return report(false, tried + f.message)
            case .success(let window):
                let end = Date().addingTimeInterval(2)
                while Date() < end {
                    if CameraProbe.anyCameraRunning() != was {
                        var out = report(true, "Sent \(app.label)'s camera shortcut to “\(window)”: camera \(was ? "off" : "on").")
                        out.camera = !was
                        return out
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                return report(false, "Sent \(app.label)'s camera shortcut to “\(window)”, but the camera didn't change.")
            }
        }

        // FaceTime, WhatsApp or another call app on the mic: its own camera control, no shortcut
        guard let call else { return report(false, "No call on the Mac to turn the camera on or off in.") }
        let pid = Self.pid(bundleIDs: call.bundleIDs)
        guard pid != 0 else { return report(false, "\(call.name) isn't running, so there's nothing to press.") }
        let r = cameraKey.press(.app(name: call.name, hover: call.hover), pid: pid)
        var out = report(r.ok, r.message)
        out.camera = r.camera
        return out
    }

    /// The process running the first of these apps, or 0.
    private static func pid(bundleIDs: [String]) -> Int32 {
        for id in bundleIDs {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) {
                return running.processIdentifier
            }
        }
        return 0
    }

    /// The process showing a FaceTime or WhatsApp call, or 0.
    private static func pid(of app: LabelledCallApp) -> Int32 {
        for id in app.appBundleIDs {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) {
                return running.processIdentifier
            }
        }
        return 0
    }

    /// Whether a press shows within `within` seconds: mute flips; leave ends the meeting.
    private func effectSeen(_ what: MeetingControl, _ app: MeetingApp, _ before: Bool?, within: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(within)
        engine.pressed()                            // read again now, and find a rebuilt button straight away
        while true {
            engine.tick()
            let s = engine.snapshot().apps[app] ?? MeetingAppState()
            switch what {
            case .mute: if s.inMeeting, let now = s.muted, let before, now != before { return true }
            case .leave, .end: if !s.inMeeting { return true }
            }
            if Date() >= end { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

@MainActor
final class MeetingKeys: ObservableObject {
    @Published private(set) var snapshot = MeetingSnapshot()
    @Published private(set) var lastPopup: MeetingPopupReport?
    @Published private(set) var lastPress: MeetingPressReport?
    /// What's wrong with the patterns file, if anything.
    @Published private(set) var problems: [String] = []
    @Published var closeSurveys: Bool {
        didSet {
            UserDefaults.standard.set(closeSurveys, forKey: "closeSurveys")
            worker.configure(dismissSurveys: closeSurveys)
        }
    }
    /// Whether Teams and Zoom are read at all: for the sign's muted look and
    /// the Mute and Leave keys. Off, nothing is asked of them.
    @Published var reading: Bool {
        didSet {
            UserDefaults.standard.set(reading, forKey: "readMeetings")
            worker.configure(reading: reading)
        }
    }

    private let worker: MeetingWorker
    private var micApps: Set<MeetingApp> = []

    /// Where the patterns can be changed without a new build.
    static var patternsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Busy Bar Sign", isDirectory: true)
            .appendingPathComponent("meeting-ui.json")
    }

    init() {
        let close = UserDefaults.standard.object(forKey: "closeSurveys") as? Bool ?? true
        let read = UserDefaults.standard.object(forKey: "readMeetings") as? Bool ?? true
        closeSurveys = close
        reading = read
        let loaded = MeetingPatterns.load(Self.patternsFile)
        worker = MeetingWorker(patterns: loaded.patterns, dismissSurveys: close, reading: read)
        problems = loaded.problems
        worker.onState = { [weak self] s in
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.snapshot != s { self?.snapshot = s } } }
        }
        worker.onPopup = { [weak self] p in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lastPopup = MeetingPopupReport(popup: p) } }
        }
    }

    func start() { worker.start() }

    /// Before the app quits: Teams' accessibility switches put back as they were.
    func stop() { worker.shutdown() }

    /// The meeting apps holding the mic (StatusModel, once a second and on a change).
    func onMic(_ apps: Set<MeetingApp>) {
        guard apps != micApps else { return }
        micApps = apps
        worker.hint(onMic: apps)
    }

    /// Presses mute or leave in the meeting the keys act on: the Teams or Zoom
    /// meeting, else `call`, the FaceTime or WhatsApp call on the mic.
    func press(_ what: MeetingControl, call: LabelledCallApp? = nil, then done: @escaping (MeetingPressReport) -> Void = { _ in }) {
        worker.press(what, call: call) { [weak self] r in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.lastPress = r
                    done(r)
                }
            }
        }
    }

    /// The Camera key: turns the camera on or off in the Teams or Zoom meeting,
    /// else in `call`, the call app on the mic.
    func pressCamera(call: CameraCall?, then done: @escaping (MeetingPressReport) -> Void = { _ in }) {
        worker.pressCamera(call: call) { [weak self] r in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.lastPress = r
                    done(r)
                }
            }
        }
    }

    /// The meeting apps' controls (and FaceTime's and WhatsApp's), as text, for the settings.
    func inspect(then done: @escaping (String) -> Void) {
        worker.inspect { text in DispatchQueue.main.async { done(text) } }
    }

    /// Every popup and extra window, touching nothing.
    func capture(then done: @escaping (String) -> Void) {
        worker.capture { text in DispatchQueue.main.async { done(text) } }
    }

    /// Shows the patterns file in Finder, writing out the shipped one first if there isn't one.
    func revealPatterns() {
        let url = Self.patternsFile
        if !FileManager.default.fileExists(atPath: url.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(MeetingPatterns.shippedConfig).write(to: url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Reads the patterns file again.
    func reloadPatterns() {
        let loaded = MeetingPatterns.load(Self.patternsFile)
        problems = loaded.problems
        worker.configure(patterns: loaded.patterns)
    }
}
