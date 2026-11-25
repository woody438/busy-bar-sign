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
 * on, it says the wall's dark. A camera on during a call lights the tally,
 * and its coming on or going off mid-call is announced, CAMERA ON or CAMERA
 * OFF (CameraFollower). Every view of the bar, the menus and the controls
 * read it from here.
 */

/// The camera coming on or going off mid-call, to announce: `serial` counts
/// them, so every one plays, however often.
struct CameraCueEvent: Equatable {
    let cue: BarCue
    let serial: Int
}
@MainActor
final class StatusModel: ObservableObject {
    @Published private(set) var state: BarState = .free
    @Published private(set) var decision = StatusDecision(state: "free", why: "Free")
    /// The moment the bar's right-hand side is about, or nil for the clock.
    @Published private(set) var moment: BarMoment?
    /// Out of hours with nothing going on: the wall and the screen saver are black.
    @Published private(set) var wallDark = false
    /// When the wall goes dark (Settings ▸ Screen care ▸ Working hours).
    @Published var wallHours = WallHours(.standard) {
        didSet {
            wallHours.save(to: .standard)
            evaluate()
        }
    }
    /// The calendar events you've said you're at in person (In Person, or the
    /// Status key during LATE): a call there shows MEETING, and never LATE.
    @Published private(set) var inPerson: Set<String> = []
    /// The calendar events you've said are over early (End Now, or the Leave
    /// key outside a Teams or Zoom meeting): off the sign as if they'd ended.
    @Published private(set) var ended: Set<String> = []
    /// FaceTime or WhatsApp on the mic, surely — by bundle ID, or FaceTime's
    /// audio daemon by name — for the Mute and Leave keys.
    private(set) var keyCallApps: [LabelledCallApp] = []
    /// A camera's on during a call: the tally (the light in the case, or stacked, a dot).
    @Published private(set) var camera = false
    /// The last camera change mid-call to announce: CAMERA ON or CAMERA OFF.
    @Published private(set) var cameraCue: CameraCueEvent?
    /// The call app on the mic that isn't Teams or Zoom, for the Camera key: FaceTime,
    /// WhatsApp, or any other (Google Meet in a browser).
    private(set) var cameraCall: CameraCall?
    /// Whether any camera on the Mac is streaming now: the green light's signal.
    var cameraRunning: Bool { detector.detection.cameraActive }
    private var cameraFollower = CameraFollower()
    private var cueSerial = 0
    /// What the sign says, in words, for the menus and the controls: the
    /// Nearby key's own word for .nearby.
    var stateName: String { state == .nearby ? away.nearbyName : state.name }

    let detector: CallDetector
    let calendar: CalendarSource
    /// Teams and Zoom: their mute and leave controls, for the sign and the Stream Deck keys
    /// (which reach FaceTime and WhatsApp through it too).
    let meeting = MeetingKeys()
    let mute: MuteDetector
    /// New builds from GitHub, installed when you're off calls.
    let updater = Updater()
    /// The away keys, and whether you're at the Mac.
    let away = Away()
    private var timer: Timer?
    private var watching = Set<AnyCancellable>()
    /// Whether a Teams or Zoom meeting was on at the last evaluation.
    private var wasInMeeting = false

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

    /// The FaceTime or WhatsApp call the Mute and Leave keys act on: one of
    /// them on the mic, with no Teams or Zoom meeting found.
    var labelledCall: LabelledCallApp? {
        guard meeting.snapshot.active == nil else { return nil }
        return keyCallApps.first
    }

    /// The calendar event End Now would end: the one the sign is showing, while
    /// it's on and the sign isn't following the mic. Nil when there's none.
    var endableEvent: (id: String, title: String)? {
        guard !detector.micOn, state != .freeTil, let id = decision.eventID, calendar.isActive,
              let event = calendar.events.first(where: { $0.id == id }) else { return nil }
        let now = Date().timeIntervalSince1970 * 1000
        guard event.start <= now && now < event.end else { return nil }
        return (id, decision.eventTitle ?? "")
    }

    /// "It's finished": the event on the sign is over, early. The sign moves on
    /// to whatever's next: FREE, till the next one warns.
    func endEvent() {
        guard let event = endableEvent else { return }
        ended.insert(event.id)
        evaluate()
    }

    /// The Leave key left the Teams or Zoom meeting (or ended it for everyone),
    /// or the FaceTime or WhatsApp call: the sign moves straight on, as if the
    /// call had ended there and then —
    /// FREE, or what's next: CALL IN for one soon, LATE FOR one you've overrun
    /// into. The calendar events the call was for are over (a meeting in a room
    /// with a Teams link would otherwise say MEETING till its slot ended, and a
    /// phone-call block ON A CALL); the mic's done with now, not ten seconds
    /// on; Do Not Disturb ends, and Force ON A CALL goes back to Automatic.
    func leftCall() {
        var input = StatusInput(now: Date().timeIntervalSince1970 * 1000)
        input.micSessions = detector.micSessions
        input.events = calendar.isActive ? calendar.events : []
        input.config = calendar.config
        input.ended = Array(ended)
        ended.formUnion(StatusRules.leftEvents(input))
        detector.callLeft()
        evaluate()
    }

