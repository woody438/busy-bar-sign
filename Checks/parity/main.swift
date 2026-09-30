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
let timer = DNDTimer(left: 1234.4, h: 15, m: 2)
// the stacked layout, for small screens: every phase of a change, and each state settled
let stackedCases: [(BarState, BarState?, Double)] = [
    (.call, .free, 0.05), (.call, .free, 0.15), (.call, .free, 1.5), (.call, .free, 3.6),
    (.call, .free, 3.8), (.call, .free, 4.0), (.call, .free, 9.0),
    (.dnd, .call, 0.3), (.dnd, .call, 3.85), (.dnd, .call, 9.0), (.free, .dnd, 2.0), (.free, nil, 9.0)
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
try! out.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("frames:", cases.count + stackedCases.count, "bytes:", out.count)
