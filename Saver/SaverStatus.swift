import Foundation
#if canImport(Network)
import Network
#endif

/*
 * What the screen saver needs from the app: what the sign says, the moment
 * its countdown is about (and the meeting its time-left rail is), which monitor is the wall and how it's laid out,
 * the Nearby key's word if it's been given one, and whether the wall's dark
 * out of hours — read from the app's answer to GET /status
 * (Sources/LocalAPI.swift).
 * The reading is Foundation only, so Checks/saver tests it anywhere Swift
 * runs, against LocalAPI's own answers. (LocalAPI.swift is compiled into
 * the screen saver too, for the port and the report it sends.)
 */
struct SaverStatus: Equatable {
    struct Moment: Equatable {
        var at: Double                  // ms since 1970
        var kind: String                // countdown, countUp, fixed
        var slot: Slot? = nil           // on a call or in a meeting: the meeting you're in, for the time-left rail

        struct Slot: Equatable {
            var start: Double, end: Double      // ms since 1970
        }
    }
    struct Wall: Equatable {
        var display: UInt32             // the monitor's CGDirectDisplayID
        var layout: String              // wide, stacked
    }

    /// A BarState raw value: "callMuted" while you're muted on a call.
    var state: String
    var moment: Moment?
    var wall: Wall?
    /// What the sign says in place of NEARBY, or nil for NEARBY.
    var nearbyWord: String? = nil
    /// Out of hours with nothing going on: the wall's black, and the screen saver with it.
    var dark = false

    /// What the screen saver sends: the Host LocalAPI expects, no Origin, and
    /// where it is, so the app can say which monitors it's showing on.
    static func request(_ report: LocalAPI.SaverReport?) -> Data {
        var r = "GET /status HTTP/1.1\r\nHost: 127.0.0.1:\(LocalAPI.port)\r\nConnection: close\r\n"
        if let report { r += "X-Busy-Bar-Saver: " + LocalAPI.saverHeaderValue(report) + "\r\n" }
        return Data((r + "\r\n").utf8)
    }

    /// A whole HTTP response from the app; nil unless it's a 200 with the sign's status in it.
    static func read(_ response: Data) -> SaverStatus? {
        guard let split = response.range(of: Data("\r\n\r\n".utf8)),
              String(decoding: response[response.startIndex..<split.lowerBound], as: UTF8.self).hasPrefix("HTTP/1.1 200 "),
              let o = try? JSONSerialization.jsonObject(with: response[split.upperBound...]) as? [String: Any],
              let state = o["state"] as? String else { return nil }
        // a muted call is "call" with muted alongside, so older Stream Deck plugins read it as before
        var status = SaverStatus(state: state == "call" && o["muted"] as? Bool == true ? "callMuted" : state)
        if let m = o["moment"] as? [String: Any], let at = (m["at"] as? NSNumber)?.doubleValue, let kind = m["kind"] as? String {
            status.moment = Moment(at: at, kind: kind)
            if let s = m["slot"] as? [String: Any], let start = (s["start"] as? NSNumber)?.doubleValue,
               let end = (s["end"] as? NSNumber)?.doubleValue {
                status.moment?.slot = Moment.Slot(start: start, end: end)
            }
        }
        if let w = o["wall"] as? [String: Any], let display = (w["display"] as? NSNumber)?.uint32Value,
           let layout = w["layout"] as? String {
            status.wall = Wall(display: display, layout: layout)
        }
        status.nearbyWord = o["nearbyWord"] as? String
        status.dark = o["dark"] as? Bool ?? false
        return status
    }
}

#if canImport(Network)
/// Asks the app, on this Mac, once. Over a plain TCP connection rather than
/// URLSession: App Transport Security follows the screen saver's host app,
/// which says nothing about plain HTTP to 127.0.0.1.
final class SaverStatusClient {
    private let queue = DispatchQueue(label: "com.woodall.BusyBarSign.Saver.status")

    /// Calls `done` on the main queue with the status, or nil if the app didn't answer within a second.
    func ask(_ report: LocalAPI.SaverReport?, _ done: @escaping (SaverStatus?) -> Void) {
        let request = SaverStatus.request(report)
        let connection = NWConnection(host: "127.0.0.1", port: 47811, using: .tcp)
        var received = Data()
        var finished = false
        func finish(_ status: SaverStatus?) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            DispatchQueue.main.async { done(status) }
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let data { received.append(data) }
                if complete || error != nil || received.count > 256 * 1024 {
                    finish(SaverStatus.read(received))
                } else {
                    receive()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { _ in })
                receive()
            case .waiting, .failed:
                finish(nil)                     // not running: the connection's refused
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 1) { finish(nil) }
    }
}
#endif
