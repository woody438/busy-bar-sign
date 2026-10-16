import AppKit
import CoreGraphics

/*
 * The away keys — Nearby, Lunch and Back In, on the Stream Deck or in the
 * menus — and whether you're at the Mac at all: it's locked, or its screen
 * saver is on. StatusRules decides what the sign says from both.
 *
 * A key sets where you are and, a few seconds after the last press (so Back
 * In can be pressed three times first), starts the screen saver. With
 * "Require password after screen saver begins" set to Immediately, that locks
 * the Mac, and the Busy Bar Sign screen saver shows the sign on every screen.
 * Coming back — unlocking, or the screen saver ending — clears the key.
 */
@MainActor
final class Away: ObservableObject {
    @Published private(set) var state = Away.saved()
    /// The Mac is locked, or its screen saver is on: you're not at it.
    @Published private(set) var locked = false
    /// Whether a key starts the screen saver (and so locks the Mac).
    @Published var startsScreenSaver = UserDefaults.standard.object(forKey: "awayStartsScreenSaver") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(startsScreenSaver, forKey: "awayStartsScreenSaver")
            if !startsScreenSaver { cancelScreenSaver() }
        }
    }
    /// Why the screen saver didn't start, or nil.
    @Published private(set) var problem: String?

    var kind: AwayState.Kind? { state.kind }
    var until: Date? { state.until }

    /// How long after the last press the screen saver starts.
    static let screenSaverDelay: TimeInterval = 3

    private var screenLocked = false
    /// When the screen saver began, while it's on.
    private var saverSince: Date?
    private var pendingSaver: DispatchWorkItem?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard timer == nil else { return }
        let centre = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "com.apple.screensaver.didstart",
                     "com.apple.screensaver.willstop", "com.apple.screensaver.didstop"] {
            observers.append(centre.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let name = note.name.rawValue
                MainActor.assumeIsolated { self?.heard(name) }
            })
        }
        // the lock is read once a second too: a notification can go missing
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
    }

    /// A key, or its menu item: Nearby and Lunch on or off, Back In ten minutes more.
    func press(_ key: AwayState.Kind) {
        var next = state
        next.press(key, at: Date())
        set(next)
        if next.kind == nil { cancelScreenSaver() } else { scheduleScreenSaver() }
    }

    /// Back at the desk.
    func end() {
        cancelScreenSaver()
        set(AwayState())
    }

    /// "Lunch", "Back at 14:30 · 23 min", for the menus and the controls; nil when no key's on.
    func statusLine(at now: Date = Date()) -> String? {
        switch state.kind {
        case .nearby: return "Nearby"
        case .lunch: return "Lunch"
        case .backIn:
            guard let until = state.until else { return nil }
            let minutes = max(Int((until.timeIntervalSince(now) / 60).rounded(.up)), 0)
            return "Back at \(DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short)) · \(minutes) min"
        case nil: return nil
        }
    }

    private func set(_ next: AwayState) {
        guard next != state else { return }
        state = next
        UserDefaults.standard.set(next.kind?.rawValue, forKey: "awayKind")
        UserDefaults.standard.set(next.until, forKey: "awayUntil")
    }

    private static func saved() -> AwayState {
        var s = AwayState(kind: (UserDefaults.standard.string(forKey: "awayKind")).flatMap(AwayState.Kind.init(rawValue:)),
                          until: UserDefaults.standard.object(forKey: "awayUntil") as? Date)
        s.expire(at: Date())
        return s
    }

    private func heard(_ name: String) {
        switch name {
        case "com.apple.screensaver.didstart": saverSince = Date()
        case "com.apple.screensaver.willstop", "com.apple.screensaver.didstop": saverSince = nil
        default: break
        }
        check()
    }

    /// Whether you're at the Mac, and whether Back In's time is up.
    private func check() {
        let now = Date()
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        screenLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        // any input since the screen saver began has ended it, in case its "did stop" went missing
        if let since = saverSince, Self.idleSeconds() < now.timeIntervalSince(since) - 1 { saverSince = nil }
        let gone = screenLocked || saverSince != nil
        if gone != locked {
            if !gone { end() }                  // back at the Mac: the key's done its job
            locked = gone
        }
        var next = state
        next.expire(at: now)
        set(next)
    }

    /// Seconds since the last keyboard, mouse or trackpad input.
    private static func idleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return .infinity }     // kCGAnyInputEventType
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    // MARK: - The screen saver

    private func scheduleScreenSaver() {
        cancelScreenSaver()
        guard startsScreenSaver, !locked else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.startScreenSaver() }
        }
        pendingSaver = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.screenSaverDelay, execute: work)
    }

    private func cancelScreenSaver() {
        pendingSaver?.cancel()
        pendingSaver = nil
    }

    private func startScreenSaver() {
        pendingSaver = nil
        guard startsScreenSaver, state.kind != nil, !locked else { return }
        let engine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: engine, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            let message = error.map { "Couldn't start the screen saver: \($0.localizedDescription)" }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.problem = message }
            }
        }
    }
}
