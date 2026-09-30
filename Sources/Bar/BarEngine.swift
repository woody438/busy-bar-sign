import Foundation

/*
 * The bar engine decides the colour of every LED for a moment in time.
 *
 * A line-for-line port of simulator/engine.js. Keep them in step: the
 * simulator is where the look is designed and checked, and this is what
 * runs on the wall. Pure and deterministic — same inputs, same frame.
 *
 * Coordinates are LED cells. Colours are RGB in 0...1: the values the BUSY
 * Bar firmware would send to its LEDs, divided by 255.
 */

typealias RGB = SIMD3<Double>

extension SIMD3 where Scalar == Double {
    init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255,
                  Double((hex >> 8) & 0xFF) / 255,
                  Double(hex & 0xFF) / 255)
    }
}

enum BarState: String {
    case call, free, dnd

    var word: String {
        switch self {
        case .call: return "ON A CALL"
        case .free: return "FREE"
        case .dnd: return "DND"
        }
    }
}

/// Sampled from the BUSY Bar firmware's own animation frames.
struct BarPalette {
    let highlight: RGB   // top row of the pill
    let top: RGB         // rows 1-3
    let bottom: RGB      // row 14
    let rimBottom: RGB   // row 15
    let edge: RGB        // 1-LED rim on the rounded ends
    let shadow: RGB      // text drop shadow on the lit pill
    let flood: RGB       // what the shockwave floods to

    static let call = BarPalette(
        highlight: RGB(hex: 0xFF808E), top: RGB(hex: 0xFF001D), bottom: RGB(hex: 0x6E0002),
        rimBottom: RGB(hex: 0x7C191B), edge: RGB(hex: 0xD14C58), shadow: RGB(hex: 0x4A0006),
        flood: RGB(hex: 0xBC2525))

    /// Do Not Disturb: indigo, the colour macOS gives Focus and Do Not
    /// Disturb, on the same vertical profile as the firmware's pills.
    static let dnd = BarPalette(
        highlight: RGB(hex: 0xB0A8FF), top: RGB(hex: 0x5B45FF), bottom: RGB(hex: 0x1D1370),
        rimBottom: RGB(hex: 0x2C237E), edge: RGB(hex: 0x8A80E8), shadow: RGB(hex: 0x110A48),
        flood: RGB(hex: 0x4A3DC4))

    static let free = BarPalette(
        highlight: RGB(hex: 0x8FFFC4), top: RGB(hex: 0x17EB79), bottom: RGB(hex: 0x03603F),
        rimBottom: RGB(hex: 0x0D7B55), edge: RGB(hex: 0x5CD69A), shadow: RGB(hex: 0x013A24),
        flood: RGB(hex: 0x2A9E63))

    static func of(_ state: BarState) -> BarPalette {
        switch state {
        case .call: return call
        case .free: return free
        case .dnd: return dnd
        }
    }
}

// MARK: - Maths

private func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { v < a ? a : (v > b ? b : v) }
private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
private func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { a + (b - a) * t }
private func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = clamp((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}
private func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
private func easeIn(_ t: Double) -> Double { t * t * t }
/// JavaScript's Math.round: halves go up, including negative ones.
private func jsRound(_ v: Double) -> Int { Int((v + 0.5).rounded(.down)) }

private let white = RGB(1, 1, 1)

// MARK: - Framebuffer

struct LEDFrame {
    /// The wide bar's size.
    static let cols = 118
    static let rows = 16

    /// This frame's size: the wide bar's, or the stacked layout's.
    let w: Int, h: Int
    var px: [Double]

    init(w: Int = LEDFrame.cols, h: Int = LEDFrame.rows) {
        self.w = w; self.h = h
        px = [Double](repeating: 0, count: w * h * 3)
    }

    @inline(__always) private func inBounds(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < w && y < h
    }

    func get(_ x: Int, _ y: Int) -> RGB {
        let i = (y * w + x) * 3
        return RGB(px[i], px[i + 1], px[i + 2])
    }

    mutating func clear() {
        for i in px.indices { px[i] = 0 }
    }

    mutating func set(_ x: Int, _ y: Int, _ c: RGB) {
        guard inBounds(x, y) else { return }
        let i = (y * w + x) * 3
        px[i] = c.x; px[i + 1] = c.y; px[i + 2] = c.z
    }

    /// Alpha-blend `c` over the existing LED.
    mutating func blend(_ x: Int, _ y: Int, _ c: RGB, _ alpha: Double) {
        guard alpha > 0, inBounds(x, y) else { return }
        let a = min(alpha, 1)
        let i = (y * w + x) * 3
        px[i] += (c.x - px[i]) * a
        px[i + 1] += (c.y - px[i + 1]) * a
        px[i + 2] += (c.z - px[i + 2]) * a
    }

    /// Add light — how the firmware's transition overlays combine with the screen.
    mutating func add(_ x: Int, _ y: Int, _ c: RGB, _ k: Double) {
        guard k > 0, inBounds(x, y) else { return }
        let i = (y * w + x) * 3
        px[i] = min(1, px[i] + c.x * k)
        px[i + 1] = min(1, px[i + 1] + c.y * k)
        px[i + 2] = min(1, px[i + 2] + c.z * k)
    }

    mutating func multiply(_ x: Int, _ y: Int, _ k: Double) {
        guard inBounds(x, y) else { return }
        let i = (y * w + x) * 3
        px[i] *= k; px[i + 1] *= k; px[i + 2] *= k
    }
}

// MARK: - Inputs

struct ClockReading {
    let h: Int, m: Int, s: Int, ms: Int
    let dow: Int     // 0 = Sunday, as JavaScript's getDay()
    let date: Int    // day of the month

    init(h: Int, m: Int, s: Int, ms: Int, dow: Int, date: Int) {
        self.h = h; self.m = m; self.s = s; self.ms = ms; self.dow = dow; self.date = date
    }

    init(_ when: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute, .second, .nanosecond, .weekday, .day], from: when)
        self.init(h: c.hour ?? 0, m: c.minute ?? 0, s: c.second ?? 0,
                  ms: (c.nanosecond ?? 0) / 1_000_000,
                  dow: ((c.weekday ?? 1) - 1 + 7) % 7,     // Calendar: 1 = Sunday
                  date: c.day ?? 1)
    }
}

