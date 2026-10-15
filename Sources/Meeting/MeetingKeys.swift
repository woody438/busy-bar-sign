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
 * The patterns it reads Teams' labels and surveys with can be changed in
 * ~/Library/Application Support/Busy Bar Sign/meeting-ui.json (Teams
 * Meeting Keys' teams-ui.json works as it is).
 */

/// How a key press went, for the key and the settings.
struct MeetingPressReport: Equatable {
    var ok: Bool
    var message: String
    var at = Date()
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
    private var started = false
    private var misses: [MeetingApp: Int] = [:]

    /// Called on the queue.
    var onState: (MeetingSnapshot) -> Void = { _ in }
    var onPopup: (MeetingPopup) -> Void = { _ in }

    init(patterns: MeetingPatterns, dismissSurveys: Bool) {
        engine = MeetingEngine(backend: backend, patterns: patterns)
        engine.dismissSurveys = dismissSurveys
        engine.log = { NSLog("Busy Bar Sign meeting keys: %@", $0) }
    }

    func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            self.engine.onState = { [unowned self] in self.onState($0) }
            self.engine.onPopup = { [unowned self] in self.onPopup($0) }
            self.loop()
        }
    }

    private func loop() {
        let wait = engine.tick()
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.loop() }
    }

    func configure(patterns: MeetingPatterns? = nil, dismissSurveys: Bool? = nil) {
        queue.async {
            if let patterns { self.engine.patterns = patterns }
            if let dismissSurveys { self.engine.dismissSurveys = dismissSurveys }
        }
    }

    func press(_ what: MeetingControl, then done: @escaping (MeetingPressReport) -> Void) {
        queue.async { done(self.run(what)) }
    }

    func inspect(then done: @escaping (String) -> Void) { queue.async { done(self.engine.inspect()) } }
    func capture(then done: @escaping (String) -> Void) { queue.async { done(self.engine.capture()) } }

    private func report(_ ok: Bool, _ message: String) -> MeetingPressReport {
        engine.log("\(ok ? "" : "not done: ")\(message)")
        return MeetingPressReport(ok: ok, message: message)
    }

    private func run(_ what: MeetingControl) -> MeetingPressReport {
        guard backend.trusted() else {
            return report(false, "Busy Bar Sign isn't allowed to use Accessibility: System Settings ▸ Privacy & Security ▸ Accessibility.")
        }
        let snap = engine.snapshot()
        let app = snap.active
        let before = snap.current?.muted

        // 1. the meeting's own button
        if let app, misses[app, default: 0] < 2 {
            let r = engine.press(what)
            if r.ok || (r.delivered && effectSeen(what, app, before, within: 2.5)) {
                misses[app] = 0
                return report(true, "Pressed \(app.label)'s own \(what.rawValue) button.")
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
            if what == .leave {
                engine.left(to)
            } else if let before, !effectSeen(.mute, to, before, within: 1.5) {
                return report(false, "Sent \(to.label)'s shortcut to “\(window)”, but its mute didn't change. Is that the meeting?")
            }
            return report(true, "Sent \(to.label)'s shortcut to “\(window)”.")
        }
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
            case .leave: if !s.inMeeting { return true }
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

    private let worker: MeetingWorker

    /// Where the patterns can be changed without a new build.
    static var patternsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Busy Bar Sign", isDirectory: true)
            .appendingPathComponent("meeting-ui.json")
    }

    init() {
        let close = UserDefaults.standard.object(forKey: "closeSurveys") as? Bool ?? true
        closeSurveys = close
        let loaded = MeetingPatterns.load(Self.patternsFile)
        worker = MeetingWorker(patterns: loaded.patterns, dismissSurveys: close)
        problems = loaded.problems
        worker.onState = { [weak self] s in
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.snapshot != s { self?.snapshot = s } } }
        }
        worker.onPopup = { [weak self] p in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lastPopup = MeetingPopupReport(popup: p) } }
        }
    }

    func start() { worker.start() }

    /// Presses mute or leave in the meeting the keys act on.
    func press(_ what: MeetingControl, then done: @escaping (MeetingPressReport) -> Void = { _ in }) {
        worker.press(what) { [weak self] r in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.lastPress = r
                    done(r)
                }
            }
        }
    }

    /// The meeting apps' controls, as text, for the settings.
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
