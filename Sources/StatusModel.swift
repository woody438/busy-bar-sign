import Combine
import SwiftUI

/*
 * What the sign says, all things considered: the manual controls and the
 * microphone (CallDetector), Do Not Disturb, and the calendar
 * (CalendarSource), decided by StatusRules once a second and whenever
 * one of them changes. Every view of the bar, the menus and the controls
 * read it from here.
 */
@MainActor
final class StatusModel: ObservableObject {
    @Published private(set) var state: BarState = .free
    @Published private(set) var decision = StatusDecision(state: "free", why: "Free")
    /// The moment the bar's right-hand side is about, or nil for the clock.
    @Published private(set) var moment: BarMoment?

    let detector: CallDetector
    let calendar: CalendarSource
    private var timer: Timer?
    private var watching = Set<AnyCancellable>()

    init(detector: CallDetector, calendar: CalendarSource) {
        self.detector = detector
        self.calendar = calendar
        // objectWillChange fires before the change lands: decide on the next turn
        for publisher in [detector.objectWillChange.eraseToAnyPublisher(), calendar.objectWillChange.eraseToAnyPublisher()] {
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
        evaluate()
    }

    func evaluate() {
        let now = Date()
        var input = StatusInput(now: now.timeIntervalSince1970 * 1000)
        input.override = detector.override.rawValue
        input.dndUntil = detector.dndUntil.map { $0.timeIntervalSince1970 * 1000 }
        input.micSessions = detector.micSessions
        input.events = calendar.isActive ? calendar.events : []
        input.config = calendar.config
        let d = StatusRules.decide(input)
        let next = BarState(rawValue: d.state) ?? .free

        // what the right of the pill counts to, or from
        var m: BarMoment?
        if let at = d.at.map({ Date(timeIntervalSince1970: $0 / 1000) }) {
            if d.left != nil { m = BarMoment(at: at, kind: next == .late ? .countUp : .countdown) }
            else if [.freeTil, .callTbc, .busyTbc].contains(next) { m = BarMoment(at: at, kind: .fixed) }
        }

        if decision != d { decision = d }
        if moment != m { moment = m }
        if state != next { state = next }
    }
}

/// How the bar's states are named and marked outside the bar: the menus,
/// the menu-bar icon and the controls window.
extension BarState {
    var name: String {
        switch self {
        case .call: return "On a call"
        case .meeting: return "In a meeting"
        case .free: return "Free"
        case .dnd: return "Do Not Disturb"
        case .callIn: return "Call soon"
        case .busyIn: return "Meeting soon"
        case .late: return "Late for a call"
        case .freeTil: return "Free till the slot ends"
        case .callTbc: return "Call to be confirmed"
        case .busyTbc: return "Meeting to be confirmed"
        case .away: return "Away"
        case .lunch: return "Lunch"
        case .ooo: return "Out of office"
        }
    }

    /// SF Symbols for the menu bar.
    var symbol: String {
        switch self {
        case .call: return "mic.circle.fill"
        case .meeting: return "person.2.circle.fill"
        case .free: return "checkmark.circle"
        case .dnd: return "moon.circle.fill"
        case .callIn, .busyIn: return "bell.circle.fill"
        case .late: return "exclamationmark.triangle.fill"
        case .freeTil: return "checkmark.circle.fill"
        case .callTbc, .busyTbc: return "pencil.circle"
        case .away: return "figure.walk.circle"
        case .lunch: return "fork.knife.circle"
        case .ooo: return "airplane.circle"
        }
    }

    /// The pill's colour, for dots and swatches.
    var colour: Color {
        switch self {
        case .call, .meeting: return Color(red: 1, green: 0.114, blue: 0.208)
        case .dnd: return Color(red: 0.357, green: 0.271, blue: 1)
        case .free: return Color(red: 0.090, green: 0.922, blue: 0.475)
        case .callIn, .busyIn, .late, .freeTil, .callTbc, .busyTbc: return Color(red: 1, green: 0.635, blue: 0.102)
        case .away, .lunch, .ooo: return Color(red: 0.494, green: 0.518, blue: 0.573)
        }
    }
}
