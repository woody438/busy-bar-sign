import Foundation

/*
 * World clocks: local time and three more cities on the sign while it says
 * FREE (Settings ▸ World clocks). This keeps the settings and works out each
 * city's time; BarEngine draws them, in any mix of four layouts — in turns
 * (the split), resting, now and then (the board) and the ticker.
 *
 * Read on every frame, so the settings and the cities' times are worked out
 * once a second. Used on the main thread only.
 */
final class WorldClocks {
    static let shared = WorldClocks()

    /// Where the settings are kept: the World clocks section binds to these.
    enum Key {
        static let on = "worldOn", onWall = "worldOnWall", onFloating = "worldOnFloating"
        static let turns = "worldTurns", turnsSecs = "worldTurnsSecs"
        static let rest = "worldRest", restMins = "worldRestMins"
        static let board = "worldBoard", boardMins = "worldBoardMins", boardSecs = "worldBoardSecs"
        static let ticker = "worldTicker", tickerMins = "worldTickerMins"
        static let localCode = "worldLocalCode"
        /// The other three clocks, 1...3: the city, and what the sign calls it ("" for the city's own code).
        static func city(_ slot: Int) -> String { "worldCity\(slot)" }
        static func code(_ slot: Int) -> String { "worldCode\(slot)" }
        /// Whether that clock shows: unticked, its city is kept but it's off the sign.
        static func shown(_ slot: Int) -> String { "worldShown\(slot)" }
    }

    /// The settings, and what they start as: off, and In turns the only layout ticked.
    struct Settings {
        var on = false, onWall = true, onFloating = true
        var turns = true, turnsSecs = 5
        var rest = false, restMins = 30
        var board = false, boardMins = 10, boardSecs = 20
        var ticker = false, tickerMins = 15
        /// How the layouts meet, fixed: the board holds off while resting, one waits for the
        /// other, and the ticker takes the place of the word's quarter-hourly scroll.
        var restHolds = true, clash = "wait", tickerForScroll = true
        var localCode = ""
        var cities = ["New York", "Los Angeles", "Tokyo"]
        var codes = ["", "", ""]
        var shown = [true, true, true]

        static let defaults = Settings()

        /// As saved, each number kept to the range its stepper allows.
        static func read(_ d: UserDefaults = .standard) -> Settings {
            var s = Settings()
            func bool(_ key: String, _ v: inout Bool) { if let x = d.object(forKey: key) as? Bool { v = x } }
            func int(_ key: String, _ v: inout Int, _ range: ClosedRange<Int>) {
                if let x = d.object(forKey: key) as? Int { v = min(max(x, range.lowerBound), range.upperBound) }
            }
            func string(_ key: String, _ v: inout String) { if let x = d.string(forKey: key) { v = x } }
            bool(Key.on, &s.on); bool(Key.onWall, &s.onWall); bool(Key.onFloating, &s.onFloating)
            bool(Key.turns, &s.turns); int(Key.turnsSecs, &s.turnsSecs, 3...60)
            bool(Key.rest, &s.rest); int(Key.restMins, &s.restMins, 1...120)
            bool(Key.board, &s.board); int(Key.boardMins, &s.boardMins, 1...60); int(Key.boardSecs, &s.boardSecs, 5...60)
            bool(Key.ticker, &s.ticker); int(Key.tickerMins, &s.tickerMins, 5...120)
            string(Key.localCode, &s.localCode)
            for slot in 1...3 {
                string(Key.city(slot), &s.cities[slot - 1])
                string(Key.code(slot), &s.codes[slot - 1])
                bool(Key.shown(slot), &s.shown[slot - 1])
            }
            return s
        }

        var anyLayout: Bool { turns || rest || board || ticker }
    }

    /// A city in the lists: its name, what the sign calls it, its time zone,
    /// and the zone's abbreviations in winter and in summer.
    struct City: Identifiable, Hashable {
        let name: String, code: String, zone: String, std: String, dst: String
        var id: String { name }
        var timeZone: TimeZone { TimeZone(identifier: zone) ?? .current }

        /// "Chicago — CDT, GMT−5", as it is at `date`.
        func label(at date: Date) -> String { name + " — " + WorldClocks.zoneText(timeZone, std: std, dst: dst, at: date) }
    }

