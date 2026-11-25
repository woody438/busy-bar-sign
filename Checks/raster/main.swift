import Foundation
// Times the engine and rasteriser at 4K pitch. The display refreshes every
// 16.7 ms; a frame has to fit comfortably inside that.
let clock = ClockReading(h: 14, m: 32, s: 27, ms: 200, dow: 2, date: 30)
let raster = LEDRaster(pitch: 32)
var f = LEDFrame()
func time(_ label: String, _ n: Int, _ body: (Int) -> Void) -> Double {
    let t0 = Date(); for i in 0..<n { body(i) }
    let ms = Date().timeIntervalSince(t0) / Double(n) * 1000
    print(label.padding(toLength: 38, withPad: " ", startingAt: 0), String(format: "%6.2f ms", ms))
    return ms
}
let steady = time("steady (engine + raster)", 240) { i in
    BarEngine.render(into: &f, now: 1060 + Double(i) / 60, state: .call, prev: .free, since: 1000, clock: clock)
    raster.render(f)
}
let change = time("state change (engine + raster)", 264) { i in
    BarEngine.render(into: &f, now: 1000 + Double(i % 264) / 60, state: .call, prev: .free, since: 1000, clock: clock)
    raster.render(f)
}
// The stacked layout, for small screens: at 960 x 540 (11 px LEDs) and at
// 1080p (22 px), held to the same budget.
func stackedTime(_ label: String, pitch: Int, frames: Int) -> Double {
    let r = LEDRaster(pitch: pitch, cols: 84, rows: 44)
    var sf = LEDFrame(w: 84, h: 44)
    return time(label, frames) { i in
        BarEngine.renderStacked(into: &sf, now: 1000 + Double(i % 264) / 60, state: .call, prev: .free, since: 1000, clock: clock)
        r.render(sf)
    }
}
let stackedSmall = stackedTime("stacked, 960x540 (engine + raster)", pitch: 11, frames: 264)
let stacked1080 = stackedTime("stacked, 1080p (engine + raster)", pitch: 22, frames: 264)
let worst = max(steady, change, stackedSmall, stacked1080)
print(worst < 8 ? "\nfast enough (worst \(String(format: "%.1f", worst)) ms of a 16.7 ms frame)" : "\nTOO SLOW")

// Stacked on a 4K screen — not what it's for, but allowed — draws 7 million
// pixels at 44 px per LED. Settled, only the LEDs that change are redrawn;
// in the first two seconds of a change (the shockwave and the announcement)
// nearly every LED changes each frame, so a slower Mac may dip below 60 fps
// then. It must never fall below 30.
let stacked4K = stackedTime("stacked, 4K, during a change", pitch: 44, frames: 132)
let fits4K = stacked4K < 33.3
print(fits4K ? "stacked at 4K keeps above 30 fps during a change (\(String(format: "%.1f", stacked4K)) ms)"
             : "stacked at 4K TOO SLOW: below 30 fps during a change")

/*
 * When the panel draws (PanelSchedule), against drawing every frame as it
 * did before 2.8.8. The panel's own schedule runs on a simulated clock: on
 * every display frame while something moves, else at the next turn of the
 * clock or the next thing to move; a frame whose LEDs match what's on the
 * screen isn't drawn; one that differs goes into one of three buffers in turn
 * (as LEDPanelView's IOSurfaces), only its changed LEDs drawn. At every
 * display frame, what the panel shows must be what drawing every frame
 * showed — or, at a turn, what it showed a frame before (the panel wakes a
 * millisecond after the turn, the display link at the frame after it).
 */
