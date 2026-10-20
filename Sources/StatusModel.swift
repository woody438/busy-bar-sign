import Combine
import SwiftUI

/*
 * What the sign says, all things considered: the manual controls and the
 * microphone (CallDetector), Do Not Disturb, the away keys and whether the
 * Mac is locked or in use (Away), the calls you've said you're at in person,
 * and the calendar (CalendarSource), decided by
 * StatusRules once a second and whenever one of them changes. On a call, the call app's own mute button
 * (MuteDetector, and MeetingKeys for Teams and Zoom) turns ON A CALL into
 * its muted look. Out of the wall's hours (WallHours), with nothing going
 * on, it says the wall's dark. Every view of the bar, the menus and the
 * controls read it from here.
 */
@MainActor
final class StatusModel: ObservableObject {
    @Published private(set) var state: BarState = .free
    @Published private(set) var decision = StatusDecision(state: "free", why: "Free")
    /// The moment the bar's right-hand side is about, or nil for the clock.
    @Published private(set) var moment: BarMoment?
    /// Out of hours with nothing going on: the wall and the screen saver are black.
    @Published private(set) var wallDark = false
    /// When the wall goes dark (Settings ▸ Displays ▸ Out of hours).
    @Published var wallHours = WallHours(.standard) {
        didSet {
            wallHours.save(to: .standard)
            evaluate()
        }
    }
    /// The calendar events you've said you're at in person (In Person, or the
    /// Status key during LATE): a call there shows MEETING, and never LATE.
    @Published private(set) var inPerson: Set<String> = []
    /// What the sign says, in words, for the menus and the controls: the
    /// Nearby key's own word for .nearby.
    var stateName: String { state == .nearby ? away.nearbyName : state.name }

    let detector: CallDetector
    let calendar: CalendarSource
    /// Teams and Zoom: their mute and leave controls, for the sign and the Stream Deck keys.
    let meeting = MeetingKeys()
    let mute: MuteDetector
    /// New builds from GitHub, installed when you're off calls.
    let updater = Updater()
    /// The away keys, and whether you're at the Mac.
    let away = Away()
    private var timer: Timer?
    private var watching = Set<AnyCancellable>()

    init(detector: CallDetector, calendar: CalendarSource) {
        self.detector = detector
        self.calendar = calendar
        mute = MuteDetector(meeting: meeting)
        // objectWillChange fires before the change lands: decide on the next turn
        for publisher in [detector.objectWillChange.eraseToAnyPublisher(), calendar.objectWillChange.eraseToAnyPublisher(),
                          mute.objectWillChange.eraseToAnyPublisher(), meeting.objectWillChange.eraseToAnyPublisher(),
                          away.objectWillChange.eraseToAnyPublisher()] {
            publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
                .store(in: &watching)
        }
    }

