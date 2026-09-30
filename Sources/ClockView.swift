import SwiftUI

/// Broadcast studio clock: hands for hours and minutes, a 60-segment LED ring
/// that fills across each minute for seconds, and an inset seven-segment
/// module behind smoked acrylic.
struct ClockView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                draw(context, size: size, date: timeline.date)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func draw(_ context: GraphicsContext, size: CGSize, date: Date) {
        let side = min(size.width, size.height)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = side / 2

        let parts = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0, second = parts.second ?? 0
        let fraction = Double(parts.nanosecond ?? 0) / 1_000_000_000

        drawBezel(context, center: c, radius: r)
        drawFace(context, center: c, radius: r)
        drawRing(context, center: c, radius: r, second: second, fraction: fraction)
        drawMarks(context, center: c, radius: r)
        drawModule(context, center: c, radius: r, hour: hour, minute: minute, second: second, fraction: fraction)
        drawHands(context, center: c, radius: r, hour: hour, minute: minute, second: second)
    }

    // MARK: - Pieces

    private func drawBezel(_ context: GraphicsContext, center c: CGPoint, radius r: CGFloat) {
        let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        // Brushed metal: alternating stops around a conic sweep.
        var stops: [Gradient.Stop] = []
        for i in 0...12 {
            stops.append(.init(color: i % 2 == 0 ? Palette.bezelHi : Palette.bezelLo,
                               location: Double(i) / 12))
        }
        context.fill(circle, with: .conicGradient(Gradient(stops: stops), center: c, angle: .degrees(-90)))
    }

    private func drawFace(_ context: GraphicsContext, center c: CGPoint, radius r: CGFloat) {
        let inner = r * 0.9
        let face = Path(ellipseIn: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        context.fill(face, with: .radialGradient(
            Gradient(colors: [Color(hex: 0x14171D), Color(hex: 0x07080B)]),
            center: CGPoint(x: c.x, y: c.y - r * 0.25),
            startRadius: r * 0.05, endRadius: r * 0.92))
    }

    private func drawRing(_ context: GraphicsContext, center c: CGPoint, radius r: CGFloat,
                          second: Int, fraction: Double) {
        let step = Double.pi * 2 / 60
        let gap = step * 0.19
        for i in 0..<60 {
            let major = i % 5 == 0
            let a0 = -Double.pi / 2 + Double(i) * step + gap / 2
            let a1 = -Double.pi / 2 + Double(i + 1) * step - gap / 2
            let outer = r * 0.868
            let inner = r * (major ? 0.788 : 0.818)

            var lit = 0.0
            if i < second { lit = 1 }
            else if i == second { lit = 0.25 + 0.75 * fraction }

            let segment = arcBand(center: c, inner: inner, outer: outer, from: a0, to: a1)
            if lit > 0.02 {
                var glow = context
                glow.addFilter(.shadow(color: Palette.led.opacity(0.7 * lit), radius: major ? 11 : 8))
                glow.fill(segment, with: .color(Palette.led.opacity(0.28 + 0.72 * lit)))
            } else {
                context.fill(segment, with: .color(major ? Color(hex: 0x33260F) : Color(hex: 0x231A0C)))
            }
        }
    }

    private func drawMarks(_ context: GraphicsContext, center c: CGPoint, radius r: CGFloat) {
        // 12 / 3 / 6 / 9
        for (label, degrees) in [("12", 0.0), ("3", 90.0), ("6", 180.0), ("9", 270.0)] {
            let a = (degrees - 90) * .pi / 180
            let point = CGPoint(x: c.x + cos(a) * r * 0.655, y: c.y + sin(a) * r * 0.655)
            let text = Text(label)
                .font(.system(size: r * 0.113, weight: .bold, design: .default))
                .foregroundStyle(Palette.ink)
            context.draw(text, at: point, anchor: .center)
        }
        // fine pips on the remaining hours
        for i in 0..<12 where i % 3 != 0 {
            let a = -Double.pi / 2 + Double(i) * (.pi / 6)
            let pip = arcBand(center: c, inner: r * 0.70, outer: r * 0.745, from: a - 0.012, to: a + 0.012)
            context.fill(pip, with: .color(Palette.ink.opacity(0.34)))
        }
    }

    private func drawModule(_ context: GraphicsContext, center c: CGPoint, radius r: CGFloat,
                            hour: Int, minute: Int, second: Int, fraction: Double) {
        let h1 = r * 0.175
        let w1 = SevenSegment.width(forHeight: h1)
        let g1 = h1 * 0.16, colonWidth = h1 * 0.26, bigGap = h1 * 0.30
        let h2 = h1 * 0.56
        let w2 = SevenSegment.width(forHeight: h2)
        let g2 = h2 * 0.16

        let total = w1 * 4 + colonWidth + g1 * 4 + bigGap + w2 * 2 + g2
        var x = c.x - total / 2
        let yTop = c.y + r * 0.33 - h1 / 2

        // smoked acrylic window
        let padX = h1 * 0.34, padY = h1 * 0.28
        let window = Path(roundedRect: CGRect(x: x - padX, y: yTop - padY,
                                              width: total + padX * 2, height: h1 + padY * 2),
                          cornerRadius: h1 * 0.13)
        context.fill(window, with: .color(.black.opacity(0.5)))
        context.stroke(window, with: .color(Palette.ink.opacity(0.07)), lineWidth: 1)

        let hh = String(format: "%02d", hour)
        let mm = String(format: "%02d", minute)
        let ss = String(format: "%02d", second)

        for ch in hh {
            SevenSegment.draw(context, character: ch, origin: CGPoint(x: x, y: yTop), height: h1)
            x += w1 + g1
        }
        SevenSegment.drawColon(context, x: x + colonWidth / 2, y: yTop, height: h1,
                               alpha: fraction < 0.5 ? 1 : 0.35)
        x += colonWidth + g1
        for ch in mm {
            SevenSegment.draw(context, character: ch, origin: CGPoint(x: x, y: yTop), height: h1)
            x += w1 + g1
        }
        x += bigGap - g1

        // seconds sit smaller on the same baseline
        let y2 = yTop + h1 - h2
        for ch in ss {
            SevenSegment.draw(context, character: ch, origin: CGPoint(x: x, y: y2), height: h2)
            x += w2 + g2
        }
    }

    private func drawHands(_ context: GraphicsContext, center c: CGPoint, radius r: CGFloat,
                           hour: Int, minute: Int, second: Int) {
        let minuteAngle = (Double(minute) + Double(second) / 60) * .pi / 30
        let hourAngle = (Double(hour % 12) + Double(minute) / 60) * .pi / 6
        drawHand(context, center: c, radius: r, angle: hourAngle,   length: r * 0.44, base: 22, tip: 11)
        drawHand(context, center: c, radius: r, angle: minuteAngle, length: r * 0.70, base: 17, tip: 8)

        let cap = Path(ellipseIn: CGRect(x: c.x - 15, y: c.y - 15, width: 30, height: 30))
        context.fill(cap, with: .color(Palette.ink))
        let pin = Path(ellipseIn: CGRect(x: c.x - 6.5, y: c.y - 6.5, width: 13, height: 13))
        context.fill(pin, with: .color(Color(hex: 0x0A0B0E)))
    }

    private func drawHand(_ context: GraphicsContext, center c: CGPoint, radius r: CGFloat,
                          angle: Double, length: CGFloat, base: CGFloat, tip: CGFloat) {
        let shape = Path { p in
            p.move(to: CGPoint(x: -base / 2, y: r * 0.10))
            p.addLine(to: CGPoint(x: -tip / 2, y: -length))
            p.addLine(to: CGPoint(x: 0, y: -length - tip * 0.9))
            p.addLine(to: CGPoint(x: tip / 2, y: -length))
            p.addLine(to: CGPoint(x: base / 2, y: r * 0.10))
            p.closeSubpath()
        }
        var hand = context
        hand.translateBy(x: c.x, y: c.y)
        hand.rotate(by: .radians(angle))
        hand.addFilter(.shadow(color: .black.opacity(0.85), radius: 9, x: 0, y: 3))
        hand.fill(shape, with: .color(Palette.ink))
    }

    private func arcBand(center c: CGPoint, inner: CGFloat, outer: CGFloat,
                         from a0: Double, to a1: Double) -> Path {
        Path { p in
            p.addArc(center: c, radius: outer, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
            p.addArc(center: c, radius: inner, startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
            p.closeSubpath()
        }
    }
}