struct Scenario {
    let name: String, state: BarState, prev: BarState?, from: Double, seconds: Double
    var layout = BarLayout.wide, pitch = 32
    var moment: (Double, BarMoment.Kind)? = nil      // seconds from the start, kind
    var slot: (Double, Double)? = nil                // the time-left rail's meeting: start and end, seconds from the start
    var camera = BarCamera.off                       // a camera in the call: its cue, and stacked, its dot
}
let scenarios = [
    // a camera in the call: CAMERA ON announced, then the stacked layout's dot breathing, and steady while muted
    Scenario(name: "CAMERA ON, announced", state: .call, prev: .call, from: 0, seconds: 10, moment: (1800.37, .countdown),
             camera: BarCamera(on: true, cue: .cameraOn)),
    Scenario(name: "CAMERA OFF, announced, stacked", state: .call, prev: .call, from: 0, seconds: 10, layout: .stacked, pitch: 11,
             moment: (1800.37, .countdown), camera: BarCamera(on: false, cue: .cameraOff)),
    Scenario(name: "ON A CALL, camera on, stacked (the dot)", state: .call, prev: .call, from: 300, seconds: 12, layout: .stacked,
             pitch: 11, moment: (1234.567, .countdown), camera: BarCamera(on: true, cue: .cameraOn)),
    Scenario(name: "ON A CALL, muted, camera on, stacked", state: .callMuted, prev: .call, from: 300, seconds: 12, layout: .stacked,
             pitch: 11, moment: (1234.567, .countdown), camera: BarCamera(on: true)),
    Scenario(name: "FREE, settled", state: .free, prev: .call, from: 600, seconds: 30),
    Scenario(name: "FREE, resting (after half an hour)", state: .free, prev: .call, from: 2400, seconds: 30),
    Scenario(name: "FREE, easing down to rest", state: .free, prev: .call, from: 1795, seconds: 30),
    Scenario(name: "FREE, the quarter-hour scroll", state: .free, prev: .call,
             from: BarEngine.Timing.settled + BarEngine.Scroll.every - 4, seconds: 10),
    Scenario(name: "A change: FREE to ON A CALL", state: .call, prev: .free, from: 0, seconds: 10, moment: (1800.37, .countdown)),
    Scenario(name: "ON A CALL, counting down", state: .call, prev: .free, from: 300, seconds: 20, moment: (1234.567, .countdown)),
    Scenario(name: "ON A CALL, muted", state: .callMuted, prev: .call, from: 300, seconds: 20, moment: (1234.567, .countdown)),
    Scenario(name: "LATE FOR CALL", state: .late, prev: .callIn, from: 300, seconds: 10, moment: (-80.25, .countUp)),
    Scenario(name: "DND", state: .dnd, prev: .free, from: 60, seconds: 20, moment: (1739.81, .countdown)),
    Scenario(name: "CALL IN, counting down", state: .callIn, prev: .free, from: 30, seconds: 20, moment: (451.2, .countdown)),
    Scenario(name: "AWAY", state: .away, prev: .free, from: 600, seconds: 20),
    Scenario(name: "FREE, stacked on 960 x 540", state: .free, prev: .call, from: 600, seconds: 20, layout: .stacked, pitch: 11),
    Scenario(name: "FREE, stacked, resting", state: .free, prev: .call, from: 2400, seconds: 20, layout: .stacked, pitch: 11),
    Scenario(name: "AWAY, resting", state: .away, prev: .free, from: 2400, seconds: 20),
    Scenario(name: "FREE, resting, the scroll", state: .free, prev: .call,
             from: BarEngine.Timing.settled + 2 * BarEngine.Scroll.every - 4, seconds: 10),
    // the time-left rail on its meeting's seconds (out of step with the moment's and the clock's), the
    // last two minutes' sweep, and CALL SOON's big countdown, as they start and once they've started
    Scenario(name: "ON A CALL, the time-left rail", state: .call, prev: .free, from: 300, seconds: 20,
             moment: (1234.567, .countdown), slot: (-1765.2, 834.81)),
    Scenario(name: "ON A CALL, its last two minutes", state: .call, prev: .free, from: 300, seconds: 12,
             moment: (1234.567, .countdown), slot: (-1700.4, 95.43)),
    Scenario(name: "MEETING, into its last two minutes", state: .meeting, prev: .free, from: 300, seconds: 10,
             moment: (2000.1, .countdown), slot: (-1500.6, 125.3)),
    Scenario(name: "CALL IN, the big countdown", state: .callIn, prev: .free, from: 30, seconds: 20,
             moment: (101.2, .countdown)),
    Scenario(name: "CALL IN, into its last two minutes", state: .callIn, prev: .free, from: 30, seconds: 10,
             moment: (124.7, .countdown)),
    Scenario(name: "MEETING, stacked, the sweep", state: .meeting, prev: .free, from: 300, seconds: 10,
             layout: .stacked, pitch: 11, moment: (900.3, .countdown), slot: (-1700.2, 100.4)),
    Scenario(name: "CALL IN, stacked, the sweep", state: .callIn, prev: .free, from: 30, seconds: 10,
             layout: .stacked, pitch: 11, moment: (100.6, .countdown)),
]

