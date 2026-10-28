import Foundation

/// The moment the right of the pill is about: a countdown to it (Do Not
/// Disturb, a call's end, CALL IN), a count up from it (LATE), or just its
/// time (FREE TILL, CALL TBC once it's on). On a call or in a meeting, `slot`
/// is the meeting you're in, for the time-left rail.
struct BarMoment: Equatable {
    enum Kind { case countdown, countUp, fixed }
    let at: Date
    let kind: Kind
    var slot: DateInterval? = nil

    /// The engine's timer, at `date`.
    func timer(at date: Date) -> BarTimer {
        let c = Calendar.current.dateComponents([.hour, .minute], from: at)
        let left: Double
        switch kind {
        case .countdown: left = at.timeIntervalSince(date)
        case .countUp: left = date.timeIntervalSince(at)
        case .fixed: left = 0
        }
        return BarTimer(left: left, h: c.hour ?? 0, m: c.minute ?? 0,
                        slot: slot.map { BarSlot(left: $0.end.timeIntervalSince(date), total: $0.duration) })
    }
}

/*
 * When the LED panel has to draw. The engine is a function of time, but most
 * of the time it only changes as the clock turns: the time and the colon on
 * the wall clock's whole seconds, a countdown on its moment's. So the panel
 * draws on every display frame only while something moves — a change of
 * state, the scroll, the LEDs easing down to rest, the muted mic's flash,
 * LATE's breathing, the sheen crossing the pill (which stops while the LEDs
 * rest) — and otherwise once a turn.
 *
 * Foundation only, so Checks/raster runs the panel's own schedule against
 * drawing every frame and finds no LED that differs.
 */
enum PanelSchedule {
    /// How far from the sheen's centre, in LEDs, its light can still change an LED as LEDRaster
    /// keys it (16 bits a channel): beyond it the light is under 1e-8 of full, a thousandth of
    /// one step. (Checks/raster finds no LED that changes beyond 29 LEDs.)
    static let sheenReach: Double = {
        let peak = BarEngine.sheenAt(0).strength, width = BarEngine.sheenAt(0).width
        return width * (2 * log(peak / 1e-8)).squareRoot()       // 34.7 LEDs
    }()

    /// Whole seconds after a turn, so a draw lands on the far side of it.
    static let pastTurn = 0.001

    /*
     * nil while something on the bar moves: draw every display frame.
     * Otherwise the scene changes only as the clock turns until the time
     * returned (on the `now` clock; .infinity: not until something changes).
     * `rests`: the panel eases its LEDs down after half an hour (the wall's).
     * The world clocks have their own timings: the panel draws them every frame.
     */
    static func stillUntil(now: Double, state: BarState, since: Double, layout: BarLayout, rests: Bool) -> Double? {
        let e = now - since
        // a change of state: the wave, the announcement, the pill drawing back
        guard e >= BarEngine.Timing.settled else { return nil }
        // LATE breathes all the time
        if state == .late || state == .lateMtg { return nil }
        var until = Double.infinity
        if state == .callMuted {
            // the mic fades out at 1.1 s and back at 1.8 s of every 2 (BarEngine.iconAlphaAt)
            let p = now.truncatingRemainder(dividingBy: 2)
            if (1.1...1.3).contains(p) || p >= 1.8 { return nil }
            until = min(until, now + (p < 1.1 ? 1.1 - p : 1.8 - p))
        }
        if BarEngine.quiet(state) {
            // the scroll, every 15 minutes once the announcement's done
            let every = BarEngine.Scroll.every, s = e - BarEngine.Timing.settled
            let n = (s / every).rounded(.down)
            if n >= 1 && s - n * every < BarEngine.Scroll.duration { return nil }
            until = min(until, since + BarEngine.Timing.settled + (n + 1) * every)
            // easing down to rest
            if rests {
                let from = BarEngine.Rest.after, to = from + BarEngine.Rest.fade
                if e >= from && e <= to { return nil }
                if e < from { until = min(until, since + from) }
            }
        }
        // the sheen, crossing the pill every 8 s — stopped while the LEDs rest
        if rests && BarEngine.sheenRests(now, state, since: since) { return until }
        guard let sheen = sheenStill(now: now, layout: layout) else { return nil }
        return min(until, sheen)
    }

    /// nil while the sheen's light is on the steady pill; else when it next will be.
    static func sheenStill(now: Double, layout: BarLayout) -> Double? {
        // the steady pill as BarEngine.drawSteady and drawStackedSteady draw it, and every LED drawPill visits
        let (x0, w, rows, cols): (Double, Double, Int, Int) = layout == .wide
            ? (BarEngine.Layout.statusX, BarEngine.Layout.statusW, LEDFrame.rows, LEDFrame.cols)
            : (BarEngine.Stacked.pillX, BarEngine.Stacked.pillW, BarEngine.Stacked.pillH, BarEngine.Stacked.cols)
        let xs = Double(Int(x0.rounded(.down)) - 1), xe = Double(Int((x0 + w).rounded(.up)) + 1)
        let skew = 0.55, mid = Double(rows) / 2
        // drawPill: u = (x + 0.5 - pos) + (y - rows / 2) * 0.55; lit while |u| <= reach somewhere on the pill
        let lo = xs + 0.5 + (0 - mid) * skew - sheenReach
        let hi = xe + 0.5 + (Double(rows - 1) - mid) * skew + sheenReach
        // sheenAt: pos = (now mod 8) / 8 * (cols + 50) - 25
        let cycle = 8.0, span = Double(cols + 50)
        let from = max(0, (lo + 25) / span * cycle), to = min(cycle, (hi + 25) / span * cycle)
        guard from < to else { return .infinity }
        let p = now.truncatingRemainder(dividingBy: cycle)
        if p >= from && p <= to { return nil }
        return now + (p < from ? from - p : cycle - p + from)
    }

    /// The next turn after `date`: a whole second on the clock, or on the moment's (a countdown
    /// counts down its moment's seconds, not the clock's).
    static func nextTurn(after date: Date, moment: BarMoment?) -> Date {
        let t = date.timeIntervalSince1970
        var next = t.rounded(.down) + 1
        if let at = moment?.at.timeIntervalSince1970 {
            let frac = (t - at) - (t - at).rounded(.down)            // 0..<1 past the moment's last whole second
            next = min(next, t + (1 - frac))
        }
        return Date(timeIntervalSince1970: next + pastTurn)
    }

    /// When the panel draws next, in seconds from now; nil: on the next display frame.
    static func delay(now: Double, date: Date, state: BarState, since: Double, layout: BarLayout, rests: Bool,
                      moment: BarMoment?, world: Bool) -> Double? {
        guard !world, let still = stillUntil(now: now, state: state, since: since, layout: layout, rests: rests) else {
            return nil
        }
        let turn = nextTurn(after: date, moment: moment).timeIntervalSince(date)
        return max(min(turn, still - now + pastTurn), pastTurn)
    }
}
