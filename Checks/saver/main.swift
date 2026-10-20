import Foundation

// Checks SaverStatus, the screen saver's reading of the app's answer:
// LocalAPI's own answers, read back as the screen saver reads them.
var failures: [String] = []
func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
func answer(_ status: LocalAPI.Status) -> Data { LocalAPI.response(200, body: LocalAPI.encode(status)) }

var back = LocalAPI.Status(state: "backIn", moment: LocalAPI.Status.Moment(at: 1_760_000_600_000, kind: "countdown"), dnd: false)
back.away = LocalAPI.Status.Away(kind: "backIn", until: 1_760_000_600_000)
back.wall = LocalAPI.Status.Wall(display: 3, layout: "stacked")
expect(SaverStatus.read(answer(back)) == SaverStatus(state: "backIn", moment: .init(at: 1_760_000_600_000, kind: "countdown"),
                                                     wall: .init(display: 3, layout: "stacked")),
       "BACK IN, its countdown and the wall")
expect(SaverStatus.read(answer(LocalAPI.Status(state: "nearby", moment: nil, dnd: false))) == SaverStatus(state: "nearby"),
       "NEARBY, with no wall up")
expect(SaverStatus.read(answer(LocalAPI.Status(state: "nearby", moment: nil, dnd: false, nearbyWord: "W HOUSE")))
       == SaverStatus(state: "nearby", nearbyWord: "W HOUSE"),
       "the Nearby key's own word")
expect(SaverStatus.read(answer(LocalAPI.Status(state: "call", moment: nil, dnd: false, muted: true)))?.state == "callMuted",
       "muted on a call reads as the bar draws it")
expect(SaverStatus.read(answer(LocalAPI.Status(state: "call", moment: nil, dnd: false)))?.state == "call", "on a call")
expect(SaverStatus.read(LocalAPI.response(403)) == nil, "a refusal is no answer")
expect(SaverStatus.read(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)) == nil, "an answer with no state")
expect(SaverStatus.read(Data("HTTP/1.1 200 OK\r\n".utf8)) == nil, "half an answer")
expect(SaverStatus.read(Data()) == nil, "nothing")

// what it asks is what LocalAPI answers, with where it is
let here = LocalAPI.SaverReport(display: 4, drawing: true, name: "LG HDR 4K; =wall\r\n")
for report in [nil, here] {
    if case .complete(let request) = LocalAPI.parse(SaverStatus.request(report)) {
        expect(LocalAPI.route(request) == .status, "the screen saver's request is a GET /status the app answers")
        expect(LocalAPI.saverReport(request) == report.map { LocalAPI.SaverReport(display: $0.display, drawing: $0.drawing,
                                                                                  name: "LG HDR 4K; =wall") },
               "the app reads where it is, whatever the monitor's called")
    } else {
        failures.append("the screen saver's request doesn't read as one")
    }
}

for f in failures { print("FAIL", f) }
print(failures.isEmpty ? "the screen saver reads the app's answers as designed" : "\(failures.count) screen saver checks failed")
exit(failures.isEmpty ? 0 : 1)
