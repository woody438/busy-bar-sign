import Foundation
import Network

/*
 * A small web server for the Stream Deck plugin, on 127.0.0.1 only:
 * nothing else on the network can reach it. LocalAPI says what each
 * request means; this listens, and answers from the sign's own status.
 * One request per connection, then it closes.
 */
@MainActor
final class LocalServer: ObservableObject {
    /// Why the Stream Deck can't reach the app, or nil when it can.
    @Published private(set) var problem: String?

    private let detector: CallDetector
    private let status: StatusModel
    private var listener: NWListener?

    init(detector: CallDetector, status: StatusModel) {
        self.detector = detector
        self.status = status
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
        read(connection, Data())
        // a client that never finishes asking is let go
        Task {
            try? await Task.sleep(for: .seconds(5))
            connection.cancel()
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
        switch LocalAPI.route(request) {
        case .status:
            break
        case .toggleDND:
            detector.toggleDND()
            status.evaluate()                   // decide now, so the answer has the new state
        case .reject(let code):
            return send(LocalAPI.response(code), on: connection)
        }
        send(LocalAPI.response(200, body: LocalAPI.encode(current)), on: connection)
    }

    private var current: LocalAPI.Status {
        let moment = status.moment.map { m in
            LocalAPI.Status.Moment(at: Int64((m.at.timeIntervalSince1970 * 1000).rounded()), kind: m.kind.apiName)
        }
        return LocalAPI.Status(state: status.state.rawValue, moment: moment, dnd: detector.dndUntil != nil)
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
