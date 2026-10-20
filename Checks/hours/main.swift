import Foundation

// Checks WallHours: when the wall's in hours, when it goes dark, and that the
// settings keep. Times are on a fixed calendar, so the check doesn't depend on
// where it runs.
var failures: [String] = []
func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Europe/London")!
/// 2026-10-19 is a Monday.
func at(_ day: Int, _ time: String) -> Date {
    let hm = time.split(separator: ":").map { Int($0)! }
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hm[0], minute: hm[1]))!
}

let usual = WallHours()
expect(usual.isOpen(at: at(19, "07:30"), calendar: calendar), "Monday 07:30: the hours begin")
expect(!usual.isOpen(at: at(19, "07:29"), calendar: calendar), "Monday 07:29: not yet")
expect(usual.isOpen(at: at(19, "18:59"), calendar: calendar), "Monday 18:59: still in hours")
expect(!usual.isOpen(at: at(19, "19:00"), calendar: calendar), "Monday 19:00: out of hours")
expect(usual.isOpen(at: at(23, "12:00"), calendar: calendar), "Friday noon")
expect(!usual.isOpen(at: at(24, "12:00"), calendar: calendar), "Saturday: out of hours all day")
expect(!usual.isOpen(at: at(25, "12:00"), calendar: calendar), "Sunday too")
// the clocks go back on 25 October: the hours are still the wall clock's
expect(usual.isOpen(at: at(26, "07:30"), calendar: calendar) && !usual.isOpen(at: at(26, "07:29"), calendar: calendar),
       "the Monday after the clocks change")

expect(usual.isDark(at: at(19, "21:00"), quiet: true, calendar: calendar), "out of hours, FREE: dark")
expect(!usual.isDark(at: at(19, "21:00"), quiet: false, calendar: calendar), "out of hours, on a call: lit")
expect(!usual.isDark(at: at(19, "10:00"), quiet: true, calendar: calendar), "in hours, FREE: lit")
var off = usual
off.on = false
expect(!off.isDark(at: at(24, "03:00"), quiet: true, calendar: calendar), "turned off: never dark")

// a span past midnight belongs to the day it starts
var nights = WallHours()
nights.from = 22 * 60
nights.to = 6 * 60
nights.days = [6]                                            // Friday night
expect(nights.isOpen(at: at(23, "23:00"), calendar: calendar), "Friday 23:00, overnight hours")
expect(nights.isOpen(at: at(24, "05:59"), calendar: calendar), "into Saturday morning")
expect(!nights.isOpen(at: at(24, "06:00"), calendar: calendar), "till 06:00")
expect(!nights.isOpen(at: at(24, "23:00"), calendar: calendar), "not Saturday night")
expect(!nights.isOpen(at: at(23, "05:00"), calendar: calendar), "nor Friday morning: Thursday's night isn't on")
var allDay = WallHours()
allDay.to = allDay.from
expect(allDay.isOpen(at: at(19, "03:00"), calendar: calendar) && !allDay.isOpen(at: at(24, "12:00"), calendar: calendar),
       "from and to the same: all day on the days chosen")

// kept in the settings, and the default when there are none
let defaults = UserDefaults(suiteName: "busy-bar-sign-checks-hours")!
defaults.removePersistentDomain(forName: "busy-bar-sign-checks-hours")
expect(WallHours(defaults) == WallHours(), "nothing saved: 07:30 to 19:00, Monday to Friday, dark, displays sleep")
var mine = WallHours()
mine.from = 8 * 60
mine.to = 18 * 60 + 30
mine.days = [2, 3, 4, 5, 6, 7]
mine.sleeps = false
mine.save(to: defaults)
expect(WallHours(defaults) == mine, "saved and read back")
defaults.set(5000, forKey: "wallHoursFrom")
defaults.set([0, 3, 9], forKey: "wallHoursDays")
let odd = WallHours(defaults)
expect(odd.from == WallHours().from && odd.days == [3], "nonsense in the settings is left out")
defaults.removePersistentDomain(forName: "busy-bar-sign-checks-hours")

for f in failures { print("FAIL", f) }
print(failures.isEmpty ? "the wall's hours work as designed" : "\(failures.count) wall hours checks failed")
exit(failures.isEmpty ? 0 : 1)
