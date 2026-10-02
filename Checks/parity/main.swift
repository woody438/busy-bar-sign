import Foundation

// Renders the moments simulator/tools/parity.js renders, as raw little-endian doubles.
let cases: [(BarState, BarState?, Double)] = [
    (.call, .free, 0.03), (.call, .free, 0.07), (.call, .free, 0.12), (.call, .free, 0.16),
    (.call, .free, 0.5), (.call, .free, 2.0), (.call, .free, 3.6), (.call, .free, 3.75),
    (.call, .free, 3.9), (.call, .free, 4.05), (.call, .free, 9.0),
    (.free, .call, 0.05), (.free, .call, 0.3), (.free, .call, 3.8), (.free, .call, 9.0),
    (.call, nil, 0.02), (.call, nil, 0.4),
    (.dnd, .free, 0.03), (.dnd, .free, 0.5), (.dnd, .free, 3.8), (.dnd, .free, 9.0),
    (.call, .dnd, 0.05), (.free, .dnd, 0.05), (.dnd, .call, 3.75), (.dnd, nil, 0.4)
]
let timer = BarTimer(left: 1234.4, h: 15, m: 2)
// the stacked layout, for small screens: every phase of a change, and each state settled
let stackedCases: [(BarState, BarState?, Double)] = [
    (.call, .free, 0.05), (.call, .free, 0.15), (.call, .free, 1.5), (.call, .free, 3.6),
    (.call, .free, 3.8), (.call, .free, 4.0), (.call, .free, 9.0),
    (.dnd, .call, 0.3), (.dnd, .call, 3.85), (.dnd, .call, 9.0), (.free, .dnd, 2.0), (.free, nil, 9.0)
]
// the calendar's states, each with the timer the app gives it (keep in step with parity.js)
let timers: [String: BarTimer] = [
    "soon": BarTimer(left: 461.2, h: 11, m: 0), "late": BarTimer(left: 80.4, h: 9, m: 45),
    "till": BarTimer(left: 0, h: 11, m: 0), "free": BarTimer(left: 4532.6, h: 12, m: 0),
    "dnd": BarTimer(left: 1234.4, h: 15, m: 2)
]
let calendarCases: [(BarState, BarState?, Double, String?)] = [
    (.meeting, .free, 2.0, "free"), (.meeting, .free, 3.75, "free"), (.meeting, .free, 9.0, "free"),
    (.call, .callIn, 9.0, "free"), (.call, .late, 0.05, "free"),
    (.callIn, .free, 0.5, "soon"), (.callIn, .free, 2.0, "soon"), (.callIn, .free, 3.75, "soon"), (.callIn, .free, 9.0, "soon"),
    (.busyIn, .free, 9.0, "soon"),
    (.late, .callIn, 2.0, "late"), (.late, .callIn, 3.75, "late"), (.late, .callIn, 9.0, "late"),
    (.late, .callIn, 9.4, "late"), (.late, .callIn, 10.2, "late"),
    (.freeTil, .call, 2.0, "till"), (.freeTil, .call, 3.9, "till"), (.freeTil, .call, 9.0, "till"), (.freeTil, .call, 2.0, nil),
    (.callTbc, .free, 2.0, "soon"), (.callTbc, .free, 9.0, "soon"), (.callTbc, .free, 9.0, "till"),
    (.busyTbc, .free, 9.0, "till"),
    (.away, .free, 2.0, nil), (.away, .free, 9.0, nil), (.lunch, .away, 2.0, nil), (.lunch, .away, 3.75, nil), (.lunch, nil, 9.0, nil),
    (.ooo, .free, 2.0, nil), (.ooo, .free, 3.8, nil), (.ooo, .free, 9.0, nil)
]
let stackedCalendarCases: [(BarState, BarState?, Double, String?)] = [
    (.meeting, .free, 2.0, "free"), (.meeting, .free, 9.0, "free"), (.callIn, .free, 2.0, "soon"), (.callIn, .free, 3.8, "soon"),
    (.late, .callIn, 2.0, "late"), (.late, .callIn, 9.3, "late"), (.freeTil, .call, 2.0, "till"), (.freeTil, .call, 9.0, "till"),
    (.callTbc, .free, 2.0, "till"), (.busyTbc, .free, 9.0, "soon"), (.lunch, .free, 2.0, nil), (.ooo, .free, 2.0, nil),
    (.ooo, .free, 9.0, nil), (.away, .free, 2.0, nil)
]
let clock = ClockReading(h: 14, m: 32, s: 27, ms: 200, dow: 2, date: 30)
var out = Data()
for (state, prev, e) in cases {
    var f = LEDFrame()
    let since = 1000.0
    BarEngine.render(into: &f, now: since + e, state: state, prev: prev, since: since, clock: clock, timer: timer)
    f.px.withUnsafeBytes { out.append(contentsOf: $0) }
}
for (state, prev, e) in stackedCases {
    var f = LEDFrame(w: BarEngine.Stacked.cols, h: BarEngine.Stacked.rows)
    let since = 1000.0
    BarEngine.renderStacked(into: &f, now: since + e, state: state, prev: prev, since: since, clock: clock, timer: timer)
    f.px.withUnsafeBytes { out.append(contentsOf: $0) }
}
for (state, prev, e, key) in calendarCases {
    var f = LEDFrame()
    let since = 1000.0
    BarEngine.render(into: &f, now: since + e, state: state, prev: prev, since: since, clock: clock,
                     timer: key.flatMap { timers[$0] })
    f.px.withUnsafeBytes { out.append(contentsOf: $0) }
}
for (state, prev, e, key) in stackedCalendarCases {
    var f = LEDFrame(w: BarEngine.Stacked.cols, h: BarEngine.Stacked.rows)
    let since = 1000.0
    BarEngine.renderStacked(into: &f, now: since + e, state: state, prev: prev, since: since, clock: clock,
                            timer: key.flatMap { timers[$0] })
    f.px.withUnsafeBytes { out.append(contentsOf: $0) }
}
try! out.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("frames:", cases.count + stackedCases.count + calendarCases.count + stackedCalendarCases.count, "bytes:", out.count)
