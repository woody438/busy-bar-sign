import Foundation

/*
 * The wall's hours (Settings ▸ Screen care ▸ Working hours). Outside them,
 * while the sign would say FREE or that you're not here (BarEngine.quiet),
 * the wall goes black — on an OLED, its pixels off — and the screen saver
 * with it, and the app lets the displays sleep. A call, a meeting or a
 * warning lights it as usual. Foundation only, so Checks/hours tests it
 * anywhere Swift runs.
 */
struct WallHours: Equatable {
    /// Whether the wall goes dark out of hours at all.
    var on = true
    /// Minutes after midnight: 07:30 to 19:00. A span past midnight (22:00
    /// to 06:00) belongs to the day it starts; from and to the same is all day.
    var from = 7 * 60 + 30
    var to = 19 * 60
    /// Calendar weekdays, 1 Sunday to 7 Saturday: Monday to Friday.
    var days: Set<Int> = [2, 3, 4, 5, 6]
    /// Whether the displays may sleep while the wall's dark.
    var sleeps = true

    /// Whether `date` is in hours.
    func isOpen(at date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0), day = c.weekday ?? 1
        if from == to { return days.contains(day) }
        if from < to { return days.contains(day) && minute >= from && minute < to }
        let yesterday = day == 1 ? 7 : day - 1
        return (days.contains(day) && minute >= from) || (days.contains(yesterday) && minute < to)
    }

    /// Whether the wall's dark: out of hours, with nothing going on.
    func isDark(at date: Date, quiet: Bool, calendar: Calendar = .current) -> Bool {
        on && quiet && !isOpen(at: date, calendar: calendar)
    }

    // MARK: - Kept in the app's settings

    init() {}

    init(_ defaults: UserDefaults) {
        on = defaults.object(forKey: "wallHoursOn") as? Bool ?? on
        if let m = defaults.object(forKey: "wallHoursFrom") as? Int, (0..<1440).contains(m) { from = m }
        if let m = defaults.object(forKey: "wallHoursTo") as? Int, (0..<1440).contains(m) { to = m }
        if let d = defaults.array(forKey: "wallHoursDays") as? [Int] { days = Set(d.filter { (1...7).contains($0) }) }
        sleeps = defaults.object(forKey: "wallHoursSleep") as? Bool ?? sleeps
    }

    func save(to defaults: UserDefaults) {
        defaults.set(on, forKey: "wallHoursOn")
        defaults.set(from, forKey: "wallHoursFrom")
        defaults.set(to, forKey: "wallHoursTo")
        defaults.set(days.sorted(), forKey: "wallHoursDays")
        defaults.set(sleeps, forKey: "wallHoursSleep")
    }
}
