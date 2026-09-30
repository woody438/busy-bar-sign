import Foundation
#if canImport(CoreGraphics)
import CoreGraphics      // CGRect's initialisers live here on macOS
#endif

/*
 * Where the bar goes on a screen, in points.
 *
 * Everything is measured in "4K pixels" (the simulator's units) and scaled
 * so that one LED is a whole number of device pixels: 118 LEDs plus a
 * one-LED rim either side span the screen, which on a 3840-pixel-wide
 * display is exactly 32 pixels per LED. Foundation only, so it's tested
 * on any platform.
 */
/// Where everything goes, in points, for a given screen.
struct BarGeometry {
    let pitchPixels: Int
    /// Points per 4K pixel.
    let u: CGFloat
    /// Top-left of the case (not counting the controls above it).
    let origin: CGPoint
    let field: CGRect

    static let screenUnits: CGFloat = 3840     // device width in 4K pixels: 120 LEDs at 32
    static let caseHeight: CGFloat = 624
    static let controlsHeight: CGFloat = 40

    init(size: CGSize, scale: CGFloat) {
        let s = max(scale, 1)
        let pitch = max(4, Int((size.width * s) / 120))
        pitchPixels = pitch
        u = CGFloat(pitch) / 32 / s
        let deviceW = BarGeometry.screenUnits * u
        let total = (BarGeometry.caseHeight + BarGeometry.controlsHeight) * u
        let snap = { (v: CGFloat) -> CGFloat in (v * s).rounded() / s }
        origin = CGPoint(x: snap((size.width - deviceW) / 2),
                         y: snap((size.height - total) / 2 + BarGeometry.controlsHeight * u))
        // The LED field is what must sit on whole pixels; the case can take
        // the sub-pixel remainder of its 1.75-LED margin.
        field = CGRect(x: snap(origin.x + 32 * u), y: snap(origin.y + 56 * u), width: 3776 * u, height: 512 * u)
    }

    /// A rectangle given in 4K pixels relative to the top-left of the case.
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: origin.x + x * u, y: origin.y + y * u, width: w * u, height: h * u)
    }
}