/// Do Not Disturb's countdown: seconds left, and the end time (hour, minute).
struct DNDTimer {
    let left: Double
    let h: Int, m: Int
}

struct Sheen { let pos: Double; let width: Double; let strength: Double }

struct TextStyle {
    var shadow: RGB? = nil
    var shadowDepth = 1
    var shadowAlpha = 0.85
    var alpha = 1.0
    var space: Int? = nil
    var tracking = 0
    var clip: (lo: Int, hi: Int)? = nil
    var clipY: (lo: Int, hi: Int)? = nil
}

// MARK: - Engine

enum BarEngine {
    static let cols = LEDFrame.cols
    static let rows = LEDFrame.rows

    /*
     * Layout — 118 x 16, after the firmware's timer screen: a lit pill on
     * the left, the time in white on black to its right, a dim word below.
     *   col 0        margin
     *   cols 1-80    status pill  (icon + word, lit)
     *   cols 81-83   gap
     *   cols 84-116  clock        (time rows 1-7, date rows 10-14)
     *   col 117      margin
     */
    enum Layout {
        static let statusX = 1.0, statusW = 80.0
        static let clockX = 84, clockW = 33
        static let heroX = 1.0, heroW = Double(LEDFrame.cols - 2)
        static let heroFont = "busy_regular_14"   // 14-row capitals: the announcement
        static let statusFont = "busy_bold_10"    // the face of the firmware's BUSY pill
        static let timeFont = "busy_bold_7"       // the firmware's clock app face
        static let dateFont = "busy_regular_5"
        static let heroBase = 14                  // baseline rows (bottom row of capitals)
        static let statusBase = 12
        static let timeBase = 7                   // rows 1-7, as the firmware's timer label
        static let dateBase = 14                  // rows 10-14
        static let iconGap = 4
        static let slideIn = 40.0                 // the time slides in from 40 LEDs right
    }

    /// Seconds from the moment the state changes.
    enum Timing {
        static let wave = 1.10       // the shockwave: 66 frames at 60 fps
        static let swap = 0.10       // the firmware cuts to the new screen at 100 ms
        static let press = 3.0       // ...having pressed the old one down 3 rows, then springs the new one up
        static let hold = 3.4        // the announcement stays up this long after the cut
        static let collapse = 0.667  // 41 frames, as indicator_busy_transition

        /// After this long the bar is back to its steady screen.
        static var settled: Double { swap + hold + collapse }
    }

    static let days = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

    /// Pictograms, drawn in the firmware's style: white, hard shadow. The mic
    /// echoes the firmware's on_call theme; the tick is the "available" mark
    /// every meeting app uses; the moon is Do Not Disturb's, as on the Mac.
    /// Rows top to bottom.
    static let icons: [BarState: [String]] = [
        .call: [
            "...###...",
            "..#####..",
            "..#####..",
            "..#####..",
            "..#####..",
            "#.#####.#",
            "#.#####.#",
            "#..###..#",
            ".#.....#.",
            "..#####..",
            "....#....",
            "..#####.."
        ],
        .dnd: [
            "....#.......",
            "..###.......",
            ".###........",
            ".###........",
            "#####.......",
            "#####.......",
            "######......",
            "#######....#",
            ".##########.",
            ".##########.",
            "..########..",
            "....####...."
        ],
        .free: [
            "........##",
            ".......###",
            "......###.",
            ".....###..",
            "##..###...",
            "######....",
            ".####.....",
            "..##......"
        ]
    ]
    /// Rows above the baseline for the icon's bottom row.
    static let iconLift: [BarState: Int] = [.call: -1, .free: 1, .dnd: -1]

