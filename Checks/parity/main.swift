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
    (.ooo, .free, 2.0, nil), (.ooo, .free, 3.8, nil), (.ooo, .free, 9.0, nil),
    (.callMuted, .call, 9.0, "free"), (.callMuted, .free, 2.0, "free"), (.callMuted, .free, 3.75, "free"),
    (.callMuted, nil, 9.0, nil), (.call, .callMuted, 0.05, "free"),
    // the muted mic's slow flash: fading out, off, fading back
    (.callMuted, nil, 9.2, nil), (.callMuted, nil, 9.5, nil), (.callMuted, .call, 9.9, "free"),
    // the away keys: NEARBY alone in its pill, BACK IN counting down (an hour and more: 1H15)
    (.nearby, .free, 2.0, nil), (.nearby, .free, 3.75, nil), (.nearby, nil, 9.0, nil),
    (.backIn, .nearby, 2.0, "soon"), (.backIn, .nearby, 3.75, "soon"), (.backIn, .free, 9.0, "soon"),
    (.backIn, .lunch, 9.0, "free"), (.call, .backIn, 0.05, "free"),
    // a meeting in a room started without you, breathing as LATE does; out on site with a client
    (.lateMtg, .busyIn, 2.0, "late"), (.lateMtg, .busyIn, 3.75, "late"), (.lateMtg, .busyIn, 9.0, "late"),
    (.lateMtg, .busyIn, 9.4, "late"), (.meeting, .lateMtg, 0.05, "free"),
    (.onSite, .free, 2.0, nil), (.onSite, .free, 3.8, nil), (.onSite, .free, 9.0, nil),
    // lunch from the calendar: a countdown to when you're back
    (.lunch, .free, 3.75, "free"), (.lunch, .meeting, 9.0, "soon"),
    // FREE a quarter of an hour on: the icon and word scroll out to the left and back in from the
    // right (and not after it, or a call); the next quarter's; and the other quiet states'
    (.free, .call, 904.467, nil), (.free, .call, 905.067, nil), (.free, .call, 905.667, nil), (.free, .call, 906.267, nil),
    (.free, .call, 907.0, nil), (.call, .free, 905.067, "free"), (.free, .call, 1804.767, nil),
    (.nearby, nil, 905.0, nil), (.ooo, .free, 906.0, nil), (.lunch, .free, 905.5, "free")
]
let stackedCalendarCases: [(BarState, BarState?, Double, String?)] = [
    (.meeting, .free, 2.0, "free"), (.meeting, .free, 9.0, "free"), (.callIn, .free, 2.0, "soon"), (.callIn, .free, 3.8, "soon"),
    (.late, .callIn, 2.0, "late"), (.late, .callIn, 9.3, "late"), (.freeTil, .call, 2.0, "till"), (.freeTil, .call, 9.0, "till"),
    (.callTbc, .free, 2.0, "till"), (.busyTbc, .free, 9.0, "soon"), (.lunch, .free, 2.0, nil), (.ooo, .free, 2.0, nil),
    (.ooo, .free, 9.0, nil), (.away, .free, 2.0, nil), (.callMuted, .free, 2.0, "free"), (.callMuted, .call, 9.0, "free"),
    (.callMuted, .call, 9.5, "free"),
    (.nearby, .free, 2.0, nil), (.nearby, .free, 3.8, nil), (.nearby, .free, 9.0, nil),
    (.backIn, .free, 2.0, "soon"), (.backIn, .free, 9.0, "soon"),
    (.lateMtg, .busyIn, 2.0, "late"), (.lateMtg, .busyIn, 9.3, "late"), (.onSite, .free, 2.0, nil), (.onSite, .free, 9.0, nil),
    (.lunch, .free, 9.0, "free"),
    // the scroll, stacked
    (.free, .call, 904.767, nil), (.free, .call, 905.967, nil), (.onSite, .free, 905.3, nil)
]
// the Nearby key's own word, through each way of fitting it: as it is; stacked a step
// tighter; the announcement in the status face, stacked in it too; stacked on two lines
// (keep in step with parity.js)
let nearbyCases: [(String, stacked: Bool, Double)] = [
    ("W HOUSE", false, 2.0), ("W HOUSE", false, 3.75), ("W HOUSE", false, 9.0),
    ("W HOUSE", true, 2.0), ("W HOUSE", true, 3.8), ("W HOUSE", true, 9.0),
    ("STUDIO 2", false, 2.0), ("STUDIO 2", true, 2.0),
    ("1111111111", false, 2.0), ("1111111111", false, 3.75), ("1111111111", true, 2.0),
    ("1111 1111", true, 2.0), ("1111 1111", true, 3.8)
]
// the words the sign takes for the Nearby key, as engine.js takes them (keep in step with parity.js)
let nearbyWords: [(String?, String)] = [
    (nil, "NEARBY"), ("", "NEARBY"), ("  w   house ", "W HOUSE"), ("Studio 2", "STUDIO 2"), ("kitchen", "KITCHEN"),
    ("WAREHOUSE", "NEARBY"), ("UPSTAIRS", "NEARBY"), ("Café", "NEARBY"), ("✈ AWAY", "NEARBY"), ("1111111111..", "1111111111..")
]
for (word, takes) in nearbyWords where BarEngine.nearbyWordOf(word) != takes {
    FileHandle.standardError.write(Data("the sign takes \(String(describing: word)) as \(BarEngine.nearbyWordOf(word)), not \(takes)\n".utf8))
    exit(1)
}
let problems: [(String, BarEngine.NearbyProblem?)] = [
    ("W HOUSE", nil), ("WAREHOUSE", .sign), ("UPSTAIRS", .key), ("café", .characters)
]
for (word, problem) in problems where BarEngine.nearbyProblem(word) != problem {
    FileHandle.standardError.write(Data("\(word): \(String(describing: BarEngine.nearbyProblem(word))), not \(String(describing: problem))\n".utf8))
    exit(1)
}
// how bright the LEDs are: dimmed only after half an hour of a quiet state (keep in step with parity.js)
let rests: [(BarState, Double, Double)] = [
    (.free, 0, 1), (.free, 1800, 1), (.free, 1815, 0.86), (.free, 1830, 0.83), (.nearby, 7200, 0.83),
    (.call, 7200, 1), (.dnd, 7200, 1), (.callIn, 7200, 1)
]
for (state, e, level) in rests where BarEngine.restAt(1000 + e, state, since: 1000) != level {
    FileHandle.standardError.write(Data("\(state) at \(e) s rests at \(BarEngine.restAt(1000 + e, state, since: 1000)), not \(level)\n".utf8))
    exit(1)
}
let clock = ClockReading(h: 14, m: 32, s: 27, ms: 200, dow: 2, date: 30)
// world clocks: two plans through each phase (keep in step with parity.js)
let worldZones = [
    BarEngine.WorldZone(code: "LON", h: 14, m: 32, dow: 2, date: 30, dayDelta: 0),
    BarEngine.WorldZone(code: "NYC", h: 9, m: 32, dow: 2, date: 30, dayDelta: 0),
    BarEngine.WorldZone(code: "TYO", h: 23, m: 32, dow: 2, date: 30, dayDelta: 0),
    BarEngine.WorldZone(code: "SYD", h: 0, m: 32, dow: 3, date: 31, dayDelta: 1)
]
var worldAll = BarEngine.WorldPlan()
worldAll.zones = worldZones
worldAll.turns = .init(on: true, secs: 5)
worldAll.rest = .init(on: true, mins: 30)
worldAll.board = .init(on: true, mins: 5, secs: 20)
worldAll.ticker = .init(on: true, mins: 15)
worldAll.rules = .init(restHolds: true, clash: .wait, tickerForScroll: true)
var worldPlain = worldAll
worldPlain.turns = .init(on: false, secs: 5)
worldPlain.rest = .init(on: true, mins: 60)
worldPlain.board = .init(on: true, mins: 7, secs: 20)
worldPlain.ticker = .init(on: true, mins: 21)
worldPlain.rules = .init(restHolds: false, clash: .skip, tickerForScroll: false)
// fewer cities (a clock set to None): the layouts close up around the ones left
var worldTwo = worldAll
worldTwo.zones = [worldZones[0], worldZones[3]]
var worldThree = worldAll
worldThree.zones = [worldZones[0], worldZones[1], worldZones[3]]
let worldPlans = ["all": worldAll, "plain": worldPlain, "two": worldTwo, "three": worldThree]
let worldCases: [(stacked: Bool, String, Double)] = [
    (false, "all", 2.167), (false, "all", 3.867), (false, "all", 9.167), (false, "all", 9.367), (false, "all", 304.417),
    (false, "all", 309.167), (false, "all", 324.917), (false, "all", 904.767), (false, "all", 907.167), (false, "all", 917.167),
    (false, "all", 1804.567), (false, "all", 1806.167),
    (false, "plain", 2.167), (false, "plain", 9.167), (false, "plain", 424.417), (false, "plain", 904.767),
    (false, "plain", 1264.767), (false, "plain", 1267.167), (false, "plain", 1280.167), (false, "plain", 3604.667),
    (false, "plain", 3784.417), (false, "plain", 3794.167),
    (true, "all", 2.167), (true, "all", 3.867), (true, "all", 9.167), (true, "all", 9.367),
    (true, "all", 304.417), (true, "all", 309.167), (true, "all", 904.767), (true, "all", 907.167),
    (true, "all", 1804.567), (true, "all", 1806.167),
    (true, "plain", 9.167), (true, "plain", 904.767), (true, "plain", 3604.667), (true, "plain", 3784.417),
    (false, "two", 9.367), (false, "two", 309.167), (false, "two", 907.167), (false, "two", 1806.167),
    (false, "three", 309.167), (false, "three", 1806.167),
    (true, "two", 9.367), (true, "two", 309.167), (true, "two", 1806.167),
    (true, "three", 309.167), (true, "three", 1806.167)
]
// ...and as a call starts: how long FREE had been up
let worldPresses: [(stacked: Bool, String, Double)] = [(false, "all", 9.367), (false, "plain", 9.167), (true, "all", 9.367)]
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
for (word, stacked, e) in nearbyCases {
    BarEngine.setNearbyWord(word)
    let since = 1000.0
    var f: LEDFrame
    if stacked {
        f = LEDFrame(w: BarEngine.Stacked.cols, h: BarEngine.Stacked.rows)
        BarEngine.renderStacked(into: &f, now: since + e, state: .nearby, prev: .free, since: since, clock: clock)
    } else {
        f = LEDFrame()
        BarEngine.render(into: &f, now: since + e, state: .nearby, prev: .free, since: since, clock: clock)
    }
    f.px.withUnsafeBytes { out.append(contentsOf: $0) }
}
BarEngine.setNearbyWord(nil)
for (stacked, plan, e) in worldCases {
    let since = 1000.0, world = worldPlans[plan]!
    var f = stacked ? LEDFrame(w: BarEngine.Stacked.cols, h: BarEngine.Stacked.rows) : LEDFrame()
    if stacked {
        BarEngine.renderStackedWorld(into: &f, now: since + e, state: .free, prev: .call, since: since, clock: clock, timer: nil,
                                     world: world, prevFor: 0)
    } else {
        BarEngine.renderWorld(into: &f, now: since + e, state: .free, prev: .call, since: since, clock: clock, timer: nil,
                              world: world, prevFor: 0)
    }
    f.px.withUnsafeBytes { out.append(contentsOf: $0) }
}
for (stacked, plan, up) in worldPresses {
    let since = 1000.0, world = worldPlans[plan]!
    var f = stacked ? LEDFrame(w: BarEngine.Stacked.cols, h: BarEngine.Stacked.rows) : LEDFrame()
    if stacked {
        BarEngine.renderStackedWorld(into: &f, now: since + 0.05, state: .call, prev: .free, since: since, clock: clock, timer: timer,
                                     world: world, prevFor: up)
    } else {
        BarEngine.renderWorld(into: &f, now: since + 0.05, state: .call, prev: .free, since: since, clock: clock, timer: timer,
                              world: world, prevFor: up)
    }
    f.px.withUnsafeBytes { out.append(contentsOf: $0) }
}
try! out.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("frames:", cases.count + stackedCases.count + calendarCases.count + stackedCalendarCases.count + nearbyCases.count
      + worldCases.count + worldPresses.count,
      "bytes:", out.count)
