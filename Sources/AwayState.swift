import Foundation

/*
 * Where you've said you are, from the Stream Deck's Nearby, Lunch and
 * Back In keys (or the menus): what a press does, and when Back In's time
 * is up. Away keeps it, and StatusRules decides what the sign says from it.
 * Foundation only, so Checks/away can test it anywhere Swift runs.
 */
struct AwayState: Equatable {
    enum Kind: String, CaseIterable {
        case nearby             // in the building, not at your desk
        case lunch              // out of the building
        case backIn             // back at `until`: a countdown on the sign
    }

    var kind: Kind?
    /// When you'll be back, for Back In.
    var until: Date?

    /// Each press of Back In adds this much.
    static let step: TimeInterval = 10 * 60
    /// Back In goes no further ahead than this: a working day.
    static let most: TimeInterval = 8 * 3600

    /// A key pressed. Nearby and Lunch go on, or off if they're on
    /// already. Back In is ten minutes from now, and ten more for each
    /// press after that: three presses for half an hour.
    mutating func press(_ key: Kind, at now: Date) {
        switch key {
        case .nearby, .lunch:
            if kind == key {
                self = AwayState()
            } else {
                kind = key
                until = nil
            }
        case .backIn:
            let from = kind == .backIn ? max(until ?? now, now) : now
            kind = .backIn
            until = min(from.addingTimeInterval(Self.step), now.addingTimeInterval(Self.most))
        }
    }

    /// Back In clears itself once its time is up; the sign moves on to what's next.
    mutating func expire(at now: Date) {
        if kind == .backIn, until.map({ $0 <= now }) ?? true { self = AwayState() }
    }
}