    /// The announcement. busy_regular_14 is busy_regular_7 doubled, so
    /// everything about it is at twice the scale: a two-step shadow, and word
    /// spaces trimmed to match. DO NOT DISTURB is too wide for it, so it's set
    /// in the status face across the whole bar.
    struct Hero {
        let word: String, font: String, base: Int, depth: Int, space: Int?
    }
    static func hero(_ state: BarState) -> Hero {
        switch state {
        case .call: return Hero(word: "ON A CALL", font: "busy_regular_14", base: 14, depth: 2, space: 6)
        case .free: return Hero(word: "FREE", font: "busy_regular_14", base: 14, depth: 2, space: 6)
        case .dnd: return Hero(word: "DO NOT DISTURB", font: "busy_bold_10", base: 12, depth: 1, space: nil)
        }
    }

    /// Deterministic hash to 0...1. Matches engine.js bit for bit.
    static func hash(_ n: Int) -> Double {
        var x = UInt32(truncatingIfNeeded: n)
        x = (x ^ (x >> 16)) &* 0x45d9f3b
        x = (x ^ (x >> 16)) &* 0x45d9f3b
        x = x ^ (x >> 16)
        return Double(x) / 4294967295
    }

    // MARK: Scene

    /*
     * The scene at a moment.
     *   now   — seconds, monotonic (drives ambient motion)
     *   state — current state;  prev — the one before it, if any
     *   since — `now` at which `state` began
     *   clock — the wall-clock time to show
     *   timer — Do Not Disturb's countdown, shown in place of the clock
     *           while the state is .dnd
     */
    static func render(into f: inout LEDFrame, now: Double, state: BarState, prev: BarState?,
                       since: Double, clock: ClockReading, timer: DNDTimer? = nil) {
        f.clear()
        let pal = BarPalette.of(state)
        let e = now - since
        let collapseStart = Timing.swap + Timing.hold
        let collapseEnd = collapseStart + Timing.collapse

        if e < Timing.swap {
            // the old screen, pressed down as the wave hits it
            if let prev {
                drawSteady(&f, now: now, state: prev, clock: clock, timer: timer, slide: 0)
                shiftDown(&f, jsRound(Timing.press * easeIn(e / Timing.swap)))
            }
        } else if e < collapseStart {
            drawHero(&f, now: now, state: state, pal: pal)
            // ...and the new one springs back up
            let r = (e - Timing.swap) / Timing.swap
            if r < 1 { shiftDown(&f, jsRound(Timing.press * (1 - easeOut(r)))) }
        } else if e < collapseEnd {
            let k = easeInOut((e - collapseStart) / Timing.collapse)
            let w = lerp(Layout.heroW, Layout.statusW, k)
            let edge = Layout.heroX + w
            drawPill(&f, x0: Layout.heroX, w: w, pal: pal, sheen: sheenAt(now))
            // the announcement face gives way to icon + status face as the pill shrinks:
            // out before the big word can outgrow the pill, in once there's room
            let fadeOut = 1 - smooth(0.08, 0.34, k)
            let fadeIn = smooth(0.14, 0.4, k)         // overlapping, so the pill is never empty
            let clip = (lo: Int(Layout.heroX) + 1, hi: Int(edge.rounded(.down)) - 1)
            if fadeOut > 0 {
                let hw = Double(heroWidth(state))
                var style = heroStyle(state, pal, alpha: fadeOut)
                style.clip = clip
                let h = hero(state)
                drawText(&f, font: h.font, h.word,
                         x: Layout.heroX + (max(w, hw + 6) - hw) / 2 + 0.5,
                         baseY: h.base, colour: white, style: style)
            }
            if fadeIn > 0 {
                drawStatusContent(&f, state: state, pal: pal, x0: Layout.heroX, w: w, alpha: fadeIn, clip: clip)
            }
            // the time slides in from the right as the pill makes room, as the
            // firmware's timer label does
            let slide = jsRound(Layout.slideIn * (1 - easeOut((e - collapseStart) / Timing.collapse)))
            drawRight(&f, state: state, clock: clock, timer: timer, slide: slide, minX: Int(edge.rounded(.up)) + 2)
        } else {
            drawSteady(&f, now: now, state: state, clock: clock, timer: timer, slide: 0)
        }

        if e < Timing.wave { drawShockwave(&f, progress: e / Timing.wave, pal: pal) }
    }

