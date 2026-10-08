import Foundation

/*
 * What the Stream Deck plugin (streamdeck/) can ask the app, without the
 * networking: reading a request, deciding what it asks for, and writing
 * the answer. LocalServer listens and answers. Foundation only, so
 * Checks/http can test it anywhere Swift runs.
 *
 *   GET  /status       {"dnd":false,"moment":{"at":1760000000000,"kind":"countdown"},"state":"call"}
 *   POST /dnd/toggle   as a double-click on the bar; answers with the new status
 *
 * `state` is a BarState. `moment` is what the right of the pill is about,
 * in ms since 1970 — counted down to ("countdown"), up from ("countUp",
 * LATE) or just shown ("fixed", FREE TILL) — and absent while the bar
 * shows the clock. `dnd` is whether a Do Not Disturb is running, shown or
 * not: a call outranks it.
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

    enum Route: Equatable { case status, toggleDND, reject(Int) }

    /// What a request asks for, or the status code it's turned away with.
    static func route(_ request: Request) -> Route {
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard hosts.contains(request.headers["host"]?.lowercased() ?? ""),
              request.headers["origin"] == nil else { return .reject(403) }
        switch (request.method, request.path) {
        case ("GET", "/status"): return .status
        case ("POST", "/dnd/toggle"): return .toggleDND
        case (_, "/status"), (_, "/dnd/toggle"): return .reject(405)
        default: return .reject(404)
        }
    }

    struct Status: Encodable, Equatable {
        struct Moment: Encodable, Equatable {
            var at: Int64                       // ms since 1970
            var kind: String                    // countdown, countUp, fixed
        }
        var state: String
        var moment: Moment?
        var dnd: Bool
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