    /// Major cities, one or two a time zone. Where cities share a zone, the
    /// first is the one the Mac's own zone is named after.
    static let cities: [City] = [
        City(name: "Honolulu", code: "HNL", zone: "Pacific/Honolulu", std: "HST", dst: "HST"),
        City(name: "Anchorage", code: "ANC", zone: "America/Anchorage", std: "AKST", dst: "AKDT"),
        City(name: "Los Angeles", code: "LAX", zone: "America/Los_Angeles", std: "PST", dst: "PDT"),
        City(name: "Las Vegas", code: "LAS", zone: "America/Los_Angeles", std: "PST", dst: "PDT"),
        City(name: "Vancouver", code: "YVR", zone: "America/Vancouver", std: "PST", dst: "PDT"),
        City(name: "Phoenix", code: "PHX", zone: "America/Phoenix", std: "MST", dst: "MST"),
        City(name: "Denver", code: "DEN", zone: "America/Denver", std: "MST", dst: "MDT"),
        City(name: "Chicago", code: "CHI", zone: "America/Chicago", std: "CST", dst: "CDT"),
        City(name: "Dallas", code: "DAL", zone: "America/Chicago", std: "CST", dst: "CDT"),
        City(name: "Nashville", code: "BNA", zone: "America/Chicago", std: "CST", dst: "CDT"),
        City(name: "Mexico City", code: "MEX", zone: "America/Mexico_City", std: "CST", dst: "CST"),
        City(name: "New York", code: "NYC", zone: "America/New_York", std: "EST", dst: "EDT"),
        City(name: "Miami", code: "MIA", zone: "America/New_York", std: "EST", dst: "EDT"),
        City(name: "Toronto", code: "YYZ", zone: "America/Toronto", std: "EST", dst: "EDT"),
        City(name: "Montreal", code: "YUL", zone: "America/Toronto", std: "EST", dst: "EDT"),
        City(name: "Bogotá", code: "BOG", zone: "America/Bogota", std: "COT", dst: "COT"),
        City(name: "São Paulo", code: "SAO", zone: "America/Sao_Paulo", std: "BRT", dst: "BRT"),
        City(name: "Buenos Aires", code: "BUE", zone: "America/Argentina/Buenos_Aires", std: "ART", dst: "ART"),
        City(name: "Reykjavík", code: "REK", zone: "Atlantic/Reykjavik", std: "GMT", dst: "GMT"),
        City(name: "London", code: "LON", zone: "Europe/London", std: "GMT", dst: "BST"),
        City(name: "Dublin", code: "DUB", zone: "Europe/Dublin", std: "GMT", dst: "IST"),
        City(name: "Lisbon", code: "LIS", zone: "Europe/Lisbon", std: "WET", dst: "WEST"),
        City(name: "Paris", code: "PAR", zone: "Europe/Paris", std: "CET", dst: "CEST"),
        City(name: "Amsterdam", code: "AMS", zone: "Europe/Amsterdam", std: "CET", dst: "CEST"),
        City(name: "Berlin", code: "BER", zone: "Europe/Berlin", std: "CET", dst: "CEST"),
        City(name: "Madrid", code: "MAD", zone: "Europe/Madrid", std: "CET", dst: "CEST"),
        City(name: "Rome", code: "ROM", zone: "Europe/Rome", std: "CET", dst: "CEST"),
        City(name: "Stockholm", code: "STO", zone: "Europe/Stockholm", std: "CET", dst: "CEST"),
        City(name: "Johannesburg", code: "JNB", zone: "Africa/Johannesburg", std: "SAST", dst: "SAST"),
        City(name: "Athens", code: "ATH", zone: "Europe/Athens", std: "EET", dst: "EEST"),
        City(name: "Helsinki", code: "HEL", zone: "Europe/Helsinki", std: "EET", dst: "EEST"),
        City(name: "Cairo", code: "CAI", zone: "Africa/Cairo", std: "EET", dst: "EEST"),
        City(name: "Istanbul", code: "IST", zone: "Europe/Istanbul", std: "TRT", dst: "TRT"),
        City(name: "Moscow", code: "MOW", zone: "Europe/Moscow", std: "MSK", dst: "MSK"),
        City(name: "Riyadh", code: "RUH", zone: "Asia/Riyadh", std: "AST", dst: "AST"),
        City(name: "Dubai", code: "DXB", zone: "Asia/Dubai", std: "GST", dst: "GST"),
        City(name: "Mumbai", code: "BOM", zone: "Asia/Kolkata", std: "IST", dst: "IST"),
        City(name: "Delhi", code: "DEL", zone: "Asia/Kolkata", std: "IST", dst: "IST"),
        City(name: "Bangkok", code: "BKK", zone: "Asia/Bangkok", std: "ICT", dst: "ICT"),
        City(name: "Singapore", code: "SIN", zone: "Asia/Singapore", std: "SGT", dst: "SGT"),
        City(name: "Hong Kong", code: "HKG", zone: "Asia/Hong_Kong", std: "HKT", dst: "HKT"),
        City(name: "Shanghai", code: "SHA", zone: "Asia/Shanghai", std: "CST", dst: "CST"),
        City(name: "Perth", code: "PER", zone: "Australia/Perth", std: "AWST", dst: "AWST"),
        City(name: "Seoul", code: "SEL", zone: "Asia/Seoul", std: "KST", dst: "KST"),
        City(name: "Tokyo", code: "TYO", zone: "Asia/Tokyo", std: "JST", dst: "JST"),
        City(name: "Sydney", code: "SYD", zone: "Australia/Sydney", std: "AEST", dst: "AEDT"),
        City(name: "Melbourne", code: "MEL", zone: "Australia/Melbourne", std: "AEST", dst: "AEDT"),
        City(name: "Auckland", code: "AKL", zone: "Pacific/Auckland", std: "NZST", dst: "NZDT")
    ]

