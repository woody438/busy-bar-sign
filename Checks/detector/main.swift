import Foundation

// Drives the real CallDetector through a scripted afternoon, in real time,
// and checks when the sign changes. The processes are the awkward cases:
//
//   0-1 s    nothing                                      -> FREE
//   1-7 s    Zoom has the mic                             -> ON A CALL after 2 s (~3 s)
//   7 s      Zoom lets go                                 -> FREE after 10 s (~17 s)
//   19-23 s  Wispr Flow dictating, through a helper with
//            an unfamiliar bundle ID                      -> stays FREE
//   19-35 s  Sound Recognition (Apple, always listening)  -> stays FREE throughout
//   25-26 s  Zoom, for one second only                    -> too short: stays FREE
//   28 s     override: Force ON A CALL                    -> ON A CALL at once
//   29 s     override: Automatic                          -> FREE at once
//   31-40 s  Google Meet, captured in a Chrome helper     -> ON A CALL (~33 s)
//
// and Do Not Disturb, set to 20 s for the test:
//
//   4 s      turned on during the Zoom call               -> stays ON A CALL
//   ~17 s    the call ends                                -> DO NOT DISTURB, not FREE
//   24 s     its time runs out (not reset by the call)    -> FREE
//   29.5 s   turned on                                    -> DO NOT DISTURB at once
//   30.5 s   turned off                                   -> FREE at once
//   35-36.5  on and off again during the Meet call        -> stays ON A CALL
func user(_ raw: String?, _ app: String?, _ path: String, _ name: String) -> MicUser {
    MicUser(pid: 100, rawBundleID: raw, appBundleID: app, executablePath: path, name: name)
}
let zoom = user("us.zoom.xos", "us.zoom.xos", "/Applications/zoom.us.app/Contents/MacOS/zoom.us", "zoom.us")
Script.spans = [
    Span(from: 1, to: 7, user: zoom),
    Span(from: 19, to: 23, user: user("com.example.wisprflow.helper", "com.example.wisprflow",
                                      "/Applications/Wispr Flow.app/Contents/Frameworks/Wispr Flow Helper.app/Contents/MacOS/Wispr Flow Helper",
                                      "Wispr Flow")),
    Span(from: 19, to: 35, user: user(nil, nil, "/System/Library/PrivateFrameworks/SoundAnalysis.framework/soundanalysisd",
                                      "soundanalysisd")),
    Span(from: 25, to: 26, user: zoom),
    Span(from: 31, to: 40, user: user("com.google.Chrome.helper", "com.google.Chrome",
                                      "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                                      "Google Chrome")),
]

var changes: [(Double, Sign)] = []
var failures: [String] = []
/// When each scripted action actually ran: a shared CI machine can run a
/// timer late, so "at once" is measured from here, not from the script.
var actedAt: [String: Double] = [:]

// path helper: pure string logic, check it directly
for (path, expected) in [
    ("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/x", "/Applications/Google Chrome.app"),
    ("/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper", "/Applications/Slack.app"),
    ("/usr/libexec/avconferenced", nil),
] as [(String, String?)] {
    if AppPath.outermostApp(path) != expected { failures.append("outermostApp(\(path)) gave \(String(describing: AppPath.outermostApp(path)))") }
}

Task { @MainActor in
    Script.start = Date()
    let detector = CallDetector()
    detector.endDND()                  // nothing left over from an earlier run
    detector.dndLength = 20
    detector.start()
    var last = detector.sign
    changes.append((Script.elapsed, last))
    var done = Set<String>()
    func once(_ key: String, at time: Double, _ action: () -> Void) {
        if Script.elapsed >= time && !done.contains(key) { done.insert(key); actedAt[key] = Script.elapsed; action() }
    }
    let watch = Timer(timeInterval: 0.05, repeats: true) { _ in
        MainActor.assumeIsolated {
            if detector.sign != last { last = detector.sign; changes.append((Script.elapsed, last)) }
            once("force on", at: 28) { detector.override = .onCall }
            once("automatic", at: 29) { detector.override = .auto }
            once("dnd on in call", at: 4) { detector.startDND() }
            once("dnd on", at: 29.5) { detector.toggleDND() }
            once("dnd off", at: 30.5) { detector.toggleDND() }
            once("dnd on in meet", at: 35) { detector.toggleDND() }
            once("dnd off in meet", at: 36.5) {
                detector.toggleDND()
                if detector.dndUntil != nil { failures.append("a second double-click should end Do Not Disturb") }
            }
            // a change an action made shows at once: note it now, not on the next tick
            if detector.sign != last { last = detector.sign; changes.append((Script.elapsed, last)) }
        }
    }
    RunLoop.main.add(watch, forMode: .common)
    // the microphone's own sessions, for the calendar rules: forcing ON A CALL isn't one
    let check = Timer(timeInterval: 40.5, repeats: false) { _ in
        MainActor.assumeIsolated {
            let s = detector.micSessions.map { (($0.start / 1000) - Script.start.timeIntervalSince1970,
                                                $0.end.map { ($0 / 1000) - Script.start.timeIntervalSince1970 }) }
            print("mic sessions:", s.map { String(format: "%.1f–%@", $0.0, $0.1.map { String(format: "%.1f", $0) } ?? "on") }.joined(separator: ", "))
            if s.count != 2 { failures.append("expected two mic sessions (Zoom, Meet), saw \(s.count)") }
            else {
                // polls are a second apart, so each edge lands up to a second after the event
                if abs(s[0].0 - 1.6) > 0.8 || abs((s[0].1 ?? 0) - 7.6) > 0.8 { failures.append("the Zoom session should run from about 1 s to 7 s") }
                if abs(s[1].0 - 31.6) > 0.8 || s[1].1 != nil { failures.append("the Meet session should start about 31 s and still be on") }
            }
        }
    }
    RunLoop.main.add(check, forMode: .common)
}

RunLoop.main.run(until: Date().addingTimeInterval(41))

let names: [Sign: String] = [.call: "ON A CALL", .dnd: "DO NOT DISTURB", .free: "FREE"]
for (t, sign) in changes { print(String(format: "%5.2f s  %@", t, names[sign] ?? "?")) }
func expect(_ sign: Sign, between a: Double, and b: Double, _ what: String) {
    if !changes.contains(where: { $0.1 == sign && $0.0 >= a && $0.0 <= b }) { failures.append(what) }
}
expect(.call, between: 2.8, and: 3.3, "Zoom should light the sign 2 s after it takes the mic")
expect(.dnd, between: 16.8, and: 17.3, "when the call ends 10 s after Zoom lets go, Do Not Disturb should return")
expect(.free, between: 23.9, and: 25.2, "Do Not Disturb should run out at its original time, not be reset by the call")
/// A change that should follow an action at once: within 0.2 s of when it actually ran.
func expectAtOnce(_ sign: Sign, after key: String, _ what: String) {
    guard let t = actedAt[key] else { failures.append(what + " (the action never ran)"); return }
    expect(sign, between: t, and: t + 0.2, what)
}
expectAtOnce(.call, after: "force on", "Force ON A CALL should take effect at once")
expectAtOnce(.free, after: "automatic", "Automatic should return to FREE at once")
expectAtOnce(.dnd, after: "dnd on", "Do Not Disturb should come on at once")
expectAtOnce(.free, after: "dnd off", "turning Do Not Disturb off should return to FREE at once")
expect(.call, between: 32.8, and: 33.3, "Google Meet in a Chrome helper should count")
if changes.contains(where: { $0.1 == .call && $0.0 > 18 && $0.0 < 27.9 }) {
    failures.append("dictation, an Apple system process or a 1-second blip lit the sign")
}
let expected: [Sign] = [.free, .call, .dnd, .free, .call, .free, .dnd, .free, .call]
if changes.map(\.1) != expected {
    failures.append("expected " + expected.map { names[$0]! }.joined(separator: ", ")
                    + "; saw " + changes.map { names[$0.1]! }.joined(separator: ", "))
}
print(failures.isEmpty ? "\ndetector behaves as designed" : "\nFAILED:\n  " + failures.joined(separator: "\n  "))
exit(failures.isEmpty ? 0 : 1)
