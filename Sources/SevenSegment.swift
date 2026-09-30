import SwiftUI

/// Seven-segment digits drawn as real segments with mitred ends, the way a
/// physical module is cut. Unlit segments stay faintly visible — that ghosting
/// is most of what makes an LED display read as one.
enum SevenSegment {

    private static let map: [Character: String] = [
        "0": "abcdef", "1": "bc",     "2": "abged",   "3": "abgcd",  "4": "fgbc",
        "5": "afgcd",  "6": "afgecd", "7": "abc",     "8": "abcdefg","9": "abcdfg"
    ]

    static func width(forHeight h: CGFloat) -> CGFloat { h * 0.58 }
    static func thickness(forHeight h: CGFloat) -> CGFloat { h * 0.15 }

    static func draw(_ context: GraphicsContext,
                     character: Character,
                     origin: CGPoint,
                     height h: CGFloat) {
        let w = width(forHeight: h)
        let t = thickness(forHeight: h)
        let gp = t * 0.16
        let x = origin.x, y = origin.y
        let xa = x + t / 2 + gp, xb = x + w - t / 2 - gp

        let bars: [Character: Path] = [
            "a": hBar(xa, xb, y + t / 2, t),
            "g": hBar(xa, xb, y + h / 2, t),
            "d": hBar(xa, xb, y + h - t / 2, t),
            "f": vBar(y + t / 2 + gp,       y + h / 2 - t / 2 - gp, x + t / 2,     t),
            "b": vBar(y + t / 2 + gp,       y + h / 2 - t / 2 - gp, x + w - t / 2, t),
            "e": vBar(y + h / 2 + t / 2 + gp, y + h - t / 2 - gp,   x + t / 2,     t),
            "c": vBar(y + h / 2 + t / 2 + gp, y + h - t / 2 - gp,   x + w - t / 2, t)
        ]

        let lit = map[character] ?? ""
        for (key, path) in bars {
            if lit.contains(key) {
                var glow = context
                glow.addFilter(.shadow(color: Palette.led.opacity(0.85), radius: t * 0.95))
                glow.fill(path, with: .color(Palette.ledBright))
            } else {
                context.fill(path, with: .color(Palette.led.opacity(0.065)))
            }
        }
    }

    static func drawColon(_ context: GraphicsContext,
                          x: CGFloat, y: CGFloat, height h: CGFloat, alpha: Double) {
        let t = thickness(forHeight: h)
        var glow = context
        glow.addFilter(.shadow(color: Palette.led.opacity(0.8 * alpha), radius: t * 0.85))
        for fraction in [0.34, 0.68] {
            let dot = Path(ellipseIn: CGRect(x: x - t * 0.52,
                                             y: y + h * fraction - t * 0.52,
                                             width: t * 1.04, height: t * 1.04))
            glow.fill(dot, with: .color(Palette.ledBright.opacity(alpha)))
        }
    }

    // MARK: - Mitred bars

    private static func hBar(_ x0: CGFloat, _ x1: CGFloat, _ y0: CGFloat, _ t: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: x0, y: y0))
            p.addLine(to: CGPoint(x: x0 + t / 2, y: y0 - t / 2))
            p.addLine(to: CGPoint(x: x1 - t / 2, y: y0 - t / 2))
            p.addLine(to: CGPoint(x: x1, y: y0))
            p.addLine(to: CGPoint(x: x1 - t / 2, y: y0 + t / 2))
            p.addLine(to: CGPoint(x: x0 + t / 2, y: y0 + t / 2))
            p.closeSubpath()
        }
    }

    private static func vBar(_ y0: CGFloat, _ y1: CGFloat, _ x0: CGFloat, _ t: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: x0, y: y0))
            p.addLine(to: CGPoint(x: x0 + t / 2, y: y0 + t / 2))
            p.addLine(to: CGPoint(x: x0 + t / 2, y: y1 - t / 2))
            p.addLine(to: CGPoint(x: x0, y: y1))
            p.addLine(to: CGPoint(x: x0 - t / 2, y: y1 - t / 2))
            p.addLine(to: CGPoint(x: x0 - t / 2, y: y0 + t / 2))
            p.closeSubpath()
        }
    }
}
