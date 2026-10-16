import Foundation

// Checks AwayState: what a press of the Nearby, Lunch and Back In keys
// does, and when Back In's time is up.
var failures: [String] = []
func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

let t0 = Date(timeIntervalSince1970: 1_760_000_000)
let minute = 60.0

// Nearby and Lunch: on, then off
var s = AwayState()
s.press(.nearby, at: t0)
expect(s == AwayState(kind: .nearby, until: nil), "Nearby goes on")
s.press(.nearby, at: t0)
expect(s == AwayState(), "…and off again")
s.press(.lunch, at: t0)
expect(s.kind == .lunch, "Lunch goes on")
s.press(.nearby, at: t0)
expect(s == AwayState(kind: .nearby, until: nil), "Nearby takes over from Lunch")

// Back In: ten minutes, and ten more a press
s = AwayState()
s.press(.backIn, at: t0)
expect(s == AwayState(kind: .backIn, until: t0 + 10 * minute), "Back In: ten minutes")
s.press(.backIn, at: t0 + 5)
s.press(.backIn, at: t0 + 6)
expect(s.until == t0 + 30 * minute, "three presses: half an hour from the first")
s.press(.backIn, at: t0 + 45 * minute)
expect(s.until == t0 + 55 * minute, "pressed after it's run out: ten minutes from then")
s = AwayState(kind: .lunch, until: nil)
s.press(.backIn, at: t0)
expect(s == AwayState(kind: .backIn, until: t0 + 10 * minute), "Back In takes over from Lunch")
s.press(.lunch, at: t0)
expect(s == AwayState(kind: .lunch, until: nil), "…and Lunch from Back In")
s = AwayState()
for _ in 0..<100 { s.press(.backIn, at: t0) }
expect(s.until == t0 + AwayState.most, "no further ahead than a working day")

// Back In's time is up
s = AwayState(kind: .backIn, until: t0 + 10 * minute)
s.expire(at: t0 + 10 * minute - 1)
expect(s.kind == .backIn, "not up a second early")
s.expire(at: t0 + 10 * minute)
expect(s == AwayState(), "up on time")
s = AwayState(kind: .backIn, until: nil)
s.expire(at: t0)
expect(s == AwayState(), "Back In with no time is nothing")
s = AwayState(kind: .lunch, until: nil)
s.expire(at: t0 + 600 * minute)
expect(s.kind == .lunch, "Lunch has no time to run out")

for f in failures { print("FAIL", f) }
print(failures.isEmpty ? "away keys press and run out as designed" : "\(failures.count) away checks failed")
exit(failures.isEmpty ? 0 : 1)
