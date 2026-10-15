import Foundation

// Checks LocalAPI, what the Stream Deck plugin talks to: reading requests
// as they arrive in pieces, turning away what a web page could send, and
// the exact JSON the plugin reads (streamdeck/src/app.js).
var failures: [String] = []
func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
func bytes(_ s: String) -> Data { Data(s.utf8) }
func request(_ s: String) -> LocalAPI.Request? {
    if case .complete(let r) = LocalAPI.parse(bytes(s)) { return r }
    return nil
}

let get = "GET /status HTTP/1.1\r\nHost: 127.0.0.1:47811\r\nConnection: close\r\n\r\n"

// reading
let r = request(get)
expect(r == LocalAPI.Request(method: "GET", path: "/status", headers: ["host": "127.0.0.1:47811", "connection": "close"]),
       "a plain GET reads as one")
for cut in [0, 1, 20, get.utf8.count - 1] {
    expect(LocalAPI.parse(bytes(get).prefix(cut)) == .incomplete, "\(cut) bytes of a GET should wait for more")
}
let post = "POST /dnd/toggle HTTP/1.1\r\nHost: localhost:47811\r\nContent-Length: 2\r\n\r\n"
expect(LocalAPI.parse(bytes(post + "{")) == .incomplete, "a POST should wait for its body")
expect(request(post + "{}")?.path == "/dnd/toggle", "a POST with its body reads as one")
expect(request("POST /dnd/toggle HTTP/1.1\r\nHost: localhost:47811\r\nContent-Length: 0\r\n\r\n") != nil, "an empty POST reads")
expect(request("GET /status HTTP/1.0\r\nhOsT:   127.0.0.1:47811  \r\n\r\n")?.headers["host"] == "127.0.0.1:47811",
       "header names in any case, values trimmed, HTTP/1.0")
for bad in ["GET /status\r\n\r\n", "GET /status HTTP/2\r\n\r\n", "GET /status HTTP/1.1\r\nno colon\r\n\r\n",
            "POST /dnd/toggle HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST /dnd/toggle HTTP/1.1\r\nContent-Length: 99999\r\n\r\n",
            "POST /dnd/toggle HTTP/1.1\r\nContent-Length: -1\r\n\r\n"] {
    expect(LocalAPI.parse(bytes(bad)) == .invalid, "should refuse \(bad.debugDescription)")
}
expect(LocalAPI.parse(Data(repeating: 65, count: LocalAPI.maxRequest)) == .invalid, "a request that never ends is refused")

// routing
func route(_ method: String, _ path: String, _ headers: [String: String]) -> LocalAPI.Route {
    LocalAPI.route(LocalAPI.Request(method: method, path: path, headers: headers))
}
let here = ["host": "127.0.0.1:47811"]
expect(route("GET", "/status", here) == .status, "GET /status")
expect(route("GET", "/status", ["host": "LocalHost:47811"]) == .status, "localhost, any case")
expect(route("POST", "/dnd/toggle", here) == .toggleDND, "POST /dnd/toggle")
expect(route("GET", "/dnd/toggle", here) == .reject(405), "GET can't toggle")
expect(route("POST", "/status", here) == .reject(405), "POST /status")
expect(route("GET", "/", here) == .reject(404), "unknown path")
expect(route("GET", "/status", [:]) == .reject(403), "no Host")
expect(route("GET", "/status", ["host": "evil.example:47811"]) == .reject(403), "another Host (DNS rebinding)")
expect(route("POST", "/dnd/toggle", ["host": "127.0.0.1:47811", "origin": "https://evil.example"]) == .reject(403),
       "a web page's request (Origin)")
expect(route("POST", "/dnd/toggle", ["host": "127.0.0.1:47811", "origin": "null"]) == .reject(403), "Origin: null")

// answering
let call = LocalAPI.Status(state: "call", moment: LocalAPI.Status.Moment(at: 1_760_000_000_000, kind: "countdown"), dnd: false)
expect(String(decoding: LocalAPI.encode(call), as: UTF8.self)
       == #"{"dnd":false,"moment":{"at":1760000000000,"kind":"countdown"},"state":"call"}"#, "status JSON with a moment")
expect(String(decoding: LocalAPI.encode(LocalAPI.Status(state: "dnd", moment: nil, dnd: true)), as: UTF8.self)
       == #"{"dnd":true,"state":"dnd"}"#, "status JSON without one")
let ok = String(decoding: LocalAPI.response(200, body: bytes("{}")), as: UTF8.self)
expect(ok == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{}",
       "a 200 with a body")
expect(String(decoding: LocalAPI.response(403), as: UTF8.self).hasPrefix("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n"),
       "a 403 without one")

for f in failures { print("FAIL", f) }
print(failures.isEmpty ? "local API reads, routes and answers as designed" : "\(failures.count) local API checks failed")
exit(failures.isEmpty ? 0 : 1)
