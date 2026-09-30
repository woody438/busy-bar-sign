import Foundation
#if canImport(CoreGraphics)
import CoreGraphics      // CGRect's initialisers live here on macOS
#endif
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
    // the floating window's sizes: device width x (width * 672/3840)
    ("Floating small, 2x", 600, 105, 2),
    ("Floating small, 1x", 600, 105, 1),
    ("Floating medium, 2x", 900, 158, 2),
    ("Floating medium, 1x", 900, 158, 1),
    ("Floating large, 2x", 1200, 210, 2),
    ("Floating large, 1x", 1200, 210, 1),
]
var ok = true
for (name, w, h, s) in screens {
    let g = BarGeometry(size: CGSize(width: w, height: h), scale: s)
    let fieldPxW = g.field.width * s, fieldPxH = g.field.height * s
    let aligned = [g.field.minX * s, g.field.minY * s, fieldPxW, fieldPxH].allSatisfy { abs($0 - $0.rounded()) < 1e-6 }
    let exact = abs(fieldPxW - CGFloat(118 * g.pitchPixels)) < 1e-6 && abs(fieldPxH - CGFloat(16 * g.pitchPixels)) < 1e-6
    let caseW = BarGeometry.screenUnits * g.u
    let height = (BarGeometry.caseHeight + BarGeometry.controlsHeight) * g.u
    // the whole device, controls included, must be inside the window
    let fits = g.origin.x >= 0 && g.origin.x + caseW <= w + 1e-6
        && g.origin.y - BarGeometry.controlsHeight * g.u >= -1e-6
        && g.origin.y + BarGeometry.caseHeight * g.u <= h + 1e-6
    let line = String(format: "%-44@ pitch %2d px  bar %4.0f of %4.0f pt wide (%3.0f%%)  %4.1f%% tall  aligned:%@ exact:%@ fits:%@",
                      name as NSString, g.pitchPixels, caseW, w, caseW / w * 100, height / h * 100,
                      aligned ? "yes" : "NO", exact ? "yes" : "NO", fits ? "yes" : "NO")
    print(line)
    if !(aligned && exact && fits) { ok = false }
}
// The stacked layout, for small screens: every LED on whole pixels, the
// whole panel on screen.
print("\nstacked layout")
let smallScreens: [(String, CGFloat, CGFloat, CGFloat)] = [
    ("960x540 mini monitor, 1x", 960, 540, 1),
    ("800x480, 1x", 800, 480, 1),
    ("1024x600, 1x", 1024, 600, 1),
    ("1280x720, 1x", 1280, 720, 1),
    ("1920x1080, 1x", 1920, 1080, 1),
    ("4K, default HiDPI (looks like 1920x1080)", 1920, 1080, 2),
]
for (name, w, h, s) in smallScreens {
    let g = BarGeometry(size: CGSize(width: w, height: h), scale: s, layout: .stacked)
    let fieldPxW = g.field.width * s, fieldPxH = g.field.height * s
    let aligned = [g.field.minX * s, g.field.minY * s, fieldPxW, fieldPxH].allSatisfy { abs($0 - $0.rounded()) < 1e-6 }
    let exact = abs(fieldPxW - CGFloat(84 * g.pitchPixels)) < 1e-6 && abs(fieldPxH - CGFloat(44 * g.pitchPixels)) < 1e-6
    let fits = g.field.minX >= 0 && g.field.maxX <= w && g.field.minY >= 0 && g.field.maxY <= h
    print(String(format: "%-44@ pitch %2d px  panel %4.0f x %4.0f pt  %4.1f%% tall  aligned:%@ exact:%@ fits:%@",
                 name as NSString, g.pitchPixels, g.field.width, g.field.height, g.field.height / h * 100,
                 aligned ? "yes" : "NO", exact ? "yes" : "NO", fits ? "yes" : "NO"))
    if !(aligned && exact && fits) { ok = false }
}
print(ok ? "\nall layouts pixel-exact" : "\nLAYOUT PROBLEMS ABOVE")
exit(ok ? 0 : 1)
