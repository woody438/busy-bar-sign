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
/// How the full-screen display is laid out. The floating window is always wide.
enum BarLayout: String, CaseIterable, Identifiable {
    /// The bar across the screen, in its case — the default.
    case wide
    /// For small screens (960 x 540 and the like): the pill on top, the
    /// clock large beneath, LEDs filling the screen.
    case stacked

    var id: String { rawValue }
    var label: String {
        switch self {
        case .wide: return "Wide bar"
        case .stacked: return "Stacked (small screens)"
        }
    }
    /// The LED grid. (LEDFrame.cols x rows and BarEngine.Stacked; literal here
    /// so this file builds on its own for the checks.)
    var cols: Int { self == .wide ? 118 : 84 }
    var rows: Int { self == .wide ? 16 : 44 }
}

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

    /// For a layout: the wide bar in its case, or the stacked layout — no
    /// case, just the LEDs, as large as whole pixels allow with a one-LED
    /// margin, centred.
    init(size: CGSize, scale: CGFloat, layout: BarLayout) {
        switch layout {
        case .wide:
            self.init(size: size, scale: scale)
        case .stacked:
            let s = max(scale, 1)
            let pitch = max(4, Int(min(size.width * s / CGFloat(layout.cols + 2),
                                       size.height * s / CGFloat(layout.rows + 2))))
            let snap = { (v: CGFloat) -> CGFloat in (v * s).rounded() / s }
            let fw = CGFloat(layout.cols * pitch) / s, fh = CGFloat(layout.rows * pitch) / s
            let field = CGRect(x: snap((size.width - fw) / 2), y: snap((size.height - fh) / 2), width: fw, height: fh)
            self.init(pitchPixels: pitch, u: CGFloat(pitch) / 32 / s, origin: field.origin, field: field)
        }
    }

    private init(pitchPixels: Int, u: CGFloat, origin: CGPoint, field: CGRect) {
        self.pitchPixels = pitchPixels
        self.u = u
        self.origin = origin
        self.field = field
    }

    /// A rectangle given in 4K pixels relative to the top-left of the case.
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: origin.x + x * u, y: origin.y + y * u, width: w * u, height: h * u)
    }

    // MARK: - The orbit

    /*
     * Looking after the wall's screen: the LEDs never stand still. They move
     * a device pixel at a time along a path through every position within
     * one LED — there and back, snaking a row at a time — so every pixel of
     * the screen spends as long under a dot as in a gap, and the edges of the
     * pill and the type blur across a whole LED rather than burn in. A
     * one-way pass takes about an hour whatever the pitch: a step every 14 s
     * at 16 pixels an LED, every 3.5 s at 32. Whole pixels, so the dots stay
     * sharp. In the wide layout the LEDs move inside the case, which stays put.
     */
    struct Offset: Equatable {
        var x = 0, y = 0
    }

    /// Where the LEDs are, in device pixels from their place, at `t` (seconds since 1970).
    static func orbit(at t: Double, pitch: Int) -> Offset {
        let p = max(pitch, 1), cells = p * p
        guard cells > 1 else { return Offset() }
        let period = 2 * (cells - 1)
        var i = Int((t / orbitStep(pitch: p)).rounded(.down)) % period
        if i < 0 { i += period }
        if i >= cells { i = period - i }                 // and back
        let row = i / p
        let col = row % 2 == 0 ? i % p : p - 1 - i % p   // snaking
        return Offset(x: col - p / 2, y: row - p / 2)
    }

    /// Seconds between steps: a one-way pass in an hour, a step every 2 to 60 s.
    static func orbitStep(pitch: Int) -> Double {
        min(60, max(2, 3600 / Double(max(pitch * pitch, 1))))
    }

    /// The LEDs' corners in the wide layout, in 4K pixels: rounded, so that
    /// moving half an LED they stay inside the case's rounded face.
    static let fieldCorner: CGFloat = 40
}