    /// Move everything down by `dy` rows (the firmware's press effect).
    static func shiftDown(_ f: inout LEDFrame, _ dy: Int) {
        guard dy > 0 else { return }
        for y in stride(from: f.h - 1, through: 0, by: -1) {
            for x in 0..<f.w {
                f.set(x, y, y - dy >= 0 ? f.get(x, y - dy) : RGB(0, 0, 0))
            }
        }
    }

    /// A soft band of light crosses the pill every 8 s — the firmware's
    /// indicator_busy loop does the same over 20 s.
    static func sheenAt(_ now: Double, cols: Int = BarEngine.cols) -> Sheen {
        let cycle = 8.0
        let pos = (now.truncatingRemainder(dividingBy: cycle) / cycle) * Double(cols + 50) - 25
        return Sheen(pos: pos, width: 6, strength: 0.18)
    }

    static func heroStyle(_ state: BarState, _ pal: BarPalette, alpha: Double = 1) -> TextStyle {
        let h = hero(state)
        return TextStyle(shadow: pal.shadow, shadowDepth: h.depth, shadowAlpha: 0.9 * alpha, alpha: alpha, space: h.space)
    }

    static func heroWidth(_ state: BarState) -> Int {
        let h = hero(state)
        return textWidth(h.font, h.word, space: h.space)
    }

    static func drawHero(_ f: inout LEDFrame, now: Double, state: BarState, pal: BarPalette) {
        drawPill(&f, x0: Layout.heroX, w: Layout.heroW, pal: pal, sheen: sheenAt(now))
        let w = Double(heroWidth(state))
        let h = hero(state)
        drawText(&f, font: h.font, h.word, x: Layout.heroX + (Layout.heroW - w) / 2 + 0.5,
                 baseY: h.base, colour: white, style: heroStyle(state, pal))
    }

    static func drawSteady(_ f: inout LEDFrame, now: Double, state: BarState, clock: ClockReading,
                           timer: DNDTimer?, slide: Int) {
        let pal = BarPalette.of(state)
        drawPill(&f, x0: Layout.statusX, w: Layout.statusW, pal: pal, sheen: sheenAt(now))
        drawStatusContent(&f, state: state, pal: pal, x0: Layout.statusX, w: Layout.statusW, alpha: 1, clip: nil)
        drawRight(&f, state: state, clock: clock, timer: timer, slide: slide, minX: 0)
    }

    /// Right of the pill: the clock, or Do Not Disturb's countdown.
    static func drawRight(_ f: inout LEDFrame, state: BarState, clock: ClockReading, timer: DNDTimer?,
                          slide: Int, minX: Int) {
        if state == .dnd, let timer {
            drawCountdown(&f, clock: clock, timer: timer, slide: slide, minX: minX)
        } else {
            drawClock(&f, clock: clock, slide: slide, minX: minX)
        }
    }

    // MARK: Status

    static func drawIcon(_ f: inout LEDFrame, rows iconRows: [String], x: Int, bottomY: Int,
                         colour: RGB, shadow: RGB, alpha: Double, clip: (lo: Int, hi: Int)?) {
        let h = iconRows.count
        let passes: [(d: Int, c: RGB, a: Double)] = [(1, shadow, 0.9 * alpha), (0, colour, alpha)]
        for pass in passes {
            for (r, row) in iconRows.enumerated() {
                for (c, ch) in row.enumerated() where ch == "#" {
                    let gx = x + c + pass.d, gy = bottomY - h + 1 + r + pass.d
                    if let clip, gx < clip.lo || gx >= clip.hi { continue }
                    f.blend(gx, gy, pass.c, pass.a)
                }
            }
        }
    }

    /// Icon + word, centred as one unit.
    static func statusContentWidth(_ state: BarState) -> Int {
        (icons[state]?.first?.count ?? 0) + Layout.iconGap + textWidth(Layout.statusFont, state.word)
    }

    static func drawStatusContent(_ f: inout LEDFrame, state: BarState, pal: BarPalette, x0: Double, w: Double,
                                  alpha: Double, clip: (lo: Int, hi: Int)?) {
        guard let icon = icons[state] else { return }
        let iconW = icon.first?.count ?? 0
        let x = jsRound(x0 + (w - Double(statusContentWidth(state))) / 2)
        drawIcon(&f, rows: icon, x: x, bottomY: Layout.statusBase - (iconLift[state] ?? 0),
                 colour: white, shadow: pal.shadow, alpha: alpha, clip: clip)
        drawText(&f, font: Layout.statusFont, state.word, x: Double(x + iconW + Layout.iconGap),
                 baseY: Layout.statusBase, colour: white,
                 style: TextStyle(shadow: pal.shadow, shadowAlpha: 0.9 * alpha, alpha: alpha, clip: clip))
    }

