import Foundation

/*
 * What the Stream Deck plugin (streamdeck/) can ask the app, without the
 * networking: reading a request, deciding what it asks for, and writing
 * the answer. LocalServer listens and answers. Foundation only, so
 * Checks/http can test it anywhere Swift runs.
 *
 *   GET  /status          {"dnd":false,"moment":{"at":1760000000000,"kind":"countdown"},"state":"call"}
 *   POST /dnd/toggle      as a double-click on the bar; answers with the new status
 *   POST /meeting/mute    mutes or unmutes the Teams or Zoom meeting; answers
 *   POST /meeting/leave   leaves it;
 *   POST /meeting/end     ends it for everyone if it's a Zoom meeting you host
 *                         (else leaves); each answers with the status and how
 *                         the press went: "pressed":{"ok":true,"message":"…"}
 *   POST /away/nearby  the away keys: Nearby or Lunch on, or off if on;
 *   POST /away/lunch      Back In ten minutes more; End back at your desk.
 *   POST /away/back-in    Each answers with the new status
 *   POST /away/end
 *
 * `state` is a BarState. `moment` is what the right of the pill is about,
 * in ms since 1970 — counted down to ("countdown"), up from ("countUp",
 * LATE) or just shown ("fixed", FREE TILL) — and absent while the bar
 * shows the clock. `dnd` is whether a Do Not Disturb is running, shown or
 * not: a call outranks it. `muted` appears, true, only while you're muted
 * on a call; `state` stays "call" then, so older plugins read it as before.
 * `meeting` appears while you're in a Teams or Zoom meeting:
 * {"app":"teams","canLeave":true,"muted":false}, `muted` left out when the
 * meeting's mute can't be read. `away` appears while an away key is on:
 * {"kind":"backIn","until":1760000000000} — nearby, lunch or backIn,
 * `until` (ms) for backIn only. `nearbyWord` appears once the Nearby key's
 * been given a word of its own in Settings: "W HOUSE", in capitals, what the
 * sign says in place of NEARBY. `wall` appears while the full-screen display
 * is up: {"display":3,"layout":"wide"}, its monitor's display number and its
 * layout, for the screen saver to draw the wall as the wall is drawn.
 *
 * The screen saver adds a header to its GET /status saying where it is:
 *   X-Busy-Bar-Saver: display=4; drawing=1; name=LG HDR 4K
 * its monitor's CGDirectDisplayID, whether it drew since it last asked, and
 * the monitor's name (last, as it can hold anything but a line break).
 *
 * For programs on this Mac only. LocalServer listens on 127.0.0.1, and
 * this turns away what a web page could send: a request with an Origin
 * (browsers add one), or a Host other than 127.0.0.1 or localhost (a page
 * reaching it through a name it controls: DNS rebinding).
 */
enum LocalAPI {
    static let port: UInt16 = 47811

    /// The longest request read: a request line and a few headers.
    static let maxRequest = 16 * 1024

    struct Request: Equatable {
        var method: String
        var path: String
        var headers: [String: String]           // names in lower case
    }

    enum Parsed: Equatable { case incomplete, complete(Request), invalid }