    func start() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        meeting.start()
        away.start()
        // an update reopens the app: never on a call or in a meeting
        updater.isBusy = { [weak self] in
            guard let self else { return false }
            return self.detector.micOn || self.meeting.snapshot.active != nil || [.call, .callMuted, .meeting].contains(self.state)
        }
        updater.start()
        evaluate()
    }

    /// The call or meeting In Person would apply to: the one the sign is
    /// warning about, or says you're late for. Nil when there's none.
    var inPersonEvent: (id: String, title: String)? {
        guard [.callIn, .late, .lateMtg].contains(state), let id = decision.eventID else { return nil }
        return (id, decision.eventTitle ?? "")
    }

    /// "I'm here in person": the call or meeting on the sign shows MEETING till
    /// it ends. Joining it on the Mac still shows ON A CALL.
    func markInPerson() {
        guard let event = inPersonEvent else { return }
        inPerson.insert(event.id)
        evaluate()
    }

    /// The Stream Deck's Status key, or a double-click on the bar: during LATE
    /// FOR CALL or MTG you're there in person; otherwise Do Not Disturb on or off.
    func pressStatus() {
        if [.late, .lateMtg].contains(state), inPersonEvent != nil { markInPerson() } else { detector.toggleDND() }
    }

    func evaluate() {
        let now = Date()
        var input = StatusInput(now: now.timeIntervalSince1970 * 1000)
        input.override = detector.override.rawValue
        input.dndUntil = detector.dndUntil.map { $0.timeIntervalSince1970 * 1000 }
        input.away = away.kind?.rawValue
        input.awayUntil = away.until.map { $0.timeIntervalSince1970 * 1000 }
        input.locked = away.locked
        input.active = away.atMac
        input.micSessions = detector.micSessions
        input.events = calendar.isActive ? calendar.events : []
        input.config = calendar.config
        // in person: only for events still in the calendar
        let known = inPerson.filter { id in input.events.contains { $0.id == id } }
        if known != inPerson { inPerson = known }
        input.inPerson = Array(known)
        let d = StatusRules.decide(input)
        var next = BarState(rawValue: d.state) ?? .free

        // the apps that count as your call, for their mute buttons (FaceTime's audio runs in avconferenced)
        var callApps: [String] = []
        for holder in detector.detection.holders where holder.counts {
            let id = holder.bundleID ?? "com.apple.FaceTime"
            if !callApps.contains(id) { callApps.append(id) }
        }
        mute.update(onCall: detector.micOn, apps: callApps)
        // muted, by the call app's own button: the same ON A CALL, quieter
        if next == .call && mute.muted { next = .callMuted }

        // what the right of the pill counts to, or from
        var m: BarMoment?
        if let at = d.at.map({ Date(timeIntervalSince1970: $0 / 1000) }) {
            if d.left != nil { m = BarMoment(at: at, kind: next == .late || next == .lateMtg ? .countUp : .countdown) }
            else if [.freeTil, .callTbc, .busyTbc].contains(next) { m = BarMoment(at: at, kind: .fixed) }
        }

        let dark = wallHours.isDark(at: now, quiet: BarEngine.quiet(next))

        if decision != d { decision = d }
        if moment != m { moment = m }
        if state != next { state = next }
        if wallDark != dark { wallDark = dark }
    }
}

/// How the bar's states are named and marked outside the bar: the menus,
/// the menu-bar icon and the controls window.
extension BarState {
    var name: String {
        switch self {
        case .call: return "On a call"
        case .callMuted: return "On a call, muted"
        case .meeting: return "In a meeting"
        case .free: return "Free"
        case .dnd: return "Do Not Disturb"
        case .callIn: return "Call soon"
        case .busyIn: return "Meeting soon"
        case .late: return "Late for a call"
        case .lateMtg: return "Late for a meeting"
        case .freeTil: return "Free till the slot ends"
        case .callTbc: return "Call to be confirmed"
        case .busyTbc: return "Meeting to be confirmed"
        case .away: return "Away"
        case .lunch: return "Lunch"
        case .ooo: return "Out of office"
        case .onSite: return "Out on site"
        case .nearby: return "Nearby"
        case .backIn: return "Back in a few minutes"
        }
    }

    /// SF Symbols for the menu bar.
    var symbol: String {
        switch self {
        case .call: return "mic.circle.fill"
        case .callMuted: return "mic.slash.circle.fill"
        case .meeting: return "person.2.circle.fill"
        case .free: return "checkmark.circle"
        case .dnd: return "moon.circle.fill"
        case .callIn, .busyIn: return "bell.circle.fill"
        case .late, .lateMtg: return "exclamationmark.triangle.fill"
        case .freeTil: return "checkmark.circle.fill"
        case .callTbc, .busyTbc: return "pencil.circle"
        case .away: return "figure.walk.circle"
        case .lunch: return "fork.knife.circle"
        case .ooo: return "airplane.circle"
        case .onSite: return "mappin.circle"
        case .nearby: return "figure.walk.motion"
        case .backIn: return "arrow.uturn.backward.circle"
        }
    }

    /// The pill's colour, for dots and swatches.
    var colour: Color {
        switch self {
        case .call, .callMuted, .meeting: return Color(red: 1, green: 0.114, blue: 0.208)
        case .dnd: return Color(red: 0.357, green: 0.271, blue: 1)
        case .free: return Color(red: 0.090, green: 0.922, blue: 0.475)
        case .callIn, .busyIn, .late, .lateMtg, .freeTil, .callTbc, .busyTbc: return Color(red: 1, green: 0.635, blue: 0.102)
        case .away, .lunch, .ooo, .onSite, .nearby, .backIn: return Color(red: 0.494, green: 0.518, blue: 0.573)
        }
    }
}