    static func city(named name: String) -> City? { cities.first { $0.name == name } }

    /// The lists' order: west to east by today's offset from GMT, so it stays right when the clocks change.
    static func listed(at date: Date) -> [City] {
        cities.enumerated().sorted { a, b in
            let oa = a.element.timeZone.secondsFromGMT(for: date), ob = b.element.timeZone.secondsFromGMT(for: date)
            return oa != ob ? oa < ob : a.offset < b.offset
        }.map { $0.element }
    }

    /// "BST, GMT+1"; "GMT" alone where they're the same; "IST, GMT+5:30".
    static func zoneText(_ tz: TimeZone, std: String, dst: String, at date: Date) -> String {
        let abbr = tz.isDaylightSavingTime(for: date) ? dst : std
        let gmt = gmtText(tz.secondsFromGMT(for: date))
        return abbr == gmt ? gmt : abbr + ", " + gmt
    }

    static func gmtText(_ secs: Int) -> String {
        guard secs != 0 else { return "GMT" }
        let m = abs(secs) / 60
        return "GMT" + (secs < 0 ? "−" : "+") + String(m / 60) + (m % 60 == 0 ? "" : String(format: ":%02d", m % 60))
    }

    /// How far a zone is from the Mac's: "Same time", "5 h behind", "9 h 30 min ahead".
    static func fromLocal(_ tz: TimeZone, at date: Date) -> String {
        let d = tz.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        guard d != 0 else { return "Same time" }
        let m = abs(d) / 60, h = m / 60
        let size = m % 60 == 0 ? "\(h) h" : h == 0 ? "\(m % 60) min" : "\(h) h \(m % 60) min"
        return size + (d < 0 ? " behind" : " ahead")
    }

    /// What the sign may call a city: three capitals or digits, as its fonts have them.
    static func code(_ typed: String) -> String {
        String(typed.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(3))
    }

    /// The Mac's own zone, as the lists would name it.
    static var localCity: City? { cities.first { $0.zone == TimeZone.current.identifier } }

    /// "London — BST, GMT+1", or the zone's own name where it isn't in the lists.
    static func localLabel(at date: Date) -> String {
        if let c = localCity { return c.label(at: date) }
        let tz = TimeZone.current
        let name = (tz.identifier.split(separator: "/").last.map { String($0) } ?? tz.identifier).replacingOccurrences(of: "_", with: " ")
        let abbr = tz.abbreviation(for: date) ?? ""
        return name + " — " + zoneText(tz, std: abbr, dst: abbr, at: date)
    }