    // MARK: Clock

    /*
     * The time, white on black, with the day beneath at half brightness —
     * the firmware's clock app. Colons drop to 40% on odd seconds.
     * `slide` pushes it right (entrance); nothing is drawn left of `minX`.
     */
    static func drawClock(_ f: inout LEDFrame, clock: ClockReading, slide: Int, minX: Int) {
        let hhmm = String(format: "%02d:%02d", clock.h, clock.m)
        let day = days[((clock.dow % 7) + 7) % 7] + " " + String(clock.date)
        let tw = clockTextWidth(Layout.timeFont, hhmm)
        let dw = textWidth(Layout.dateFont, day)
        let x0 = Layout.clockX + slide
        let clip = (lo: max(minX, Layout.clockX - 3), hi: cols)
        let colon = clock.s % 2 == 1 ? 0.4 : 1.0
        drawClockText(&f, font: Layout.timeFont, hhmm, x: x0 + jsRound(Double(Layout.clockW - tw) / 2),
                      baseY: Layout.timeBase, colour: white, style: TextStyle(clip: clip), colonAlpha: colon)
        drawText(&f, font: Layout.dateFont, day, x: Double(x0 + jsRound(Double(Layout.clockW - dw) / 2)),
                 baseY: Layout.dateBase, colour: white, style: TextStyle(alpha: 0.5, clip: clip))
    }

    /*
     * Do Not Disturb's countdown, in the clock's place and face — the
     * firmware's timer screen — with its end time beneath at half brightness.
     * Whole seconds, rounded up, so it reads 30:00 as it starts and 00:01 last.
     */
    static func countdownText(_ timer: DNDTimer) -> (mmss: String, until: String) {
        let secs = min(max(Int((timer.left - 1e-9).rounded(.up)), 0), 99 * 60 + 59)
        return (String(format: "%02d:%02d", secs / 60, secs % 60), String(format: "TILL %02d:%02d", timer.h, timer.m))
    }

    static func drawCountdown(_ f: inout LEDFrame, clock: ClockReading, timer: DNDTimer, slide: Int, minX: Int) {
        let (mmss, until) = countdownText(timer)
        let tw = clockTextWidth(Layout.timeFont, mmss)
        let uw = textWidth(Layout.dateFont, until)
        let x0 = Layout.clockX + slide
        let clip = (lo: max(minX, Layout.clockX - 3), hi: cols)
        let colon = clock.s % 2 == 1 ? 0.4 : 1.0
        drawClockText(&f, font: Layout.timeFont, mmss, x: x0 + jsRound(Double(Layout.clockW - tw) / 2),
                      baseY: Layout.timeBase, colour: white, style: TextStyle(clip: clip), colonAlpha: colon)
        drawText(&f, font: Layout.dateFont, until, x: Double(x0 + jsRound(Double(Layout.clockW - uw) / 2)),
                 baseY: Layout.dateBase, colour: white, style: TextStyle(alpha: 0.5, clip: clip))
    }

    private static func digitCell(_ font: PixelFont) -> Int {
        var cell = 0
        for d in "0123456789" { if let g = font.glyph(d), g.adv > cell { cell = g.adv } }
        return cell
    }

    /// Tabular digits: every digit takes the widest digit's advance, so the
    /// clock doesn't shuffle sideways as the minutes turn.
    @discardableResult
    static func drawClockText(_ f: inout LEDFrame, font fontName: String, _ str: String, x: Int, baseY: Int,
                              colour: RGB, style: TextStyle, colonAlpha: Double) -> Int {
        guard let font = PixelFonts.font(fontName) else { return 0 }
        let cell = digitCell(font)
        var pen = x
        for ch in str {
            guard let g = font.glyph(ch) else { continue }
            if ch.isASCII, ch.isNumber {
                let inset = cell - g.adv            // narrow digits sit right, like a real LED clock
                drawText(&f, font: fontName, String(ch), x: Double(pen + inset), baseY: baseY,
                         colour: colour, style: style)
                pen += cell
            } else {
                var s = style
                s.alpha *= colonAlpha
                drawText(&f, font: fontName, String(ch), x: Double(pen), baseY: baseY, colour: colour, style: s)
                pen += g.adv
            }
        }
        return pen - x
    }

