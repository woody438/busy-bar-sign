import Foundation
// Times the engine and rasteriser at 4K pitch. The display refreshes every
// 16.7 ms; a frame has to fit comfortably inside that.
let clock = ClockReading(h: 14, m: 32, s: 27, ms: 200, dow: 2, date: 30)
let raster = LEDRaster(pitch: 32)
var f = LEDFrame()
func time(_ label: String, _ n: Int, _ body: (Int) -> Void) -> Double {
    let t0 = Date(); for i in 0..<n { body(i) }
    let ms = Date().timeIntervalSince(t0) / Double(n) * 1000
    print(label.padding(toLength: 30, withPad: " ", startingAt: 0), String(format: "%6.2f ms", ms))
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
let worst = max(steady, change)
print(worst < 8 ? "\nfast enough (worst \(String(format: "%.1f", worst)) ms of a 16.7 ms frame)" : "\nTOO SLOW")
exit(worst < 8 ? 0 : 1)
