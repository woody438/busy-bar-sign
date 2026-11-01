import Foundation
import Network

/*
 * A small web server for the Stream Deck plugin and the screen saver, on 127.0.0.1 only:
 * nothing else on the network can reach it. LocalAPI says what each
 * request means; this listens, and answers from the sign's own status —
 * or, for the Mute and Leave keys, once MeetingKeys has pressed.
 * One request per connection, then it closes.
 */
@MainActor
final class LocalServer: ObservableObject {
    /// Why the Stream Deck can't reach the app, or nil when it can.
    @Published private(set) var problem: String?

    private let detector: CallDetector
    private let status: StatusModel
    private let wall: DisplayWindow
    private let saver: SaverInstaller
    private var listener: NWListener?
    /// Connections still sending their request.
    private var asking = Set<ObjectIdentifier>()

    init(detector: CallDetector, status: StatusModel, wall: DisplayWindow, saver: SaverInstaller) {
        self.detector = detector
        self.status = status
        self.wall = wall
        self.saver = saver
    }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: LocalAPI.port)!)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { return failed(error) }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.serve(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func changed(_ state: NWListener.State) {
        switch state {
        case .ready: problem = nil
        case .failed(let error): failed(error)
        default: break
        }
    }

    /// The port is taken (by another copy of the app?): say so, and try again shortly.
    private func failed(_ error: Error) {
        problem = "The Stream Deck can't reach the app: port \(LocalAPI.port) — \(error.localizedDescription)"
        stop()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.start()
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        let id = ObjectIdentifier(connection)
        asking.insert(id)
        read(connection, Data())
        // a client that never finishes asking is let go (a meeting key's answer can take a few seconds)
        Task {
            try? await Task.sleep(for: .seconds(5))
            if asking.remove(id) != nil { connection.cancel() }
        }
    }

    private func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: LocalAPI.maxRequest) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, error == nil else { return connection.cancel() }
                let received = received + (data ?? Data())
                switch LocalAPI.parse(received) {
                case .complete(let request): self.answer(request, on: connection)
                case .incomplete where !isComplete: self.read(connection, received)
                case .incomplete, .invalid: self.send(LocalAPI.response(400), on: connection)
                }
            }
        }
    }

    private func answer(_ request: LocalAPI.Request, on connection: NWConnection) {
        asking.remove(ObjectIdentifier(connection))
        switch LocalAPI.route(request) {
        case .status:
            // the screen saver says which monitor it's on
            if let report = LocalAPI.saverReport(request) { saver.heard(report) }
        case .toggleDND:
            status.pressStatus()                // Do Not Disturb, or in person during LATE
            status.evaluate()                   // decide now, so the answer has the new state
        case .meetingMute:
            return press(.mute, on: connection)
        case .meetingLeave:
            return press(.leave, on: connection)
        case .meetingEnd:
            return press(.end, on: connection)
        case .eventEnd:
            // the Leave key outside a Teams or Zoom meeting: the event on the sign is over
            let event = status.endableEvent
            status.endEvent()
            var answer = current
            answer.pressed = LocalAPI.Status.Pressed(ok: event != nil,
                                                     message: event.map { "Ended “\($0.title)” early." } ?? "Nothing on the sign to end.")
            return send(LocalAPI.response(200, body: LocalAPI.encode(answer)), on: connection)
        case .away(let key):
            if let key = AwayState.Kind(rawValue: key) { status.away.press(key) }
            status.evaluate()
        case .awayEnd:
            status.away.end()
            status.evaluate()
        case .reject(let code):
            return send(LocalAPI.response(code), on: connection)
        }
        send(LocalAPI.response(200, body: LocalAPI.encode(current)), on: connection)
    }

    /// A Mute or Leave key (held: end): answers once the meeting app has been pressed, with how it went.
    /// Left, the sign moves straight on (StatusModel.leftCall), so the answer has FREE or what's next.
    private func press(_ what: MeetingControl, on connection: NWConnection) {
        status.meeting.press(what) { [weak self] report in
            guard let self else { return connection.cancel() }
            if report.ok && what != .mute { self.status.leftCall() }
            self.status.evaluate()
            var answer = self.current
            answer.pressed = LocalAPI.Status.Pressed(ok: report.ok, message: report.message)
            self.send(LocalAPI.response(200, body: LocalAPI.encode(answer)), on: connection)
        }
    }

    private var current: LocalAPI.Status {
        let moment = status.moment.map { m in
            LocalAPI.Status.Moment(at: Int64((m.at.timeIntervalSince1970 * 1000).rounded()), kind: m.kind.apiName)
        }
        // a muted call is still "call" to the Stream Deck, with muted alongside
        let muted = status.state == .callMuted
        // the Teams or Zoom meeting the keys act on
        let snap = status.meeting.snapshot
        let meeting = snap.active.flatMap { app in
            snap.apps[app].map { LocalAPI.Status.Meeting(app: app.rawValue, muted: $0.muted, canLeave: $0.canLeave) }
        }
        let away = status.away.kind.map { kind in
            LocalAPI.Status.Away(kind: kind.rawValue, until: status.away.until.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) })
        }
        // where the full-screen display is, for the screen saver
        let wall = self.wall.displayNumber.map { LocalAPI.Status.Wall(display: $0, layout: DisplayWindow.layout.rawValue) }
        // what the sign says in place of NEARBY, for the Stream Deck and the screen saver
        let nearby = BarEngine.nearbyWord == BarEngine.nearbyDefault ? nil : BarEngine.nearbyWord
        return LocalAPI.Status(state: muted ? BarState.call.rawValue : status.state.rawValue, moment: moment,
                               dnd: detector.dndUntil != nil, muted: muted ? true : nil, meeting: meeting, away: away, wall: wall,
                               nearbyWord: nearby, dark: status.wallDark ? true : nil,
                               canEnd: meeting == nil && status.endableEvent != nil ? true : nil)
    }

    private func send(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}

private extension BarMoment.Kind {
    var apiName: String {
        switch self {
        case .countdown: return "countdown"
        case .countUp: return "countUp"
        case .fixed: return "fixed"
        }
    }
}