    static func clockTextWidth(_ fontName: String, _ str: String) -> Int {
        guard let font = PixelFonts.font(fontName) else { return 0 }
        let cell = digitCell(font)
        var w = 0
        for ch in str {
            guard let g = font.glyph(ch) else { continue }
            w += (ch.isASCII && ch.isNumber) ? cell : g.adv
        }
        return w
    }

    // MARK: Pills

    /// Signed distance from a cell centre to a rounded rectangle. Negative inside.
    private static func roundRectSDF(_ px: Double, _ py: Double, _ x0: Double, _ y0: Double,
                                     _ w: Double, _ h: Double, _ r: Double) -> Double {
        let cx = x0 + w / 2, cy = y0 + h / 2
        let qx = abs(px - cx) - (w / 2 - r)
        let qy = abs(py - cy) - (h / 2 - r)
        let ox = max(qx, 0), oy = max(qy, 0)
        return (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r
    }

    /*
     * A lit pill: highlight top row, bright band, linear fall to a deep base,
     * lighter bottom rim, and a pale 1-LED edge — the BUSY pill's vertical
     * profile, stretched to any width.
     */
    static func drawPill(_ f: inout LEDFrame, x0: Double, w: Double, pal: BarPalette, sheen: Sheen? = nil,
                         h rowsTall: Int = LEDFrame.rows) {
        let rows = rowsTall                              // rows 0..h-1: 16, or taller in the stacked layout
        let y0 = 0.0, h = Double(rows), r = 2.6
        let xs = Int(x0.rounded(.down)) - 1
        let xe = Int((x0 + w).rounded(.up)) + 1
        for y in 0..<rows {
            for x in xs...xe {
                let d = roundRectSDF(Double(x) + 0.5, Double(y) + 0.5, x0, y0, w, h, r)
                let cover = clamp(0.5 - d, 0, 1)
                guard cover > 0 else { continue }

                var c: RGB
                if y == 0 { c = pal.highlight }
                else if y <= 3 { c = pal.top }
                else if y == rows - 1 { c = pal.rimBottom }
                else { c = mix(pal.top, pal.bottom, Double(y - 3) / Double(rows - 2 - 3)) }
                // pale rim on the rounded ends
                let edge = clamp(1 - abs(d + 0.9), 0, 1)
                if edge > 0 && y > 0 && y < rows - 1 { c = mix(c, pal.edge, edge * 0.85) }
                if let sheen {
                    // a soft diagonal band of light drifting across the pill
                    let u = (Double(x) + 0.5 - sheen.pos) + (Double(y) - Double(rows) / 2) * 0.55
                    let s = exp(-(u * u) / (2 * sheen.width * sheen.width)) * sheen.strength
                    c = mix(c, pal.highlight, s)
                }
                f.blend(x, y, c, cover)
            }
        }
    }

    // MARK: Text

    static func textWidth(_ fontName: String, _ str: String, tracking: Int = 0, space: Int? = nil) -> Int {
        guard let font = PixelFonts.font(fontName) else { return 0 }
        let chars = Array(str)
        var w = 0
        for (i, ch) in chars.enumerated() {
            guard let g = font.glyph(ch) else { continue }
            w += (ch == " " ? (space ?? g.adv) : g.adv) + (i < chars.count - 1 ? tracking : 0)
        }
        return w
    }

    /// Draw a string with its baseline at `baseY`. A hard drop shadow sits one
    /// LED down and right, the way the firmware's white-on-red type is set.
    static func drawText(_ f: inout LEDFrame, font fontName: String, _ str: String, x: Double, baseY: Int,
                         colour: RGB, style: TextStyle = TextStyle()) {
        guard let font = PixelFonts.font(fontName) else { return }
        var passes: [(dx: Int, dy: Int, c: RGB, a: Double)] = []
        if let shadow = style.shadow, style.shadowDepth == 2 {
            passes.append((2, 2, shadow, style.shadowAlpha * 0.8))
        }
        if let shadow = style.shadow { passes.append((1, 1, shadow, style.shadowAlpha)) }
        passes.append((0, 0, colour, style.alpha))

        for pass in passes {
            var pen = jsRound(x)
            for ch in str {
                guard let g = font.glyph(ch) else { continue }
                for (r, row) in g.bits.enumerated() {
                    for (c, k) in row.enumerated() where k > 0 {
                        let gx = pen + g.ox + c + pass.dx
                        let gy = baseY - g.oy - g.h + 1 + r + pass.dy   // oy: bottom of box above baseline
                        if let clip = style.clip, gx < clip.lo || gx >= clip.hi { continue }
                    if let clipY = style.clipY, gy < clipY.lo || gy >= clipY.hi { continue }
                        f.blend(gx, gy, pass.c, k * pass.a)
                    }
                }
                pen += (ch == " " ? (style.space ?? g.adv) : g.adv) + style.tracking
            }
        }
    }

    // MARK: Transition

    /*
     * The firmware's "select" transition, rebuilt so it fits any width: a white
     * ring bursts from just above top-centre with a dark leading edge, clears
     * the old screen, the state colour floods in, the panel flashes, then the
     * light decays. Additive — black contributes nothing.
     *
     * 66 frames at 60 fps in the original; `progress` runs 0...1 over 1.1 s.
     */
    static func drawShockwave(_ f: inout LEDFrame, progress p: Double, pal: BarPalette) {
        guard p > 0, p < 1 else { return }
        let frame = p * 66
        let aspect = 1.65                                  // the ring reads as an oval on a wide panel
        let cx = Double(f.w) / 2, cy = -3.5
        // on a taller panel the ring travels further, so it still reaches the corners on cue
        let reach = hypot(Double(f.w) / 2 / aspect, Double(f.h) - cy) / hypot(Double(cols) / 2 / aspect, Double(rows) - cy)
        let radius = pow(frame / 11, 1.35) * 34 * reach    // reaches the corners around frame 11
        let band = 3.2 + frame * 0.55                      // ring thickens as it travels
        // colour floods in, peaks at frame 11, then decays the way the firmware's
        // frames do: roughly exponential, half-life about nine frames
        let flood = frame < 11 ? smooth(4, 11, frame)
                               : exp(-(frame - 11) / 13) * (1 - smooth(60, 66, frame))
        let ringLife = 1 - smooth(9, 16, frame)
        let crestColour = mix(pal.flood, white, 0.72)
        for y in 0..<f.h {
            for x in 0..<f.w {
                let dx = (Double(x) + 0.5 - cx) / aspect, dy = Double(y) + 0.5 - cy
                let d = (dx * dx + dy * dy).squareRoot()
                let u = (d - radius) / band                 // 0 at the ring's crest
                // hot white crest, colour behind it, dark just ahead of it
                let crest = exp(-u * u * 2.2) * ringLife
                let inside = d < radius
                let ahead = (u > 0.6 && u < 1.6) ? (1 - abs(u - 1.1) * 2) * ringLife : 0
                if ahead > 0 { f.multiply(x, y, 1 - ahead * 0.85) }
                // until the flood peaks, the ring clears the old screen as it passes
                if frame < 11 && u < -0.4 { f.multiply(x, y, 0.12) }
                f.add(x, y, crestColour, crest * 0.9)
                let edgeGlow = clamp((d - radius * 0.35) / (radius * 0.65 + 0.01), 0, 1)
                f.add(x, y, mix(pal.flood, pal.highlight, edgeGlow * 0.55), flood * (inside ? 1 : 0.9) * 0.62)
            }
        }
    }
    // MARK: - Stacked layout

    /*
     * For small screens (960 x 540 and the like): an 84 x 44 panel with the
     * status pill across the top and the clock large beneath it. Same states,
     * colours, faces and timeline as the bar.
     *
     *   rows 0-15    status pill, cols 1-82 (icon + word, as the bar)
     *   rows 20-33   the time — or Do Not Disturb's countdown — 14 rows
     *   rows 36-42   the day — or the countdown's end time — half bright
     */
    enum Stacked {
        static let cols = 84, rows = 44
        static let pillX = 1.0, pillW = 82.0, pillH = 16
        static let bigFont = "busy_regular_14", smallFont = "busy_bold_7"
        static let bigBase = 33, smallBase = 42
        static let slideIn = 24.0      // the clock rises from 24 rows down
        static let heroGap = 4         // rows between the announcement's lines

        /// The announcement fills the panel, a word or two per line.
        static func hero(_ state: BarState) -> [String] {
            switch state {
            case .call: return ["ON A", "CALL"]
            case .free: return ["FREE"]
            case .dnd: return ["DO NOT", "DISTURB"]
            }
        }
    }

    static func renderStacked(into f: inout LEDFrame, now: Double, state: BarState, prev: BarState?,
                              since: Double, clock: ClockReading, timer: DNDTimer? = nil) {
        f.clear()
        let pal = BarPalette.of(state)
        let e = now - since
        let collapseStart = Timing.swap + Timing.hold
        let collapseEnd = collapseStart + Timing.collapse

        if e < Timing.swap {
            if let prev {
                drawStackedSteady(&f, now: now, state: prev, clock: clock, timer: timer, slide: 0)
                shiftDown(&f, jsRound(Timing.press * easeIn(e / Timing.swap)))
            }
        } else if e < collapseStart {
            drawPill(&f, x0: Stacked.pillX, w: Stacked.pillW, pal: pal, sheen: sheenAt(now, cols: f.w), h: f.h)
            drawStackedHero(&f, state: state, pal: pal, alpha: 1, clipY: nil)
            let r = (e - Timing.swap) / Timing.swap
            if r < 1 { shiftDown(&f, jsRound(Timing.press * (1 - easeOut(r)))) }
        } else if e < collapseEnd {
            // the pill draws up from the whole panel to the top band
            let k = easeInOut((e - collapseStart) / Timing.collapse)
            let h = jsRound(lerp(Double(f.h), Double(Stacked.pillH), k))
            drawPill(&f, x0: Stacked.pillX, w: Stacked.pillW, pal: pal, sheen: sheenAt(now, cols: f.w), h: h)
            let fadeOut = 1 - smooth(0.08, 0.34, k)
            let fadeIn = smooth(0.14, 0.4, k)
            if fadeOut > 0 { drawStackedHero(&f, state: state, pal: pal, alpha: fadeOut, clipY: (1, h - 1)) }
            if fadeIn > 0 {
                drawStatusContent(&f, state: state, pal: pal, x0: Stacked.pillX, w: Stacked.pillW, alpha: fadeIn, clip: nil)
            }
            // ...and the clock rises into the space it leaves
            let slide = jsRound(Stacked.slideIn * (1 - easeOut((e - collapseStart) / Timing.collapse)))
            drawStackedClock(&f, state: state, clock: clock, timer: timer, slide: slide, minY: h + 2)
        } else {
            drawStackedSteady(&f, now: now, state: state, clock: clock, timer: timer, slide: 0)
        }

        if e < Timing.wave { drawShockwave(&f, progress: e / Timing.wave, pal: pal) }
    }

    static func drawStackedSteady(_ f: inout LEDFrame, now: Double, state: BarState, clock: ClockReading,
                                  timer: DNDTimer?, slide: Int) {
        let pal = BarPalette.of(state)
        drawPill(&f, x0: Stacked.pillX, w: Stacked.pillW, pal: pal, sheen: sheenAt(now, cols: f.w), h: Stacked.pillH)
        drawStatusContent(&f, state: state, pal: pal, x0: Stacked.pillX, w: Stacked.pillW, alpha: 1, clip: nil)
        drawStackedClock(&f, state: state, clock: clock, timer: timer, slide: slide, minY: 0)
    }

    static func drawStackedHero(_ f: inout LEDFrame, state: BarState, pal: BarPalette, alpha: Double,
                                clipY: (lo: Int, hi: Int)?) {
        let lines = Stacked.hero(state)
        let block = lines.count * 14 + (lines.count - 1) * Stacked.heroGap
        let top = jsRound(Double(f.h - block) / 2)
        // the 14-row face, set as the bar's announcement: two-step shadow, trimmed spaces
        var style = TextStyle(shadow: pal.shadow, shadowDepth: 2, shadowAlpha: 0.9 * alpha, alpha: alpha, space: 6)
        style.clipY = clipY
        for (i, line) in lines.enumerated() {
            let w = Double(textWidth("busy_regular_14", line, space: 6))
            drawText(&f, font: "busy_regular_14", line, x: Stacked.pillX + (Stacked.pillW - w) / 2 + 0.5,
                     baseY: top + 13 + i * (14 + Stacked.heroGap), colour: white, style: style)
        }
    }

    /// The time and the day — or Do Not Disturb's countdown and its end
    /// time — centred beneath the pill. `slide` pushes it down (entrance);
    /// nothing is drawn above row `minY`.
    static func drawStackedClock(_ f: inout LEDFrame, state: BarState, clock: ClockReading, timer: DNDTimer?,
                                 slide: Int, minY: Int) {
        let big: String, small: String
        if state == .dnd, let timer {
            let text = countdownText(timer)
            big = text.mmss; small = text.until
        } else {
            big = String(format: "%02d:%02d", clock.h, clock.m)
            small = days[((clock.dow % 7) + 7) % 7] + " " + String(clock.date)
        }
        let clipY = (lo: minY, hi: f.h)
        let colon = clock.s % 2 == 1 ? 0.4 : 1.0
        let bw = clockTextWidth(Stacked.bigFont, big)
        let sw = textWidth(Stacked.smallFont, small)
        drawClockText(&f, font: Stacked.bigFont, big, x: jsRound(Double(f.w - bw) / 2), baseY: Stacked.bigBase + slide,
                      colour: white, style: TextStyle(clipY: clipY), colonAlpha: colon)
        drawText(&f, font: Stacked.smallFont, small, x: Double(jsRound(Double(f.w - sw) / 2)),
                 baseY: Stacked.smallBase + slide, colour: white, style: TextStyle(alpha: 0.5, clipY: clipY))
    }
}
