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

/// What the sign says. The raw values are simulator/rules.js's state names.
enum BarState: String, CaseIterable {
    case call, meeting, free, dnd
    case callMuted               // on a call with the mic muted: the same words, a slashed mic, the pill dimmed
    case callIn, busyIn          // 10 minutes before: a countdown on the right
    case late                    // a call has started without you: CALL and how late
    case lateMtg                 // a meeting in a room has started, with you at the Mac: MTG and how late
    case freeTil                 // you left a call early: free till its slot ends
    case callTbc, busyTbc        // tentative: a countdown to the start, then TILL the end
    case away, lunch, ooo        // not here (ooo: OUT OF + OFFICE on the right)
    case onSite                  // with a client: OUT ON + SITE on the right
    case nearby                  // you said so: in the building, not at your desk (or your word: setNearbyWord)
    case backIn                  // you said so: a countdown on the right to when you're back

    var word: String {
        switch self {
        case .call, .callMuted: return "ON A CALL"
        case .meeting: return "MEETING"
        case .free: return "FREE"
        case .dnd: return "DND"
        case .callIn: return "CALL IN"
        case .busyIn: return "BUSY IN"
        case .late, .lateMtg: return "LATE FOR"
        case .freeTil: return "FREE TILL"
        case .callTbc: return "CALL TBC"
        case .busyTbc: return "BUSY TBC"
        case .away: return "AWAY"
        case .lunch: return "LUNCH"
        case .ooo: return "OUT OF"
        case .onSite: return "OUT ON"
        case .nearby: return BarEngine.nearbyWord
        case .backIn: return "BACK IN"
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

    /// The calendar's warnings and "free, but booked": amber, between the
    /// green and the red, on the same vertical profile.
    static let amber = BarPalette(
        highlight: RGB(hex: 0xFFD38A), top: RGB(hex: 0xFFA21A), bottom: RGB(hex: 0x6B3B00),
        rimBottom: RGB(hex: 0x7D4C12), edge: RGB(hex: 0xE0A653), shadow: RGB(hex: 0x482500),
        flood: RGB(hex: 0xC07A14))

    /// Not here: away, at lunch, out of office, out on site.
    static let grey = BarPalette(
        highlight: RGB(hex: 0xC4C8D2), top: RGB(hex: 0x7E8492), bottom: RGB(hex: 0x272A31),
        rimBottom: RGB(hex: 0x3A3D45), edge: RGB(hex: 0x8E93A0), shadow: RGB(hex: 0x15161A),
        flood: RGB(hex: 0x5E636E))

    static func of(_ state: BarState) -> BarPalette {
        switch state {
        case .call, .callMuted, .meeting: return call
        case .free: return free
        case .dnd: return dnd
        case .callIn, .busyIn, .late, .lateMtg, .freeTil, .callTbc, .busyTbc: return amber
        case .away, .lunch, .ooo, .onSite, .nearby, .backIn: return grey
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

/// The moment a state is about, for the right of the pill: seconds to go
/// (or, for LATE, seconds since the start; for TBC, 0 once the meeting is
/// on) and that moment's hour and minute.
struct BarTimer {
    let left: Double
    let h: Int, m: Int
}

/// What goes right of the pill: a top line in the clock's face and a bottom
/// line at half brightness. `blink`: whether the colon dims on odd seconds.
struct RightText {
    let top: String, bottom: String, blink: Bool
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

    /*
     * Looking after the wall's screen. When nothing's going on — FREE, or
     * not here (quiet) — the same screen can stay up for hours, so:
     *   - after half an hour unchanged the LEDs ease down to about 60% of
     *     their light, over 20 s; any change brings them straight back
     *   - every 15 minutes the pill's icon and word scroll out to the left
     *     and back in from the right, as a sign does now and then
     * Calls, meetings and warnings always show at full brightness, still.
     */
    enum Rest {
        static let after = 30 * 60.0
        static let fade = 20.0
        /// Before the LED gamma: 0.83 of the value is about 60% of the light.
        static let level = 0.83
    }
    enum Scroll {
        static let every = 15 * 60.0
        static let duration = 2.4     // out to the left in half of it, in from the right in the other
    }

    /// FREE, or not here: nobody's kept out, so the sign can rest.
    static func quiet(_ state: BarState) -> Bool {
        switch state {
        case .free, .away, .lunch, .ooo, .onSite, .nearby: return true
        default: return false
        }
    }

    /// How bright the LEDs are, 0...1: 1 except in a quiet state that's been up half an hour.
    /// In hundredths, so a fade reuses its LEDs' drawings.
    static func restAt(_ now: Double, _ state: BarState, since: Double) -> Double {
        guard quiet(state) else { return 1 }
        let k = smooth(Rest.after, Rest.after + Rest.fade, now - since)
        return (lerp(1, Rest.level, k) * 100).rounded() / 100
    }

    /// How far the pill's icon and word are scrolled, in LEDs: 0 except for a moment every
    /// 15 minutes of a quiet state, once the announcement's done.
    static func scrollAt(_ now: Double, _ state: BarState, since: Double, pillW: Double) -> Int {
        guard quiet(state) else { return 0 }
        let s = now - since - Timing.settled
        guard s >= Scroll.every else { return 0 }
        let p = s.truncatingRemainder(dividingBy: Scroll.every), half = Scroll.duration / 2
        guard p < Scroll.duration else { return 0 }
        // far enough that the icon and word, shadow and all, are out of the pill
        let away = (Double(statusContentWidth(state)) + pillW) / 2 + 2
        return p < half ? -jsRound(away * easeIn(p / half)) : jsRound(away * (1 - easeOut((p - half) / half)))
    }

    static let days = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

    /// Pictograms, drawn in the firmware's style: white, hard shadow. The mic
    /// echoes the firmware's on_call theme; the tick is the "available" mark
    /// every meeting app uses; the moon is Do Not Disturb's, as on the Mac.
    /// Rows top to bottom.
    static let icons: [BarState: [String]] = baseIcons.merging([.freeTil: baseIcons[.free]!]) { a, _ in a }
    private static let baseIcons: [BarState: [String]] = [
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
        ],
        // the mic, slashed, with the gap on one side as the Mac's mic.slash: muted
        .callMuted: [
            "#..###...",
            ".#.####..",
            ".#.####..",
            "..#.###..",
            "..##.##..",
            "#.###.#.#",
            "#.###.#.#",
            "#..###..#",
            ".#....#..",
            "..######.",
            "....#..#.",
            "..#####.#"
        ],
        // two people
        .meeting: [
            ".###...###.",
            "#####.#####",
            "#####.#####",
            ".###...###.",
            "...........",
            ".###...###.",
            "#####.#####",
            "#####.#####",
            "#####.#####"
        ],
        .callIn: soonIcon, .busyIn: soonIcon,
        .late: lateIcon, .lateMtg: lateIcon,
        .callTbc: tbcIcon, .busyTbc: tbcIcon,
        // a fork and a knife
        .lunch: [
            "#.#.#..#",
            "#.#.#.##",
            "#.#.#.##",
            "#.#.#.##",
            "#####.##",
            ".###..##",
            "..#....#",
            "..#....#",
            "..#....#",
            "..#....#",
            "..#....#"
        ],
        // someone walking: around the building
        .nearby: [
            "....##...",
            "....##...",
            ".........",
            "...####..",
            "..#.##.#.",
            ".#..##..#",
            "....##...",
            "...#..#..",
            "...#...#.",
            "..#....#.",
            ".#......#"
        ],
        // into the door: back in a few minutes
        .backIn: [
            "#####......",
            "#..........",
            "#...#......",
            "#..##......",
            "#.#########",
            "#.#########",
            "#..##......",
            "#...#......",
            "#..........",
            "#####......"
        ],
        // out of the door
        .away: [
            "#####......",
            "#..........",
            "#.......#..",
            "#.......##.",
            "#..########",
            "#..########",
            "#.......##.",
            "#.......#..",
            "#..........",
            "#####......"
        ],
        // a plane seen from above, nose to the right, wings swept back
        .ooo: [
            "....##......",
            ".....##.....",
            "......##....",
            "#......##...",
            "##.....###..",
            "############",
            "##.....###..",
            "#......##...",
            "......##....",
            ".....##.....",
            "....##......"
        ],
        // a map pin: somewhere else
        .onSite: [
            "..#####..",
            ".#######.",
            "###...###",
            "##.....##",
            "###...###",
            ".#######.",
            ".#######.",
            "..#####..",
            "...###...",
            "...###...",
            "....#...."
        ]
    ]
    /// A warning sign.
    private static let lateIcon = [
        ".....#.....",
        "....###....",
        "...##.##...",
        "...##.##...",
        "..###.###..",
        "..###.###..",
        ".#########.",
        ".####.####.",
        "###########"
    ]
    /// A bell: something's about to start.
    private static let soonIcon = [
        ".....#.....",
        "...#####...",
        "..#######..",
        "..#######..",
        "..#######..",
        "..#######..",
        ".#########.",
        "###########",
        "...........",
        "....###...."
    ]
    /// A pencil: pencilled in, not confirmed.
    private static let tbcIcon = [
        "........#.",
        ".......###",
        "......###.",
        ".....###..",
        "....###...",
        "...###....",
        "..###.....",
        ".###......",
        ".##.......",
        "#........."
    ]
    /// Rows above the baseline for the icon's bottom row.
    static let iconLift: [BarState: Int] = [
        .call: -1, .callMuted: -1, .free: 1, .dnd: -1, .meeting: 0, .callIn: 0, .busyIn: 0, .late: 0, .lateMtg: 0,
        .freeTil: 1, .callTbc: 0, .busyTbc: 0, .lunch: -1, .away: 0, .ooo: -1, .onSite: -1, .backIn: 0, .nearby: 0
    ]

    /// The announcement. busy_regular_14 is busy_regular_7 doubled, so
    /// everything about it is at twice the scale: a two-step shadow, and word
    /// spaces trimmed to match. DO NOT DISTURB is too wide for it, so it's set
    /// in the status face across the whole bar.
    struct Hero {
        let word: String, font: String, base: Int, depth: Int, space: Int?
    }
    static func hero(_ state: BarState) -> Hero {
        switch state {
        case .call, .callMuted: return Hero(word: "ON A CALL", font: "busy_regular_14", base: 14, depth: 2, space: 6)
        case .free: return Hero(word: "FREE", font: "busy_regular_14", base: 14, depth: 2, space: 6)
        case .dnd: return Hero(word: "DO NOT DISTURB", font: "busy_bold_10", base: 12, depth: 1, space: nil)
        case .meeting: return Hero(word: "MEETING", font: "busy_regular_14", base: 14, depth: 2, space: 6)
        case .callIn: return Hero(word: "CALL SOON", font: "busy_regular_14", base: 14, depth: 2, space: 6)
        case .busyIn: return Hero(word: "BUSY SOON", font: "busy_regular_14", base: 14, depth: 2, space: 6)
        case .late: return Hero(word: "LATE FOR CALL", font: "busy_bold_10", base: 12, depth: 1, space: nil)
        case .lateMtg: return Hero(word: "LATE FOR MTG", font: "busy_bold_10", base: 12, depth: 1, space: nil)
        case .freeTil: return Hero(word: "FREE TILL {t}", font: "busy_bold_10", base: 12, depth: 1, space: nil)
        case .callTbc: return Hero(word: "CALL TBC", font: "busy_regular_14", base: 14, depth: 2, space: 6)
        case .busyTbc: return Hero(word: "BUSY TBC", font: "busy_regular_14", base: 14, depth: 2, space: 6)
        case .away: return Hero(word: "AWAY", font: "busy_regular_14", base: 14, depth: 2, space: 6)
        case .lunch: return Hero(word: "LUNCH", font: "busy_regular_14", base: 14, depth: 2, space: 6)
        case .ooo: return Hero(word: "OUT OF OFFICE", font: "busy_bold_10", base: 12, depth: 1, space: nil)
        case .onSite: return Hero(word: "OUT ON SITE", font: "busy_bold_10", base: 12, depth: 1, space: nil)
        case .nearby: return nearbyHero
        case .backIn: return Hero(word: "BACK IN", font: "busy_regular_14", base: 14, depth: 2, space: 6)
        }
    }

    /// An announcement's words; {t} is the time the state is about (FREE TILL 11:00).
    static func heroWord(_ state: BarState, _ timer: BarTimer?) -> String {
        let w = hero(state).word
        guard w.contains("{t}") else { return w }
        if let timer { return w.replacingOccurrences(of: "{t}", with: String(format: "%02d:%02d", timer.h, timer.m)) }
        return w.replacingOccurrences(of: " TILL {t}", with: "").replacingOccurrences(of: "{t}", with: "")
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
                       since: Double, clock: ClockReading, timer: BarTimer? = nil) {
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
            drawHero(&f, now: now, state: state, pal: pal, timer: timer)
            // ...and the new one springs back up
            let r = (e - Timing.swap) / Timing.swap
            if r < 1 { shiftDown(&f, jsRound(Timing.press * (1 - easeOut(r)))) }
        } else if e < collapseEnd {
            let k = easeInOut((e - collapseStart) / Timing.collapse)
            let w = lerp(Layout.heroW, Layout.statusW, k)
            let edge = Layout.heroX + w
            drawPill(&f, x0: Layout.heroX, w: w, pal: pal, sheen: sheenAt(now), dim: pulseAt(now, state))
            // the announcement face gives way to icon + status face as the pill shrinks:
            // out before the big word can outgrow the pill, in once there's room
            let fadeOut = 1 - smooth(0.08, 0.34, k)
            let fadeIn = smooth(0.14, 0.4, k)         // overlapping, so the pill is never empty
            let clip = (lo: Int(Layout.heroX) + 1, hi: Int(edge.rounded(.down)) - 1)
            if fadeOut > 0 {
                let hw = Double(heroWidth(state, timer))
                var style = heroStyle(state, pal, alpha: fadeOut)
                style.clip = clip
                let h = hero(state)
                drawText(&f, font: h.font, heroWord(state, timer),
                         x: Layout.heroX + (max(w, hw + 6) - hw) / 2 + 0.5,
                         baseY: h.base, colour: white, style: style)
            }
            if fadeIn > 0 {
                drawStatusContent(&f, now: now, state: state, pal: pal, x0: Layout.heroX, w: w, alpha: fadeIn, clip: clip)
            }
            // the time slides in from the right as the pill makes room, as the
            // firmware's timer label does
            let slide = jsRound(Layout.slideIn * (1 - easeOut((e - collapseStart) / Timing.collapse)))
            drawRight(&f, state: state, clock: clock, timer: timer, slide: slide, minX: Int(edge.rounded(.up)) + 2)
        } else {
            drawSteady(&f, now: now, state: state, clock: clock, timer: timer, slide: 0,
                       scroll: scrollAt(now, state, since: since, pillW: Layout.statusW))
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

    static func heroWidth(_ state: BarState, _ timer: BarTimer?) -> Int {
        let h = hero(state)
        return textWidth(h.font, heroWord(state, timer), space: h.space)
    }

    /// The muted mic flashes, slowly, so a glance tells the room it can talk:
    /// on 1.1 s, a 0.2 s fade, off 0.5 s, a 0.2 s fade back — every 2 s. The
    /// words stay put.
    static func iconAlphaAt(_ now: Double, _ state: BarState) -> Double {
        guard state == .callMuted else { return 1 }
        let p = now.truncatingRemainder(dividingBy: 2.0)
        if p < 1.1 { return 1 }
        if p < 1.3 { return 1 - (p - 1.1) / 0.2 }
        if p < 1.8 { return 0 }
        return (p - 1.8) / 0.2
    }

    /// How far the pill is dimmed. LATE FOR (a call or a meeting) breathes: by up to a third and
    /// back every 1.6 s, so it reads as urgent rather than as an opening. ON A
    /// CALL with the mic muted glows at 45%: bright means quiet, dim means the
    /// room can talk.
    static func pulseAt(_ now: Double, _ state: BarState) -> Double {
        if state == .callMuted { return 0.55 }
        guard state == .late || state == .lateMtg else { return 0 }
        return 0.34 * (0.5 - 0.5 * cos(2 * Double.pi * now.truncatingRemainder(dividingBy: 1.6) / 1.6))
    }

    static func drawHero(_ f: inout LEDFrame, now: Double, state: BarState, pal: BarPalette, timer: BarTimer?) {
        drawPill(&f, x0: Layout.heroX, w: Layout.heroW, pal: pal, sheen: sheenAt(now), dim: pulseAt(now, state))
        let w = Double(heroWidth(state, timer))
        let h = hero(state)
        drawText(&f, font: h.font, heroWord(state, timer), x: Layout.heroX + (Layout.heroW - w) / 2 + 0.5,
                 baseY: h.base, colour: white, style: heroStyle(state, pal))
    }

    /// `scroll`: the icon and word moved this many LEDs (scrollAt), kept inside the pill.
    static func drawSteady(_ f: inout LEDFrame, now: Double, state: BarState, clock: ClockReading,
                           timer: BarTimer?, slide: Int, scroll: Int = 0) {
        let pal = BarPalette.of(state)
        drawPill(&f, x0: Layout.statusX, w: Layout.statusW, pal: pal, sheen: sheenAt(now), dim: pulseAt(now, state))
        let clip: (lo: Int, hi: Int)? = scroll == 0 ? nil
            : (lo: Int(Layout.statusX) + 1, hi: Int(Layout.statusX + Layout.statusW) - 1)
        drawStatusContent(&f, now: now, state: state, pal: pal, x0: Layout.statusX + Double(scroll), w: Layout.statusW,
                          alpha: 1, clip: clip)
        drawRight(&f, state: state, clock: clock, timer: timer, slide: slide, minX: 0)
    }

    /*
     * What goes right of the pill (or under it, stacked). Usually the time and
     * the day; states that are about another moment show it instead.
     */
    static func rightText(_ state: BarState, clock: ClockReading, timer: BarTimer?) -> RightText {
        let day = days[((clock.dow % 7) + 7) % 7] + " " + String(clock.date)
        let now = String(format: "%02d:%02d", clock.h, clock.m)
        if let timer {
            let at = String(format: "%02d:%02d", timer.h, timer.m)
            switch state {
            case .dnd, .call, .callMuted, .meeting, .lunch:
                // Do Not Disturb, on a call / in a meeting, or at lunch (from the calendar):
                // how long till you're free, or back, and when
                let c = countdownText(timer)
                return RightText(top: c.mmss, bottom: c.until, blink: true)
            case .callIn, .busyIn, .backIn:
                // a warning, or back in a few minutes: a countdown to it, and when
                return RightText(top: countdownText(timer).mmss, bottom: "AT " + at, blink: true)
            case .callTbc, .busyTbc:
                // tentative: a countdown to the start, then the end time once it's on
                return timer.left > 0 ? RightText(top: countdownText(timer).mmss, bottom: "AT " + at, blink: true)
                                      : RightText(top: now, bottom: "TILL " + at, blink: true)
            case .late:
                return RightText(top: "CALL", bottom: "+" + elapsedText(timer.left), blink: false)
            case .lateMtg:
                return RightText(top: "MTG", bottom: "+" + elapsedText(timer.left), blink: false)
            case .freeTil:
                return RightText(top: at, bottom: day, blink: false)
            default:
                break
            }
        }
        if state == .ooo { return RightText(top: now, bottom: "OFFICE", blink: true) }
        if state == .onSite { return RightText(top: now, bottom: "SITE", blink: true) }
        return RightText(top: now, bottom: day, blink: true)
    }

    /// Minutes and seconds since something started, rounded down: 00:00, 01:20.
    static func elapsedText(_ secs: Double) -> String {
        let s = min(max(Int((secs + 1e-9).rounded(.down)), 0), 99 * 60 + 59)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Right of the pill. `slide` pushes it right (entrance); nothing is drawn left of `minX`.
    static func drawRight(_ f: inout LEDFrame, state: BarState, clock: ClockReading, timer: BarTimer?,
                          slide: Int, minX: Int) {
        let text = rightText(state, clock: clock, timer: timer)
        let tw = clockTextWidth(Layout.timeFont, text.top)
        let bw = textWidth(Layout.dateFont, text.bottom)
        let x0 = Layout.clockX + slide
        let clip = (lo: max(minX, Layout.clockX - 3), hi: cols)
        let colon = text.blink && clock.s % 2 == 1 ? 0.4 : 1.0
        drawClockText(&f, font: Layout.timeFont, text.top, x: x0 + jsRound(Double(Layout.clockW - tw) / 2),
                      baseY: Layout.timeBase, colour: white, style: TextStyle(clip: clip), colonAlpha: colon)
        drawText(&f, font: Layout.dateFont, text.bottom, x: Double(x0 + jsRound(Double(Layout.clockW - bw) / 2)),
                 baseY: Layout.dateBase, colour: white, style: TextStyle(alpha: 0.5, clip: clip))
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

    /// The icon and the gap after it; nothing for a state without an icon.
    static func iconWidth(_ state: BarState) -> Int {
        icons[state].map { ($0.first?.count ?? 0) + Layout.iconGap } ?? 0
    }

    /// Icon + word, centred as one unit.
    static func statusContentWidth(_ state: BarState) -> Int {
        iconWidth(state) + textWidth(Layout.statusFont, state.word)
    }

    static func drawStatusContent(_ f: inout LEDFrame, now: Double, state: BarState, pal: BarPalette, x0: Double, w: Double,
                                  alpha: Double, clip: (lo: Int, hi: Int)?) {
        let x = jsRound(x0 + (w - Double(statusContentWidth(state))) / 2)
        if let icon = icons[state] {
            drawIcon(&f, rows: icon, x: x, bottomY: Layout.statusBase - (iconLift[state] ?? 0),
                     colour: white, shadow: pal.shadow, alpha: alpha * iconAlphaAt(now, state), clip: clip)
        }
        drawText(&f, font: Layout.statusFont, state.word, x: Double(x + iconWidth(state)),
                 baseY: Layout.statusBase, colour: white,
                 style: TextStyle(shadow: pal.shadow, shadowAlpha: 0.9 * alpha, alpha: alpha, clip: clip))
    }

    // MARK: Clock

    /*
     * A countdown in the clock's place and face — the firmware's timer
     * screen — with its end time beneath at half brightness (Do Not Disturb,
     * a call, a meeting), or the start time (CALL IN). Whole seconds, rounded
     * up, so it reads 30:00 as it starts and 00:01 last; 1H05 from an hour.
     */
    static func countdownText(_ timer: BarTimer) -> (mmss: String, until: String) {
        let until = String(format: "TILL %02d:%02d", timer.h, timer.m)
        let secs = max(Int((timer.left - 1e-9).rounded(.up)), 0)
        // an hour or more reads as hours and minutes: 1H05
        if secs >= 3600 { return (String(format: "%dH%02d", min(secs / 3600, 9), (secs % 3600) / 60), until) }
        return (String(format: "%02d:%02d", secs / 60, secs % 60), until)
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
                // only the colon blinks: letters (the H in 1H05, CALL) stay lit
                var s = style
                if ch == ":" { s.alpha *= colonAlpha }
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
                         h rowsTall: Int = LEDFrame.rows, dim: Double = 0) {
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
                if dim > 0 { c = c * (1 - dim) }
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

        /// A line of the announcement: the 14-row face, or the 10-row one
        /// where a line won't fit the 82-LED pill in it.
        struct Line {
            let t: String
            var font = "busy_regular_14"
            var tracking = 0
            init(_ t: String, font: String = "busy_regular_14", tracking: Int = 0) {
                self.t = t; self.font = font; self.tracking = tracking
            }
        }

        /// The announcement fills the panel, a word or two per line.
        static func hero(_ state: BarState) -> [Line] {
            switch state {
            case .call, .callMuted: return [Line("ON A"), Line("CALL")]
            case .free: return [Line("FREE")]
            case .dnd: return [Line("DO NOT"), Line("DISTURB")]
            case .meeting: return [Line("MEETING", tracking: -1)]
            case .callIn: return [Line("CALL"), Line("SOON")]
            case .busyIn: return [Line("BUSY"), Line("SOON")]
            case .late: return [Line("LATE"), Line("FOR CALL", font: "busy_bold_10")]
            case .lateMtg: return [Line("LATE"), Line("FOR MTG", font: "busy_bold_10")]
            case .freeTil: return [Line("FREE"), Line("TILL {t}", font: "busy_bold_10")]
            case .callTbc: return [Line("CALL"), Line("TBC")]
            case .busyTbc: return [Line("BUSY"), Line("TBC")]
            case .away: return [Line("AWAY")]
            case .lunch: return [Line("LUNCH")]
            case .ooo: return [Line("OUT OF"), Line("OFFICE")]
            case .onSite: return [Line("OUT ON"), Line("SITE")]
            case .nearby: return BarEngine.nearbyStackedHero
            case .backIn: return [Line("BACK"), Line("IN")]
            }
        }

        /// Each face's line height, shadow depth and word space.
        static func lineFont(_ font: String) -> (h: Int, depth: Int, space: Int?) {
            font == "busy_bold_10" ? (10, 1, nil) : (14, 2, 6)
        }
    }

    // MARK: - The Nearby key's word

    /*
     * NEARBY, or a word of your own (W HOUSE) from Settings ▸ Away & screen saver. The
     * sign says it wherever it would say NEARBY. One for every view of the
     * bar, set with setNearbyWord: the app sets it from its settings, the
     * screen saver from the app's answer.
     */
    static let nearbyDefault = "NEARBY"
    /// Room for it, in LEDs: beside the walker in the pill, as ON A CALL
    /// has beside its mic, and beneath the walker on a Stream Deck key in
    /// the 5-row face (streamdeck/src/key.js).
    static let nearbyRoom = (pill: 76, key: 34)

    private(set) static var nearbyWord = nearbyDefault
    private(set) static var nearbyHero = Hero(word: nearbyDefault, font: "busy_regular_14", base: 14, depth: 2, space: 6)
    private(set) static var nearbyStackedHero = [Stacked.Line(nearbyDefault)]

    /// What a word won't go on: a character the fonts don't have, the sign, or the Stream Deck key.
    enum NearbyProblem: String { case characters, sign, key }

    /// A word as the sign sets it: capitals, single spaces.
    static func signWord(_ word: String) -> String {
        word.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").uppercased()
    }

    /// Why a word can't be the Nearby key's, or nil if it can.
    static func nearbyProblem(_ word: String) -> NearbyProblem? {
        let w = signWord(word)
        // the fonts have plain ASCII only
        guard w.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else { return .characters }
        if iconWidth(.nearby) + textWidth(Layout.statusFont, w) > nearbyRoom.pill { return .sign }
        if textWidth("busy_regular_5", w) > nearbyRoom.key { return .key }
        return nil
    }

    /// The word the sign says for `word`: NEARBY for none, or for one that won't do.
    static func nearbyWordOf(_ word: String?) -> String {
        let w = signWord(word ?? "")
        return !w.isEmpty && nearbyProblem(w) == nil ? w : nearbyDefault
    }

    /// Sets the word everywhere the bar says NEARBY, and says which it took.
    /// Its announcement on the wide bar is in the 14-row face where it fits,
    /// as BUSY SOON is, else the status face, as DO NOT DISTURB.
    @discardableResult
    static func setNearbyWord(_ word: String?) -> String {
        let w = nearbyWordOf(word)
        nearbyWord = w
        nearbyHero = Double(textWidth("busy_regular_14", w, space: 6)) <= Layout.heroW - 6
            ? Hero(word: w, font: "busy_regular_14", base: 14, depth: 2, space: 6)
            : Hero(word: w, font: "busy_bold_10", base: 12, depth: 1, space: nil)
        nearbyStackedHero = nearbyStackedLines(w)
        return w
    }

    /// Its announcement stacked: one line in the 14-row face, set a step
    /// tighter if it needs it, as MEETING is; else two, broken at the space
    /// that leaves the longer line shortest; else one in the 10-row face.
    private static func nearbyStackedLines(_ word: String) -> [Stacked.Line] {
        let room = Int(Stacked.pillW) - 2               // DISTURB's width
        func wide(_ t: String, _ tracking: Int) -> Int { textWidth("busy_regular_14", t, tracking: tracking, space: 6) }
        if wide(word, 0) <= room { return [Stacked.Line(word)] }
        if wide(word, -1) <= room { return [Stacked.Line(word, tracking: -1)] }
        var best: [Stacked.Line]?, longest = Int.max
        let chars = Array(word)
        for (i, ch) in chars.enumerated() where ch == " " {
            let a = String(chars[..<i]), b = String(chars[(i + 1)...])
            let l = max(wide(a, 0), wide(b, 0))
            if l <= room && l < longest { best = [Stacked.Line(a), Stacked.Line(b)]; longest = l }
        }
        return best ?? [Stacked.Line(word, font: "busy_bold_10")]
    }

    static func renderStacked(into f: inout LEDFrame, now: Double, state: BarState, prev: BarState?,
                              since: Double, clock: ClockReading, timer: BarTimer? = nil) {
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
            drawPill(&f, x0: Stacked.pillX, w: Stacked.pillW, pal: pal, sheen: sheenAt(now, cols: f.w), h: f.h,
                     dim: pulseAt(now, state))
            drawStackedHero(&f, state: state, pal: pal, alpha: 1, clipY: nil, timer: timer)
            let r = (e - Timing.swap) / Timing.swap
            if r < 1 { shiftDown(&f, jsRound(Timing.press * (1 - easeOut(r)))) }
        } else if e < collapseEnd {
            // the pill draws up from the whole panel to the top band
            let k = easeInOut((e - collapseStart) / Timing.collapse)
            let h = jsRound(lerp(Double(f.h), Double(Stacked.pillH), k))
            drawPill(&f, x0: Stacked.pillX, w: Stacked.pillW, pal: pal, sheen: sheenAt(now, cols: f.w), h: h,
                     dim: pulseAt(now, state))
            let fadeOut = 1 - smooth(0.08, 0.34, k)
            let fadeIn = smooth(0.14, 0.4, k)
            if fadeOut > 0 { drawStackedHero(&f, state: state, pal: pal, alpha: fadeOut, clipY: (1, h - 1), timer: timer) }
            if fadeIn > 0 {
                drawStatusContent(&f, now: now, state: state, pal: pal, x0: Stacked.pillX, w: Stacked.pillW, alpha: fadeIn, clip: nil)
            }
            // ...and the clock rises into the space it leaves
            let slide = jsRound(Stacked.slideIn * (1 - easeOut((e - collapseStart) / Timing.collapse)))
            drawStackedClock(&f, state: state, clock: clock, timer: timer, slide: slide, minY: h + 2)
        } else {
            drawStackedSteady(&f, now: now, state: state, clock: clock, timer: timer, slide: 0,
                              scroll: scrollAt(now, state, since: since, pillW: Stacked.pillW))
        }

        if e < Timing.wave { drawShockwave(&f, progress: e / Timing.wave, pal: pal) }
    }

    static func drawStackedSteady(_ f: inout LEDFrame, now: Double, state: BarState, clock: ClockReading,
                                  timer: BarTimer?, slide: Int, scroll: Int = 0) {
        let pal = BarPalette.of(state)
        drawPill(&f, x0: Stacked.pillX, w: Stacked.pillW, pal: pal, sheen: sheenAt(now, cols: f.w), h: Stacked.pillH,
                 dim: pulseAt(now, state))
        let clip: (lo: Int, hi: Int)? = scroll == 0 ? nil
            : (lo: Int(Stacked.pillX) + 1, hi: Int(Stacked.pillX + Stacked.pillW) - 1)
        drawStatusContent(&f, now: now, state: state, pal: pal, x0: Stacked.pillX + Double(scroll), w: Stacked.pillW,
                          alpha: 1, clip: clip)
        drawStackedClock(&f, state: state, clock: clock, timer: timer, slide: slide, minY: 0)
    }

    static func drawStackedHero(_ f: inout LEDFrame, state: BarState, pal: BarPalette, alpha: Double,
                                clipY: (lo: Int, hi: Int)?, timer: BarTimer?) {
        let at = timer.map { String(format: "%02d:%02d", $0.h, $0.m) } ?? ""
        let lines = Stacked.hero(state)
            .map { Stacked.Line($0.t.replacingOccurrences(of: "{t}", with: at), font: $0.font, tracking: $0.tracking) }
            .filter { !$0.t.trimmingCharacters(in: .whitespaces).isEmpty && $0.t != "TILL" && $0.t != "TILL " }
        var block = (lines.count - 1) * Stacked.heroGap
        for l in lines { block += Stacked.lineFont(l.font).h }
        var top = jsRound(Double(f.h - block) / 2)
        for l in lines {
            // set as the bar's announcement: the 14-row face with a two-step
            // shadow and trimmed spaces, the 10-row face with a one-step shadow
            let lf = Stacked.lineFont(l.font)
            var style = TextStyle(shadow: pal.shadow, shadowDepth: lf.depth, shadowAlpha: 0.9 * alpha, alpha: alpha,
                                  space: lf.space, tracking: l.tracking)
            style.clipY = clipY
            let w = Double(textWidth(l.font, l.t, tracking: l.tracking, space: lf.space))
            drawText(&f, font: l.font, l.t, x: Stacked.pillX + (Stacked.pillW - w) / 2 + 0.5,
                     baseY: top + lf.h - 1, colour: white, style: style)
            top += lf.h + Stacked.heroGap
        }
    }

    /// The time and the day — or Do Not Disturb's countdown and its end
    /// time — centred beneath the pill. `slide` pushes it down (entrance);
    /// nothing is drawn above row `minY`.
    static func drawStackedClock(_ f: inout LEDFrame, state: BarState, clock: ClockReading, timer: BarTimer?,
                                 slide: Int, minY: Int) {
        let text = rightText(state, clock: clock, timer: timer)
        let clipY = (lo: minY, hi: f.h)
        let colon = text.blink && clock.s % 2 == 1 ? 0.4 : 1.0
        let bw = clockTextWidth(Stacked.bigFont, text.top)
        let sw = textWidth(Stacked.smallFont, text.bottom)
        drawClockText(&f, font: Stacked.bigFont, text.top, x: jsRound(Double(f.w - bw) / 2), baseY: Stacked.bigBase + slide,
                      colour: white, style: TextStyle(clipY: clipY), colonAlpha: colon)
        drawText(&f, font: Stacked.smallFont, text.bottom, x: Double(jsRound(Double(f.w - sw) / 2)),
                 baseY: Stacked.smallBase + slide, colour: white, style: TextStyle(alpha: 0.5, clipY: clipY))
    }

    // MARK: - World clocks

    /*
     * Local time and three more cities, while the sign says FREE. Any mix of
     * four layouts, each on its own timing:
     *   turns  — the split: the other cities in turn on the left, a narrower
     *            pill in the middle, local on the right
     *   rest   — after a while of FREE, the pill draws in to a chip and the
     *            four take the bar, till anything changes
     *   board  — now and then the bar rolls over to a four-column board
     *   ticker — the other cities run through the pill
     * The app works out each city's time; this only draws it.
     *
     *   split  cols 1-31 the other cities · 35-82 the pill · 86-116 local
     *   rest   cols 1-16 the chip · from col 19 two lines of two cities
     *   board  four columns of 29, each city above its time
     */
    struct WorldZone {
        let code: String
        let h: Int, m: Int
        let dow: Int, date: Int
        let dayDelta: Int          // 1: tomorrow there; -1: yesterday
    }

    struct WorldPlan {
        struct Turns { var on = true; var secs = 5.0 }
        struct Resting { var on = false; var mins = 30.0 }
        struct Board { var on = false; var mins = 5.0; var secs = 20.0 }
        struct Ticker { var on = false; var mins = 15.0 }
        enum Clash: String { case wait, skip }
        struct Rules { var restHolds = true; var clash = Clash.wait; var tickerForScroll = true }
        var zones: [WorldZone] = []        // local first
        var turns = Turns(), rest = Resting(), board = Board(), ticker = Ticker(), rules = Rules()
    }

    enum World {
        static let leftX = 1, leftW = 31, pillX = 35.0, pillW = 48.0, rightX = 86, rightW = 31
        static let slideIn = 40.0          // the clocks slide in from either side as the pill draws in
        static let roll = 0.45             // the left clock rolls up to the next city
        static let chipW = 16.0, restIn = 0.8     // resting: the pill draws in to a chip over this long
        static let gridX = 19, gridCell = 52, gridLabel = 14, gridGap = 3
        static let boardCell = 29, boardRoll = 0.5, boardGap = 2
        static let tickerSpeed = 24.0, tickerGap = 12     // LEDs a second; LEDs between the cities
    }

    private static func hhmm(_ z: WorldZone) -> String { String(format: "%02d:%02d", z.h, z.m) }
    /// Tomorrow or yesterday there.
    private static func dayMark(_ z: WorldZone) -> String { z.dayDelta > 0 ? "+1" : z.dayDelta < 0 ? "-1" : "" }
    private static func cityLine(_ z: WorldZone) -> String { z.code + (dayMark(z).isEmpty ? "" : " " + dayMark(z)) }
    private static func colonOf(_ clock: ClockReading) -> Double { clock.s % 2 == 1 ? 0.4 : 1 }
    private static func dayOf(_ z: WorldZone) -> String { days[((z.dow % 7) + 7) % 7] + " " + String(z.date) }
    /// The pill FREE sits in: today's, or the split's.
    private static func worldPill(_ world: WorldPlan) -> (x: Double, w: Double) {
        world.turns.on ? (x: World.pillX, w: World.pillW) : (x: Layout.statusX, w: Layout.statusW)
    }

    /// A clock beside the pill: the time in the clock's face, a line beneath at
    /// half brightness. dy moves it down (a roll), dx across (an entrance);
    /// nothing is drawn outside clip.
    private static func drawSideClock(_ f: inout LEDFrame, clock: ClockReading, _ top: String, _ bottom: String,
                                      x: Int, w: Int, dy: Int, dx: Int, alpha: Double, clip: (lo: Int, hi: Int)) {
        let tw = clockTextWidth(Layout.timeFont, top), bw = textWidth(Layout.dateFont, bottom)
        drawClockText(&f, font: Layout.timeFont, top, x: x + dx + jsRound(Double(w - tw) / 2), baseY: Layout.timeBase + dy,
                      colour: white, style: TextStyle(alpha: alpha, clip: clip), colonAlpha: colonOf(clock))
        drawText(&f, font: Layout.dateFont, bottom, x: Double(x + dx + jsRound(Double(w - bw) / 2)), baseY: Layout.dateBase + dy,
                 colour: white, style: TextStyle(alpha: 0.5 * alpha, clip: clip))
    }

    /// The other cities on the left, one at a time, rolling up to the next
    /// every turns.secs seconds. slide pushes it left; nothing right of maxX.
    private static func drawLeftTurns(_ f: inout LEDFrame, clock: ClockReading, world: WorldPlan, t: Double, slide: Int,
                                      maxX: Int, alpha: Double) {
        let others = Array(world.zones.dropFirst()), n = others.count
        guard n > 0 else { return }
        let dwell = world.turns.secs, tt = max(t, 0)
        let i = Int((tt / dwell).rounded(.down)) % n, p = tt.truncatingRemainder(dividingBy: dwell)
        // the first city is there from the start; each after it rolls in
        let k = n < 2 || tt < dwell || p >= World.roll ? 1 : easeInOut(p / World.roll)
        let clip = (lo: 0, hi: maxX)
        if k < 1 {
            let z = others[(i - 1 + n) % n]
            drawSideClock(&f, clock: clock, hhmm(z), cityLine(z), x: World.leftX, w: World.leftW,
                          dy: -jsRound(k * Double(rows + 1)), dx: -slide, alpha: alpha, clip: clip)
        }
        let z = others[i]
        drawSideClock(&f, clock: clock, hhmm(z), cityLine(z), x: World.leftX, w: World.leftW,
                      dy: jsRound((1 - k) * Double(rows + 1)), dx: -slide, alpha: alpha, clip: clip)
    }

    /// Local time and the day, right of the split's pill.
    private static func drawRightLocal(_ f: inout LEDFrame, clock: ClockReading, world: WorldPlan, slide: Int, minX: Int,
                                       alpha: Double) {
        guard let z = world.zones.first else { return }
        drawSideClock(&f, clock: clock, hhmm(z), dayOf(z), x: World.rightX, w: World.rightW, dy: 0, dx: slide, alpha: alpha,
                      clip: (lo: minX, hi: cols))
    }

    /// FREE as the settings have it: today's layout, or the split. dx moves the
    /// tick and word (the scroll); empty leaves them out (the ticker's there).
    private static func drawWorldBase(_ f: inout LEDFrame, now: Double, t: Double, clock: ClockReading, world: WorldPlan,
                                      dx: Int, empty: Bool) {
        let pal = BarPalette.free, g = worldPill(world)
        f.clear()
        if world.turns.on {
            drawLeftTurns(&f, clock: clock, world: world, t: t, slide: 0, maxX: World.leftX + World.leftW + 1, alpha: 1)
            drawRightLocal(&f, clock: clock, world: world, slide: 0, minX: 0, alpha: 1)
        } else {
            drawRight(&f, state: .free, clock: clock, timer: nil, slide: 0, minX: 0)
        }
        drawPill(&f, x0: g.x, w: g.w, pal: pal, sheen: sheenAt(now))
        if !empty {
            let clip: (lo: Int, hi: Int)? = dx == 0 ? nil : (lo: Int(g.x) + 1, hi: Int(g.x + g.w) - 1)
            drawStatusContent(&f, now: now, state: .free, pal: pal, x0: g.x + Double(dx), w: g.w, alpha: 1, clip: clip)
        }
    }

    /// The word's quarter-hour scroll in a pill w wide, s seconds after FREE settled: as scrollAt.
    private static func worldScroll(_ s: Double, _ w: Double) -> Int {
        guard s >= Scroll.every else { return 0 }
        let p = s.truncatingRemainder(dividingBy: Scroll.every), half = Scroll.duration / 2
        guard p < Scroll.duration else { return 0 }
        let away = (Double(statusContentWidth(.free)) + w) / 2 + 2
        return p < half ? -jsRound(away * easeIn(p / half)) : jsRound(away * (1 - easeOut((p - half) / half)))
    }

    /// The ticker: how long the other cities are, and them running right to
    /// left through a pill at x0, w wide, t seconds in.
    private static func tickerWidth(_ world: WorldPlan) -> Int {
        let others = Array(world.zones.dropFirst())
        var w = 0
        for (i, z) in others.enumerated() {
            w += textWidth("busy_bold_10", z.code + " ") + clockTextWidth("busy_bold_10", hhmm(z))
            if !dayMark(z).isEmpty { w += 2 + textWidth("busy_regular_5", dayMark(z)) }
            if i < others.count - 1 { w += World.tickerGap }
        }
        return w
    }
    private static func drawTickerText(_ f: inout LEDFrame, world: WorldPlan, x0: Double, w: Double, t: Double) {
        let pal = BarPalette.free, clip = (lo: Int(x0) + 1, hi: Int(x0 + w) - 1)
        var x = jsRound(x0 + w - t * World.tickerSpeed)
        for z in world.zones.dropFirst() {
            let label = z.code + " ", mark = dayMark(z)
            drawText(&f, font: "busy_bold_10", label, x: Double(x), baseY: Layout.statusBase, colour: white,
                     style: TextStyle(shadow: pal.shadow, shadowAlpha: 0.9 * 0.7, alpha: 0.7, clip: clip))
            x += textWidth("busy_bold_10", label)
            x += drawClockText(&f, font: "busy_bold_10", hhmm(z), x: x, baseY: Layout.statusBase, colour: white,
                               style: TextStyle(shadow: pal.shadow, shadowAlpha: 0.9, alpha: 1, clip: clip), colonAlpha: 1)
            if !mark.isEmpty {
                drawText(&f, font: "busy_regular_5", mark, x: Double(x + 2), baseY: Layout.statusBase - 5, colour: white,
                         style: TextStyle(shadow: pal.shadow, shadowAlpha: 0.9 * 0.8, alpha: 0.8, clip: clip))
                x += 2 + textWidth("busy_regular_5", mark)
            }
            x += World.tickerGap
        }
    }
    /// Out goes the word, in run the cities, and back the word comes: how long, in a pill pillW wide.
    private static func tickerSpan(_ world: WorldPlan, pillW: Double) -> Double {
        Scroll.duration + (pillW + Double(tickerWidth(world))) / World.tickerSpeed
    }
    /// t: seconds into the ticker; s: since FREE settled, for the left clock.
    private static func drawWorldTicker(_ f: inout LEDFrame, now: Double, t: Double, s: Double, clock: ClockReading,
                                        world: WorldPlan) {
        let g = worldPill(world), half = Scroll.duration / 2
        let run = (g.w + Double(tickerWidth(world))) / World.tickerSpeed
        let away = (Double(statusContentWidth(.free)) + g.w) / 2 + 2
        if t < half {
            drawWorldBase(&f, now: now, t: s, clock: clock, world: world, dx: -jsRound(away * easeIn(t / half)), empty: false)
            return
        }
        if t >= half + run {
            drawWorldBase(&f, now: now, t: s, clock: clock, world: world,
                          dx: jsRound(away * (1 - easeOut(min((t - half - run) / half, 1)))), empty: false)
            return
        }
        drawWorldBase(&f, now: now, t: s, clock: clock, world: world, dx: 0, empty: true)
        drawTickerText(&f, world: world, x0: g.x, w: g.w, t: t - half)
    }

    /// The board: four columns, each city above its time, local in FREE's green.
    private static func drawWorldBoard(_ f: inout LEDFrame, clock: ClockReading, world: WorldPlan) {
        f.clear()
        let cell = World.boardCell
        for (i, z) in world.zones.prefix(4).enumerated() {
            let cx = 1 + i * cell, label = cityLine(z)
            let lw = textWidth("busy_regular_5", label)
            drawText(&f, font: "busy_regular_5", label, x: Double(cx + jsRound(Double(cell - lw) / 2)), baseY: 5,
                     colour: i == 0 ? BarPalette.free.top : white, style: TextStyle(alpha: i == 0 ? 1 : 0.55))
            let tw = clockTextWidth("busy_regular_7", hhmm(z))
            drawClockText(&f, font: "busy_regular_7", hhmm(z), x: cx + jsRound(Double(cell - tw) / 2) + 1, baseY: 14,
                          colour: white, style: TextStyle(), colonAlpha: colonOf(clock))
        }
    }
    /// Frame a rolling up and out, b following from below, gap rows behind.
    private static func rollFrames(_ f: inout LEDFrame, _ a: LEDFrame, _ b: LEDFrame, off: Int, gap: Int) {
        for y in 0..<f.h {
            let src = y + off
            for x in 0..<f.w {
                if src < f.h { f.set(x, y, a.get(x, src)) }
                else if src - f.h - gap >= 0 { f.set(x, y, b.get(x, src - f.h - gap)) }
                else { f.set(x, y, RGB(0, 0, 0)) }
            }
        }
    }
    private static func boardSpan(_ world: WorldPlan) -> Double { 2 * World.boardRoll + world.board.secs }
    /// t seconds into the board: up it rolls over `under`, stays, and rolls away again.
    private static func drawWorldBoardOn(_ f: inout LEDFrame, t: Double, world: WorldPlan,
                                         face: (inout LEDFrame) -> Void, under: (inout LEDFrame) -> Void) {
        let r = World.boardRoll, secs = world.board.secs, gap = World.boardGap, span = Double(f.h + gap)
        if t >= r && t < r + secs { face(&f); return }
        var a = LEDFrame(w: f.w, h: f.h), b = LEDFrame(w: f.w, h: f.h)
        if t < r {
            under(&a); face(&b)
            rollFrames(&f, a, b, off: jsRound(easeInOut(t / r) * span), gap: gap)
        } else {
            face(&a); under(&b)
            rollFrames(&f, a, b, off: jsRound(easeInOut(min((t - r - secs) / r, 1)) * span), gap: gap)
        }
    }

    /// Resting's grid: two lines of two, each city then its time; nothing left of minX.
    private static func drawWorldGrid(_ f: inout LEDFrame, clock: ClockReading, world: WorldPlan, x0: Int, alpha: Double,
                                      minX: Int) {
        let bases = [6, 15], clip = (lo: minX, hi: cols)
        for (i, z) in world.zones.prefix(4).enumerated() {
            let cx = x0 + (i % 2) * World.gridCell, base = bases[i / 2]
            drawText(&f, font: "busy_regular_5", z.code, x: Double(cx), baseY: base, colour: i == 0 ? BarPalette.free.top : white,
                     style: TextStyle(alpha: (i == 0 ? 1 : 0.55) * alpha, clip: clip))
            drawClockText(&f, font: "busy_bold_7", hhmm(z), x: cx + World.gridLabel + World.gridGap, baseY: base, colour: white,
                          style: TextStyle(alpha: alpha, clip: clip), colonAlpha: colonOf(clock))
        }
    }
    /// Resting, k of the way there: the pill slides left and draws in to the
    /// chip, what was beside it gives way, and the four slide in behind.
    private static func drawWorldRest(_ f: inout LEDFrame, now: Double, t: Double, clock: ClockReading, world: WorldPlan,
                                      k: Double) {
        let pal = BarPalette.free, ek = easeInOut(k), split = world.turns.on
        let fromX = split ? World.pillX : Layout.statusX, fromW = split ? World.pillW : Layout.statusW
        f.clear()
        let outA = 1 - smooth(0, 0.35, k), go = jsRound(20 * smooth(0, 0.4, k))
        if outA > 0 {
            if let z = world.zones.first {
                drawSideClock(&f, clock: clock, hhmm(z), dayOf(z), x: split ? World.rightX : Layout.clockX,
                              w: split ? World.rightW : Layout.clockW, dy: 0, dx: go, alpha: outA, clip: (lo: 0, hi: cols))
            }
            if split {
                drawLeftTurns(&f, clock: clock, world: world, t: t, slide: go, maxX: World.leftX + World.leftW + 1, alpha: outA)
            }
        }
        let x = lerp(fromX, Layout.statusX, ek), w = lerp(fromW, World.chipW, ek)
        drawPill(&f, x0: x, w: w, pal: pal, sheen: sheenAt(now))
        let icon = icons[.free] ?? []
        let ix = jsRound(lerp(Double(jsRound(fromX + (fromW - Double(statusContentWidth(.free))) / 2)),
                              Layout.statusX + Double(jsRound((World.chipW - Double(icon.first?.count ?? 0)) / 2)), ek))
        let clip = (lo: Int(x.rounded(.up)) + 1, hi: Int((x + w).rounded(.down)) - 1)
        drawIcon(&f, rows: icon, x: ix, bottomY: Layout.statusBase - (iconLift[.free] ?? 0), colour: white, shadow: pal.shadow,
                 alpha: 1, clip: clip)
        let wordA = 1 - smooth(0, 0.35, k)
        if wordA > 0 {
            drawText(&f, font: Layout.statusFont, BarState.free.word, x: Double(ix + iconWidth(.free)), baseY: Layout.statusBase,
                     colour: white, style: TextStyle(shadow: pal.shadow, shadowAlpha: 0.9 * wordA, alpha: wordA, clip: clip))
        }
        let inA = smooth(0.4, 1, k)
        if inA > 0 {
            drawWorldGrid(&f, clock: clock, world: world, x0: World.gridX + jsRound(30 * (1 - easeOut(k))), alpha: inA,
                          minX: jsRound(x + w) + 2)
        }
    }

    /// A call has just ended (e seconds into FREE): the announcement across the
    /// bar, then, with the split on, it draws in to the middle as both clocks
    /// slide back from the sides.
    private static func drawWorldSettle(_ f: inout LEDFrame, now: Double, e: Double, prev: BarState?, clock: ClockReading,
                                        world: WorldPlan) {
        let cs = Timing.swap + Timing.hold
        guard world.turns.on, e >= cs else {
            render(into: &f, now: now, state: .free, prev: prev, since: now - e, clock: clock, timer: nil)
            return
        }
        let pal = BarPalette.free
        f.clear()
        let p = min((e - cs) / Timing.collapse, 1), k = easeInOut(p)
        let x = lerp(Layout.heroX, World.pillX, k), w = lerp(Layout.heroW, World.pillW, k)
        drawPill(&f, x0: x, w: w, pal: pal, sheen: sheenAt(now))
        let clip = (lo: Int(x.rounded(.up)) + 1, hi: Int((x + w).rounded(.down)) - 1)
        let fadeOut = 1 - smooth(0.08, 0.34, k), fadeIn = smooth(0.14, 0.4, k)
        if fadeOut > 0 {
            let hw = Double(heroWidth(.free, nil))
            var style = heroStyle(.free, pal, alpha: fadeOut)
            style.clip = clip
            let h = hero(.free)
            drawText(&f, font: h.font, heroWord(.free, nil), x: x + (max(w, hw + 6) - hw) / 2 + 0.5, baseY: h.base,
                     colour: white, style: style)
        }
        if fadeIn > 0 { drawStatusContent(&f, now: now, state: .free, pal: pal, x0: x, w: w, alpha: fadeIn, clip: clip) }
        let slide = jsRound(World.slideIn * (1 - easeOut(p))), sideA = smooth(0.3, 0.75, p)
        if sideA > 0 {
            drawRightLocal(&f, clock: clock, world: world, slide: slide, minX: Int((x + w).rounded(.up)) + 2, alpha: sideA)
            drawLeftTurns(&f, clock: clock, world: world, t: 0, slide: slide, maxX: Int(x.rounded(.down)) - 1, alpha: sideA)
        }
    }

    /// The board or the ticker, from `at` for `dur` seconds after FREE settled.
    struct WorldEvent {
        enum Kind { case board, ticker }
        let kind: Kind
        let at: Double, dur: Double
    }

    /*
     * When the board and the ticker show, up to s seconds after FREE settled,
     * and when it rests. The ticker needs the pill, so it never runs over the
     * chip; the board can, if the rules let it. One at a time: when two fall
     * together the second waits for the first (or is skipped), and nothing
     * starts that would run into the rest.
     */
    static func worldSchedule(_ world: WorldPlan, upTo s: Double, pillW: Double) -> (events: [WorldEvent], rest: Double) {
        let r = world.rules
        let rest = world.rest.on ? world.rest.mins * 60 : Double.infinity
        var raw: [(kind: WorldEvent.Kind, due: Double, dur: Double)] = []
        let tickerFor = tickerSpan(world, pillW: pillW), boardFor = boardSpan(world)
        if world.ticker.on && world.ticker.mins > 0 {
            var at = world.ticker.mins * 60
            while at <= s && at < rest {
                raw.append((kind: .ticker, due: at, dur: tickerFor))
                at += world.ticker.mins * 60
            }
        }
        if world.board.on && world.board.mins > 0 {
            var at = world.board.mins * 60
            while at <= s && (!r.restHolds || at < rest) {
                raw.append((kind: .board, due: at, dur: boardFor))
                at += world.board.mins * 60
            }
        }
        raw.sort { $0.due != $1.due ? $0.due < $1.due : ($0.kind == .ticker && $1.kind != .ticker) }
        var events: [WorldEvent] = []
        var clear = 0.0
        for e in raw {
            if r.clash == .skip && e.due < clear { continue }
            let at = max(e.due, clear)
            let runsIntoRest = at < rest && at + e.dur > rest
            if runsIntoRest || (e.kind == .ticker && at >= rest) { continue }
            events.append(WorldEvent(kind: e.kind, at: at, dur: e.dur))
            clear = at + e.dur + 1
        }
        return (events, rest)
    }

    /// The bar s seconds after FREE settled (below 0: still settling, after prev), and what it's showing.
    @discardableResult
    static func worldAt(into f: inout LEDFrame, now: Double, s: Double, clock: ClockReading, world: WorldPlan,
                        prev: BarState?) -> String {
        if s < 0 {
            drawWorldSettle(&f, now: now, e: s + Timing.settled, prev: prev, clock: clock, world: world)
            return "settle"
        }
        let sch = worldSchedule(world, upTo: s, pillW: worldPill(world).w)
        let resting = s >= sch.rest, restK = min((s - sch.rest) / World.restIn, 1)
        for e in sch.events where s >= e.at && s < e.at + e.dur {
            switch e.kind {
            case .board:
                drawWorldBoardOn(&f, t: s - e.at, world: world,
                                 face: { (g: inout LEDFrame) in drawWorldBoard(&g, clock: clock, world: world) },
                                 under: { (g: inout LEDFrame) in
                                     if resting { drawWorldRest(&g, now: now, t: s, clock: clock, world: world, k: restK) }
                                     else { drawWorldBase(&g, now: now, t: s, clock: clock, world: world, dx: 0, empty: false) }
                                 })
                return "board"
            case .ticker:
                drawWorldTicker(&f, now: now, t: s - e.at, s: s, clock: clock, world: world)
                return "ticker"
            }
        }
        if resting {
            drawWorldRest(&f, now: now, t: s, clock: clock, world: world, k: restK)
            return "rest"
        }
        let dx = world.ticker.on && world.rules.tickerForScroll ? 0 : worldScroll(s, worldPill(world).w)
        drawWorldBase(&f, now: now, t: s, clock: clock, world: world, dx: dx, empty: false)
        return dx != 0 ? "scroll" : "base"
    }

    /*
     * The scene with world clocks on: as render, but FREE as the settings have
     * it, and, as FREE gives way, its face pressed down as the wave hits it.
     * prevFor: how long FREE had been up when it ended.
     */
    static func renderWorld(into f: inout LEDFrame, now: Double, state: BarState, prev: BarState?, since: Double,
                            clock: ClockReading, timer: BarTimer?, world: WorldPlan, prevFor: Double) {
        let e = now - since
        if state == .free {
            f.clear()
            worldAt(into: &f, now: now, s: e - Timing.settled, clock: clock, world: world, prev: prev)
            return
        }
        if prev == .free && e < Timing.swap {
            f.clear()
            worldAt(into: &f, now: now, s: prevFor - Timing.settled, clock: clock, world: world, prev: nil)
            shiftDown(&f, jsRound(Timing.press * easeIn(e / Timing.swap)))
            drawShockwave(&f, progress: e / Timing.wave, pal: BarPalette.of(state))
            return
        }
        render(into: &f, now: now, state: state, prev: prev, since: since, clock: clock, timer: timer)
    }

    // the same, stacked: the big clock stays local; the day line beneath takes each city in turn

    /// The day line: the day (i = 0) or a city and its time.
    private static func drawStackedTurn(_ f: inout LEDFrame, clock: ClockReading, world: WorldPlan, i: Int, dy: Int) {
        let font = Stacked.smallFont, base = Stacked.smallBase + dy, clipY = (lo: 35, hi: Stacked.rows)
        let z = world.zones[i]
        if i == 0 {
            let d = dayOf(z), w = textWidth(font, d)
            drawText(&f, font: font, d, x: Double(jsRound(Double(Stacked.cols - w) / 2)), baseY: base, colour: white,
                     style: TextStyle(alpha: 0.5, clipY: clipY))
            return
        }
        let mark = dayMark(z), lw = textWidth(font, z.code + " "), tw = clockTextWidth(font, hhmm(z))
        let mw = mark.isEmpty ? 0 : 2 + textWidth("busy_regular_5", mark)
        let x = jsRound(Double(Stacked.cols - lw - tw - mw) / 2)
        drawText(&f, font: font, z.code + " ", x: Double(x), baseY: base, colour: white, style: TextStyle(alpha: 0.5, clipY: clipY))
        drawClockText(&f, font: font, hhmm(z), x: x + lw, baseY: base, colour: white, style: TextStyle(alpha: 0.8, clipY: clipY),
                      colonAlpha: colonOf(clock))
        if !mark.isEmpty {
            drawText(&f, font: "busy_regular_5", mark, x: Double(x + lw + tw + 2), baseY: base - 2, colour: white,
                     style: TextStyle(alpha: 0.5, clipY: clipY))
        }
    }
    private static func drawStackedWorldBase(_ f: inout LEDFrame, now: Double, t: Double, clock: ClockReading, world: WorldPlan,
                                             dx: Int, empty: Bool) {
        let pal = BarPalette.free
        f.clear()
        drawPill(&f, x0: Stacked.pillX, w: Stacked.pillW, pal: pal, sheen: sheenAt(now, cols: f.w), h: Stacked.pillH)
        if !empty {
            let clip: (lo: Int, hi: Int)? = dx == 0 ? nil
                : (lo: Int(Stacked.pillX) + 1, hi: Int(Stacked.pillX + Stacked.pillW) - 1)
            drawStatusContent(&f, now: now, state: .free, pal: pal, x0: Stacked.pillX + Double(dx), w: Stacked.pillW, alpha: 1,
                              clip: clip)
        }
        guard world.turns.on else {
            drawStackedClock(&f, state: .free, clock: clock, timer: nil, slide: 0, minY: 0)
            return
        }
        let big = String(format: "%02d:%02d", clock.h, clock.m), bw = clockTextWidth(Stacked.bigFont, big)
        drawClockText(&f, font: Stacked.bigFont, big, x: jsRound(Double(f.w - bw) / 2), baseY: Stacked.bigBase, colour: white,
                      style: TextStyle(), colonAlpha: colonOf(clock))
        let n = world.zones.count
        guard n > 0 else { return }
        let dwell = world.turns.secs, tt = max(t, 0)
        let i = Int((tt / dwell).rounded(.down)) % n, p = tt.truncatingRemainder(dividingBy: dwell)
        let k = n < 2 || tt < dwell || p >= World.roll ? 1 : easeInOut(p / World.roll)
        if k < 1 { drawStackedTurn(&f, clock: clock, world: world, i: (i - 1 + n) % n, dy: -jsRound(k * 10)) }
        drawStackedTurn(&f, clock: clock, world: world, i: i, dy: jsRound((1 - k) * 10))
    }
    private static func drawStackedWorldTicker(_ f: inout LEDFrame, now: Double, t: Double, s: Double, clock: ClockReading,
                                               world: WorldPlan) {
        let half = Scroll.duration / 2
        let run = (Stacked.pillW + Double(tickerWidth(world))) / World.tickerSpeed
        let away = (Double(statusContentWidth(.free)) + Stacked.pillW) / 2 + 2
        if t < half {
            drawStackedWorldBase(&f, now: now, t: s, clock: clock, world: world, dx: -jsRound(away * easeIn(t / half)), empty: false)
            return
        }
        if t >= half + run {
            drawStackedWorldBase(&f, now: now, t: s, clock: clock, world: world,
                                 dx: jsRound(away * (1 - easeOut(min((t - half - run) / half, 1)))), empty: false)
            return
        }
        drawStackedWorldBase(&f, now: now, t: s, clock: clock, world: world, dx: 0, empty: true)
        drawTickerText(&f, world: world, x0: Stacked.pillX, w: Stacked.pillW, t: t - half)
    }
    /// The board, stacked: four rows, a departures board.
    private static func drawStackedWorldBoard(_ f: inout LEDFrame, clock: ClockReading, world: WorldPlan) {
        f.clear()
        let font = "busy_bold_7", bases = [9, 20, 31, 42]
        for (i, z) in world.zones.prefix(4).enumerated() {
            let base = bases[i], mark = dayMark(z)
            drawText(&f, font: font, z.code, x: 8, baseY: base, colour: i == 0 ? BarPalette.free.top : white,
                     style: TextStyle(alpha: i == 0 ? 1 : 0.55))
            if !mark.isEmpty {
                drawText(&f, font: "busy_regular_5", mark, x: 33, baseY: base, colour: white, style: TextStyle(alpha: 0.5))
            }
            let tw = clockTextWidth(font, hhmm(z))
            drawClockText(&f, font: font, hhmm(z), x: Stacked.cols - 7 - tw, baseY: base, colour: white, style: TextStyle(),
                          colonAlpha: colonOf(clock))
        }
    }
    /// Resting, stacked: the chip and the local time share the top band, the
    /// other three beneath with their day; the big clock rises from behind the pill.
    private static func drawStackedWorldRest(_ f: inout LEDFrame, now: Double, clock: ClockReading, world: WorldPlan, k: Double) {
        let pal = BarPalette.free, ek = easeInOut(k)
        guard let z = world.zones.first else { f.clear(); return }
        f.clear()
        let big = hhmm(z), bw = clockTextWidth(Stacked.bigFont, big)
        let bx = jsRound(lerp(Double(Stacked.cols - bw) / 2, 18 + Double(66 - bw) / 2, ek))
        let bb = jsRound(lerp(Double(Stacked.bigBase), 14, ek))
        drawClockText(&f, font: Stacked.bigFont, big, x: bx, baseY: bb, colour: white, style: TextStyle(), colonAlpha: colonOf(clock))
        let dayA = 1 - smooth(0, 0.3, k)
        if dayA > 0 {
            let d = dayOf(z), dw = textWidth(Stacked.smallFont, d)
            drawText(&f, font: Stacked.smallFont, d, x: Double(jsRound(Double(Stacked.cols - dw) / 2)), baseY: Stacked.smallBase,
                     colour: white, style: TextStyle(alpha: 0.5 * dayA))
        }
        let inA = smooth(0.35, 1, k), dy = jsRound(18 * (1 - easeOut(k))), clipY = (lo: 18, hi: Stacked.rows)
        if inA > 0 {
            for (j, zz) in world.zones.prefix(4).enumerated() where j > 0 {
                let cx = (j - 1) * 28, cell = 28
                let lw = textWidth("busy_regular_5", zz.code)
                drawText(&f, font: "busy_regular_5", zz.code, x: Double(cx + jsRound(Double(cell - lw) / 2)), baseY: 26 + dy,
                         colour: white, style: TextStyle(alpha: 0.55 * inA, clipY: clipY))
                let tw = clockTextWidth("busy_regular_7", hhmm(zz))
                drawClockText(&f, font: "busy_regular_7", hhmm(zz), x: cx + jsRound(Double(cell - tw) / 2) + 1, baseY: 35 + dy,
                              colour: white, style: TextStyle(alpha: inA, clipY: clipY), colonAlpha: colonOf(clock))
                let d = days[((zz.dow % 7) + 7) % 7], dw = textWidth("busy_regular_5", d)
                drawText(&f, font: "busy_regular_5", d, x: Double(cx + jsRound(Double(cell - dw) / 2)), baseY: 42 + dy,
                         colour: white, style: TextStyle(alpha: (zz.dayDelta != 0 ? 0.9 : 0.4) * inA, clipY: clipY))
            }
        }
        let w = lerp(Stacked.pillW, World.chipW, ek)
        drawPill(&f, x0: Stacked.pillX, w: w, pal: pal, sheen: sheenAt(now, cols: f.w), h: Stacked.pillH)
        let icon = icons[.free] ?? []
        let ix = jsRound(lerp(Double(jsRound(Stacked.pillX + (Stacked.pillW - Double(statusContentWidth(.free))) / 2)),
                              Stacked.pillX + Double(jsRound((World.chipW - Double(icon.first?.count ?? 0)) / 2)), ek))
        drawIcon(&f, rows: icon, x: ix, bottomY: Layout.statusBase - (iconLift[.free] ?? 0), colour: white, shadow: pal.shadow,
                 alpha: 1, clip: nil)
        let wordA = 1 - smooth(0, 0.35, k)
        if wordA > 0 {
            drawText(&f, font: Layout.statusFont, BarState.free.word, x: Double(ix + iconWidth(.free)), baseY: Layout.statusBase,
                     colour: white, style: TextStyle(shadow: pal.shadow, shadowAlpha: 0.9 * wordA, alpha: wordA,
                                                     clip: (lo: Int(Stacked.pillX) + 1, hi: Int((Stacked.pillX + w).rounded(.down)) - 1)))
        }
    }
    @discardableResult
    static func worldAtStacked(into f: inout LEDFrame, now: Double, s: Double, clock: ClockReading, world: WorldPlan,
                               prev: BarState?) -> String {
        if s < 0 {
            renderStacked(into: &f, now: now, state: .free, prev: prev, since: now - (s + Timing.settled), clock: clock, timer: nil)
            return "settle"
        }
        let sch = worldSchedule(world, upTo: s, pillW: Stacked.pillW)
        let resting = s >= sch.rest, restK = min((s - sch.rest) / World.restIn, 1)
        for e in sch.events where s >= e.at && s < e.at + e.dur {
            switch e.kind {
            case .board:
                drawWorldBoardOn(&f, t: s - e.at, world: world,
                                 face: { (g: inout LEDFrame) in drawStackedWorldBoard(&g, clock: clock, world: world) },
                                 under: { (g: inout LEDFrame) in
                                     if resting { drawStackedWorldRest(&g, now: now, clock: clock, world: world, k: restK) }
                                     else { drawStackedWorldBase(&g, now: now, t: s, clock: clock, world: world, dx: 0, empty: false) }
                                 })
                return "board"
            case .ticker:
                drawStackedWorldTicker(&f, now: now, t: s - e.at, s: s, clock: clock, world: world)
                return "ticker"
            }
        }
        if resting {
            drawStackedWorldRest(&f, now: now, clock: clock, world: world, k: restK)
            return "rest"
        }
        let dx = world.ticker.on && world.rules.tickerForScroll ? 0 : worldScroll(s, Stacked.pillW)
        drawStackedWorldBase(&f, now: now, t: s, clock: clock, world: world, dx: dx, empty: false)
        return dx != 0 ? "scroll" : "base"
    }
    static func renderStackedWorld(into f: inout LEDFrame, now: Double, state: BarState, prev: BarState?, since: Double,
                                   clock: ClockReading, timer: BarTimer?, world: WorldPlan, prevFor: Double) {
        let e = now - since
        if state == .free {
            f.clear()
            worldAtStacked(into: &f, now: now, s: e - Timing.settled, clock: clock, world: world, prev: prev)
            return
        }
        if prev == .free && e < Timing.swap {
            f.clear()
            worldAtStacked(into: &f, now: now, s: prevFor - Timing.settled, clock: clock, world: world, prev: nil)
            shiftDown(&f, jsRound(Timing.press * easeIn(e / Timing.swap)))
            drawShockwave(&f, progress: e / Timing.wave, pal: BarPalette.of(state))
            return
        }
        renderStacked(into: &f, now: now, state: state, prev: prev, since: since, clock: clock, timer: timer)
    }
}