    /// Reads a request from the bytes received so far.
    static func parse(_ data: Data) -> Parsed {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count < maxRequest ? .incomplete : .invalid
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, start[2] == "HTTP/1.1" || start[2] == "HTTP/1.0" else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // nothing here takes a body: a short one is read and ignored, a chunked one refused
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), (0...1024).contains(length) else { return .invalid }
        if data.endIndex - end.upperBound < length { return .incomplete }
        return .complete(Request(method: String(start[0]), path: String(start[1]), headers: headers))
    }

    enum Route: Equatable {
        case status, toggleDND, meetingMute, meetingLeave, meetingEnd
        case away(String)                       // an away key: nearby, lunch, backIn
        case awayEnd
        case reject(Int)
    }

    /// What a request asks for, or the status code it's turned away with.
    static func route(_ request: Request) -> Route {
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard hosts.contains(request.headers["host"]?.lowercased() ?? ""),
              request.headers["origin"] == nil else { return .reject(403) }
        switch (request.method, request.path) {
        case ("GET", "/status"): return .status
        case ("POST", "/dnd/toggle"): return .toggleDND
        case ("POST", "/meeting/mute"): return .meetingMute
        case ("POST", "/meeting/leave"): return .meetingLeave
        case ("POST", "/meeting/end"): return .meetingEnd
        case ("POST", "/away/nearby"): return .away("nearby")
        case ("POST", "/away/lunch"): return .away("lunch")
        case ("POST", "/away/back-in"): return .away("backIn")
        case ("POST", "/away/end"): return .awayEnd
        case (_, "/status"), (_, "/dnd/toggle"), (_, "/meeting/mute"), (_, "/meeting/leave"), (_, "/meeting/end"),
             (_, "/away/nearby"), (_, "/away/lunch"), (_, "/away/back-in"), (_, "/away/end"):
            return .reject(405)
        default: return .reject(404)
        }
    }

    /// What a screen saver said about itself.
    struct SaverReport: Equatable {
        var display: UInt32
        var drawing: Bool
        var name: String
    }

    static let saverHeader = "x-busy-bar-saver"

    /// The screen saver's report in a request, if it's one of the screen saver's.
    static func saverReport(_ request: Request) -> SaverReport? {
        guard let value = request.headers[saverHeader] else { return nil }
        var head = value, name = ""
        if let at = value.range(of: "name=") {             // the name last: whatever it holds
            head = String(value[..<at.lowerBound])
            name = value[at.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        var fields: [String: String] = [:]
        for part in head.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { fields[kv[0]] = kv[1] }
        }
        guard let display = fields["display"].flatMap({ UInt32($0) }) else { return nil }
        return SaverReport(display: display, drawing: fields["drawing"] == "1", name: name)
    }

    /// The header the screen saver sends, as `saverReport` reads it.
    static func saverHeaderValue(_ report: SaverReport) -> String {
        let name = report.name.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return "display=\(report.display); drawing=\(report.drawing ? 1 : 0); name=\(name)"
    }

    struct Status: Encodable, Equatable {
        struct Moment: Encodable, Equatable {
            var at: Int64                       // ms since 1970
            var kind: String                    // countdown, countUp, fixed
        }
        /// The Teams or Zoom meeting you're in.
        struct Meeting: Encodable, Equatable {
            var app: String                     // teams, zoom
            var muted: Bool?                    // left out when it can't be read
            var canLeave: Bool
        }
        /// How a press of the Mute or Leave key went.
        struct Pressed: Encodable, Equatable {
            var ok: Bool
            var message: String
        }
        /// The away key that's on.
        struct Away: Encodable, Equatable {
            var kind: String                    // nearby, lunch, backIn
            var until: Int64?                   // ms since 1970, for backIn
        }
        /// The full-screen display, while it's up.
        struct Wall: Encodable, Equatable {
            var display: UInt32                 // its monitor's CGDirectDisplayID
            var layout: String                  // wide, stacked
        }
        var state: String
        var moment: Moment?
        var dnd: Bool
        /// Only there, and true, while you're muted on a call: `state` stays "call".
        var muted: Bool? = nil
        var meeting: Meeting? = nil
        var pressed: Pressed? = nil
        var away: Away? = nil
        var wall: Wall? = nil
        /// The Nearby key's own word, if it's been given one.
        var nearbyWord: String? = nil
    }

    static func encode(_ status: Status) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(status)) ?? Data()
    }

    /// A whole response; the connection closes after it.
    static func response(_ code: Int, body: Data = Data()) -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"]
        var head = "HTTP/1.1 \(code) \(reasons[code] ?? "Error")\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