/// What drawing every frame cost before 2.8.8: engine, raster, and the frame copied into an image.
func everyFrameCost(pitch: Int, layout: BarLayout) -> Double {
    let r = LEDRaster(pitch: pitch, cols: layout.cols, rows: layout.rows)
    var f = LEDFrame(w: layout.cols, h: layout.rows)
    let c = ClockReading(Date(timeIntervalSince1970: 1_763_470_000))
    return time("  (every frame, as before)", 600) { i in
        let now = 1600 + Double(i) / 60
        if layout == .wide { BarEngine.render(into: &f, now: now, state: .free, prev: .call, since: 1000, clock: c) }
        else { BarEngine.renderStacked(into: &f, now: now, state: .free, prev: .call, since: 1000, clock: c) }
        r.render(f)
        let copy = Data(bytes: r.pixels.baseAddress!, count: r.bytesPerRow * r.height)
        _ = r.glow(f)
        precondition(copy.count > 0)
    }
}

print("\n== when the panel draws (60 Hz display; ms of CPU a second, engine and raster, here)")
var scheduleFailures: [String] = []
let wall0 = 1_763_470_000.3721                 // the wall clock's whole seconds fall between display frames
for sc in scenarios {
    let cols = sc.layout.cols, rows = sc.layout.rows
    let raster = LEDRaster(pitch: sc.pitch, cols: cols, rows: rows, bgra: true)
    let since = 5000.0, t0 = since + sc.from, end = t0 + sc.seconds
    let moment = sc.moment.map { m in
        BarMoment(at: Date(timeIntervalSince1970: wall0 + t0 + m.0), kind: m.1,
                  slot: sc.slot.map { DateInterval(start: Date(timeIntervalSince1970: wall0 + t0 + $0.0),
                                                   end: Date(timeIntervalSince1970: wall0 + t0 + $0.1)) })
    }
    let rests = true                                    // the wall's, wide or stacked
    var frame = LEDFrame(w: cols, h: rows)
    func keysAt(_ t: Double, into out: UnsafeMutableBufferPointer<UInt64>) {
        let date = Date(timeIntervalSince1970: wall0 + t)
        let timer = moment?.timer(at: date), clock = ClockReading(date)
        if sc.layout == .wide {
            BarEngine.render(into: &frame, now: t, state: sc.state, prev: sc.prev, since: since, clock: clock, timer: timer,
                             rests: rests, camera: sc.camera)
        } else {
            BarEngine.renderStacked(into: &frame, now: t, state: sc.state, prev: sc.prev, since: since, clock: clock, timer: timer,
                                    rests: rests, camera: sc.camera)
        }
        raster.keys(frame, dim: rests ? BarEngine.restAt(t, sc.state, since: since) : 1, into: out)
    }
    // the panel: its buffers, what's on the screen, and its clock
    let pitchBytes = raster.width * 4
    let buffers = (0..<3).map { _ in UnsafeMutableRawPointer.allocate(byteCount: pitchBytes * raster.height, alignment: 16) }
    let canvases = (0..<3).map { _ in LEDRaster.Canvas(leds: cols * rows) }
    var front = -1, nextBuffer = 0
    let wanted = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: cols * rows)
    var ticks = 0, drawn = 0, leds = 0, work = 0.0
    // drawing every frame, for comparison
    let now = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: cols * rows)
    let before = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: cols * rows)
    before.initialize(repeating: .max)
    var mismatches = 0, firstMismatch = -1.0
    let phase = t0 + 0.0041                                 // the display's frames, out of step with the clock
    func vsyncTime(_ n: Int) -> Double { phase + Double(n) / 60 }
    var tick = t0, frameNo = 0
    while vsyncTime(frameNo) < end {
        let vsync = vsyncTime(frameNo)
        // the panel's ticks up to this display frame
        while tick <= vsync {
            let start = Date()
            keysAt(tick, into: wanted)
            ticks += 1
            if front < 0 || !canvases[front].shows(UnsafeBufferPointer(wanted)) {
                let b = nextBuffer
                nextBuffer = (nextBuffer + 1) % 3
                leds += raster.render(keys: UnsafeBufferPointer(wanted), into: canvases[b], base: buffers[b], bytesPerRow: pitchBytes)
                front = b
                drawn += 1
            }
            let date = Date(timeIntervalSince1970: wall0 + tick)
            let delay = PanelSchedule.delay(now: tick, date: date, state: sc.state, since: since, layout: sc.layout,
                                            rests: rests, moment: moment, world: false, camera: sc.camera.on)
            work += Date().timeIntervalSince(start)
            if let delay {
                tick += delay
            } else {
                // the display link: the first display frame after this tick
                var n = max(0, Int(((tick - phase) * 60).rounded(.down)))
                while vsyncTime(n) <= tick { n += 1 }
                tick = vsyncTime(n)
            }
        }
        // what drawing every frame shows at this display frame
        keysAt(vsync, into: now)
        if !canvases[front].shows(UnsafeBufferPointer(now)) && !canvases[front].shows(UnsafeBufferPointer(before)) {
            mismatches += 1
            if firstMismatch < 0 { firstMismatch = vsync - since }
        }
        before.baseAddress!.update(from: now.baseAddress!, count: now.count)
        frameNo += 1
    }
    // a buffer drawn a changed LED at a time is the frame drawn whole
    let afresh = LEDRaster(pitch: sc.pitch, cols: cols, rows: rows, bgra: true)
    let fresh = LEDRaster.Canvas(leds: cols * rows)
    let check = UnsafeMutableRawPointer.allocate(byteCount: pitchBytes * raster.height, alignment: 16)
    let same = withExtendedLifetime(canvases) {             // its keys live as long as it does
        afresh.render(keys: UnsafeBufferPointer(canvases[front].keys), into: fresh, base: check, bytesPerRow: pitchBytes)
        return memcmp(check, buffers[front], pitchBytes * raster.height) == 0
    }
    if !same {
        scheduleFailures.append("\(sc.name): the buffer on the screen isn't the frame drawn whole")
    }
    if mismatches > 0 {
        scheduleFailures.append("\(sc.name): \(mismatches) display frames differ from drawing every frame (first \(String(format: "%.3f", firstMismatch)) s in)")
    }
    let secs = sc.seconds
    print(sc.name.padding(toLength: 38, withPad: " ", startingAt: 0),
          String(format: "%5.1f wakes/s, %5.1f drawn/s, %5.1f idle/s, %6.0f LEDs/s, %5.1f ms/s",
                 Double(ticks) / secs, Double(drawn) / secs, Double(ticks - drawn) / secs, Double(leds) / secs,
                 work / secs * 1000))
    buffers.forEach { $0.deallocate() }
    check.deallocate(); wanted.deallocate(); now.deallocate(); before.deallocate()
}
let wideBefore = everyFrameCost(pitch: 32, layout: .wide)
print(String(format: "  before 2.8.8 the panel drew 60 frames a second whatever was on it: %.0f ms/s for the wide bar at 4K,", wideBefore * 60))
print("  and handed Core Animation a new 7.7 MB image each time")
for f in scheduleFailures { print("FAIL", f) }
print(scheduleFailures.isEmpty ? "the panel shows what drawing every frame showed, at every display frame" : "\(scheduleFailures.count) schedule checks failed")
exit(worst < 8 && fits4K && scheduleFailures.isEmpty ? 0 : 1)