    /// What the sign calls local time when it isn't set: the city's code, or the zone name's first three letters.
    static var localCode: String {
        if let c = localCity { return c.code }
        let name = TimeZone.current.identifier.split(separator: "/").last.map { String($0) } ?? "LOC"
        let c = code(name)
        return c.isEmpty ? "LOC" : c
    }

    // MARK: - On the sign

    private var second = Int.min
    private var settings = Settings.defaults
    private var zones: [BarEngine.WorldZone] = []

    /// The settings and the four clocks, worked out afresh once a second.
    private func refresh(_ date: Date) {
        let s = Int(date.timeIntervalSince1970.rounded(.down))
        guard s != second else { return }
        second = s
        settings = Settings.read()
        let local = TimeZone.current
        let localDay = Self.dayKey(local, date)
        var z = [Self.reading(settings.localCode.isEmpty ? Self.localCode : settings.localCode, local, date, localDay)]
        for slot in 0..<3 {
            guard settings.shown[slot], let city = Self.city(named: settings.cities[slot]) else { continue }
            let typed = settings.codes[slot]
            z.append(Self.reading(typed.isEmpty ? city.code : typed, city.timeZone, date, localDay))
        }
        zones = z
    }

    private static func calendar(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    /// The date there, as one number to compare: 20261021.
    private static func dayKey(_ tz: TimeZone, _ date: Date) -> Int {
        let c = calendar(tz).dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    private static func reading(_ code: String, _ tz: TimeZone, _ date: Date, _ localDay: Int) -> BarEngine.WorldZone {
        let c = calendar(tz).dateComponents([.hour, .minute, .weekday, .day], from: date)
        let day = dayKey(tz, date)
        return BarEngine.WorldZone(code: code, h: c.hour ?? 0, m: c.minute ?? 0, dow: ((c.weekday ?? 1) - 1 + 7) % 7,
                                   date: c.day ?? 1, dayDelta: day > localDay ? 1 : day < localDay ? -1 : 0)
    }

    private func plan(_ s: Settings) -> BarEngine.WorldPlan {
        var p = BarEngine.WorldPlan()
        p.zones = zones
        p.turns = .init(on: s.turns, secs: Double(s.turnsSecs))
        p.rest = .init(on: s.rest, mins: Double(s.restMins))
        p.board = .init(on: s.board, mins: Double(s.boardMins), secs: Double(s.boardSecs))
        p.ticker = .init(on: s.ticker, mins: Double(s.tickerMins))
        p.rules = .init(restHolds: s.restHolds, clash: BarEngine.WorldPlan.Clash(rawValue: s.clash) ?? .wait,
                        tickerForScroll: s.tickerForScroll)
        return p
    }

    /// What the wall or the floating window shows while FREE is up; nil: FREE as it always was.
    func plan(for style: BarStyle, at date: Date) -> BarEngine.WorldPlan? {
        refresh(date)
        let s = settings
        guard s.on, style == .wall ? s.onWall : s.onFloating, s.anyLayout, zones.count > 1 else { return nil }
        return plan(s)
    }

    /// The settings' preview: one layout, soon and often, or all of them as set.
    enum Watch: String, CaseIterable, Identifiable {
        case asSet, turns, rest, board, ticker
        var id: String { rawValue }
        var label: String {
            switch self {
            case .asSet: return "As set"
            case .turns: return "In turns"
            case .rest: return "Resting"
            case .board: return "Now and then"
            case .ticker: return "Ticker"
            }
        }
    }

    /// The plan the preview plays, whether or not the world clocks are on: as set, or one layout
    /// a few seconds after FREE settles (with In turns as set beneath it).
    func preview(_ watch: Watch, at date: Date) -> BarEngine.WorldPlan {
        refresh(date)
        var p = plan(settings)
        guard watch != .asSet else { return p }
        let turnsOn = watch == .turns || p.turns.on
        p.turns.on = turnsOn
        p.rest.on = false
        p.board.on = false
        p.ticker.on = false
        p.rules.clash = .skip
        switch watch {
        case .rest: p.rest = .init(on: true, mins: 4 / 60)
        case .board: p.board = .init(on: true, mins: 3 / 60, secs: 6)
        case .ticker:
            p.ticker = .init(on: true, mins: 3 / 60)
            p.rules.tickerForScroll = true
        case .asSet, .turns: break
        }
        return p
    }
}
