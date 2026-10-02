import Foundation

// Runs Sources/StatusRules.swift on every case simulator/tools/rules-cases.js
// wrote, and checks it decides what rules.js decided: the same state, the
// same countdown and the same moment.
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
let cases = root["cases"] as! [[String: Any]]

func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
func str(_ v: Any?) -> String { v as? String ?? "" }

func event(_ o: [String: Any]) -> CalEvent {
    CalEvent(id: str(o["id"]), title: str(o["title"]), start: num(o["start"]) ?? 0, end: num(o["end"]) ?? 0,
             allDay: o["allDay"] as? Bool ?? false,
             availability: CalEvent.Availability(rawValue: str(o["availability"])) ?? .busy,
             attendees: Int(num(o["attendees"]) ?? 0), notes: str(o["notes"]), location: str(o["location"]),
             url: str(o["url"]), cancelled: o["cancelled"] as? Bool ?? false)
}

func input(_ o: [String: Any]) -> StatusInput {
    var i = StatusInput(now: num(o["now"])!)
    i.override = o["override"] as? String ?? "auto"
    i.dndUntil = num(o["dndUntil"])
    i.micSessions = (o["micSessions"] as? [[String: Any]] ?? []).map { MicSession(start: num($0["start"])!, end: num($0["end"])) }
    i.events = (o["events"] as? [[String: Any]] ?? []).map(event)
    if let config = o["config"] as? [String: Any], let kw = config["keywords"] as? [String: [String]] {
        if let w = kw["ooo"] { i.config.keywords.ooo = w }
        if let w = kw["lunch"] { i.config.keywords.lunch = w }
        if let w = kw["dnd"] { i.config.keywords.dnd = w }
        if let w = kw["call"] { i.config.keywords.call = w }
    }
    return i
}

func same(_ a: Double?, _ b: Double?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return abs(x - y) < 1e-6
    default: return false
    }
}

var failures: [String] = []
for (n, c) in cases.enumerated() {
    let i = input(c["input"] as! [String: Any])
    let want = c["expect"] as! [String: Any]
    let got = StatusRules.decide(i)
    if got.state != str(want["state"]) || !same(got.left, num(want["left"])) || !same(got.at, num(want["at"])) {
        failures.append("case \(n) at \(i.now / 60000) min: got \(got.state) left \(got.left.map { "\($0)" } ?? "-") at \(got.at.map { "\($0)" } ?? "-")"
                        + "; want \(str(want["state"])) left \(num(want["left"]).map { "\($0)" } ?? "-") at \(num(want["at"]).map { "\($0)" } ?? "-")")
    }
}
for f in failures.prefix(20) { print("FAIL", f) }
print(failures.isEmpty ? "status rules match the simulator in all \(cases.count) cases"
                       : "\(failures.count) of \(cases.count) cases differ")
exit(failures.isEmpty ? 0 : 1)