    /// The Stream Deck's Status key, or a double-click on the bar: during LATE
    /// FOR CALL or MTG you're there in person; otherwise Do Not Disturb on or off.
    func pressStatus() {
        if [.late, .lateMtg].contains(state), inPersonEvent != nil { markInPerson() } else { detector.toggleDND() }
    }

    func evaluate() {
        // a meeting started since the Leave key: the mic's that call's, at once
        let inMeeting = meeting.snapshot.active != nil
        if inMeeting && !wasInMeeting { detector.endLeaveGrace() }
        wasInMeeting = inMeeting

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
        let over = ended.filter { id in input.events.contains { $0.id == id } }
        if over != ended { ended = over }
        input.ended = Array(over)
        let d = StatusRules.decide(input)
        var next = BarState(rawValue: d.state) ?? .free

        // the apps that count as your call, for their mute buttons: FaceTime's audio runs in
        // avconferenced, which has no windows of its own, so FaceTime is read for it
        var callApps: [String] = []
        var keyApps: [LabelledCallApp] = []
        var camCall: CameraCall?
        for holder in detector.detection.holders where holder.counts {
            var id = holder.bundleID ?? "com.apple.FaceTime"
            if id == "com.apple.avconferenced" { id = "com.apple.FaceTime" }
            if !callApps.contains(id) { callApps.append(id) }
            // the Camera key, with no Teams or Zoom meeting: FaceTime or WhatsApp, else any app on the mic by bundle ID
            if camCall == nil && MeetingApp(bundleID: id) == nil {
                if let app = LabelledCallApp(bundleID: id) {
                    camCall = CameraCall(name: app.label, bundleIDs: app.appBundleIDs, hover: app.hoverControls)
                } else if holder.bundleID != nil {
                    camCall = CameraCall(name: holder.name, bundleIDs: [id], hover: false)
                }
            }
            // the keys: not just any tool with no bundle ID — only what's surely FaceTime or WhatsApp
            let byName: LabelledCallApp? = holder.name.lowercased().contains("avconferenced") ? LabelledCallApp.facetime : nil
            let sure: LabelledCallApp? = holder.bundleID.flatMap(LabelledCallApp.init(bundleID:)) ?? byName
            if let sure, !keyApps.contains(sure) { keyApps.append(sure) }
        }
        if keyCallApps != keyApps { keyCallApps = keyApps }
        if cameraCall != camCall { cameraCall = camCall }
        // Teams or Zoom taking the mic: their meeting's looked for straight away
        meeting.onMic(Set(callApps.compactMap(MeetingApp.init(bundleID:))))
        mute.update(onCall: detector.micOn, apps: callApps)
        // muted, by the call app's own button: the same ON A CALL, quieter
        if next == .call && mute.muted { next = .callMuted }

        // what the right of the pill counts to, or from; on a call or in a meeting, the
        // meeting you're in, for the time-left rail
        var m: BarMoment?
        if let at = d.at.map({ Date(timeIntervalSince1970: $0 / 1000) }) {
            let slot = d.slot.flatMap { s in
                s.end > s.start ? DateInterval(start: Date(timeIntervalSince1970: s.start / 1000),
                                               end: Date(timeIntervalSince1970: s.end / 1000)) : nil
            }
            if d.left != nil { m = BarMoment(at: at, kind: next == .late || next == .lateMtg ? .countUp : .countdown, slot: slot) }
            else if [.freeTil, .callTbc, .busyTbc].contains(next) { m = BarMoment(at: at, kind: .fixed) }
        }

        let dark = wallHours.isDark(at: now, quiet: BarEngine.quiet(next))

        // the camera: the tally while one's on during a call, and CAMERA ON or OFF as it changes mid-call
        let onCall = next == .call || next == .callMuted
        if let cue = cameraFollower.step(at: ProcessInfo.processInfo.systemUptime, camera: detector.detection.cameraActive,
                                         mic: detector.detection.onCall, onCall: onCall) {
            cueSerial += 1
            cameraCue = CameraCueEvent(cue: cue == .cameraOn ? .cameraOn : .cameraOff, serial: cueSerial)
        }
        let tally = cameraFollower.tally(onCall: onCall)

        if decision != d { decision = d }
        if moment != m { moment = m }
        if camera != tally { camera = tally }
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
