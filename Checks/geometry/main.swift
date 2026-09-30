import Foundation
// Checks BarGeometry puts the LED field on whole device pixels on common displays.
// (description, points wide, points high, backing scale)
let screens: [(String, CGFloat, CGFloat, CGFloat)] = [
    ("4K, default HiDPI (looks like 1920x1080)", 1920, 1080, 2),
    ("4K, native 1x", 3840, 2160, 1),
    ("4K, 'looks like 2560x1440' (scaled)", 2560, 1440, 2),
    ("1440p 27in, 1x", 2560, 1440, 1),
    ("1080p, 1x", 1920, 1080, 1),
    ("5K Studio Display, 2x", 2560, 1440, 2),
    ("Ultrawide 3440x1440, 1x", 3440, 1440, 1),
    ("6K Pro Display XDR, 2x", 3008, 1692, 2),
]
var ok = true
for (name, w, h, s) in screens {
    let g = BarGeometry(size: CGSize(width: w, height: h), scale: s)
    let fieldPxW = g.field.width * s, fieldPxH = g.field.height * s
    let aligned = [g.field.minX * s, g.field.minY * s, fieldPxW, fieldPxH].allSatisfy { abs($0 - $0.rounded()) < 1e-6 }
    let exact = abs(fieldPxW - CGFloat(118 * g.pitchPixels)) < 1e-6 && abs(fieldPxH - CGFloat(16 * g.pitchPixels)) < 1e-6
    let fits = g.field.minX >= 0 && g.field.maxX <= w && g.field.minY >= 0 && g.field.maxY <= h
    let caseW = BarGeometry.screenUnits * g.u
    let height = (BarGeometry.caseHeight + BarGeometry.controlsHeight) * g.u
    let line = String(format: "%-44@ pitch %2d px  bar %4.0f of %4.0f pt wide (%3.0f%%)  %4.1f%% tall  aligned:%@ exact:%@ fits:%@",
                      name as NSString, g.pitchPixels, caseW, w, caseW / w * 100, height / h * 100,
                      aligned ? "yes" : "NO", exact ? "yes" : "NO", fits ? "yes" : "NO")
    print(line)
    if !(aligned && exact && fits) { ok = false }
}
print(ok ? "\nall layouts pixel-exact" : "\nLAYOUT PROBLEMS ABOVE")
exit(ok ? 0 : 1)
