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
exit(worst < 8 && fits4K ? 0 : 1)
