import AppKit
import EventKit

/*
 * Your calendar, read from macOS Calendar (EventKit): whatever accounts
 * Calendar.app has, Outlook / Exchange included, already synced to this
 * Mac. Read-only — nothing is ever written back.
 *
 * Reads the chosen calendar from 12 hours ago to 36 hours ahead every
 * minute and whenever Calendar.app says something changed, and turns each
 * event into a CalEvent for StatusRules.
 *
 * macOS syncs Exchange itself and doesn't say when it last managed to, so a
 * calendar that has quietly stopped syncing looks just like a quiet one.
 * The newest change seen across a few weeks of events is the best clue:
 * when that's older than a couple of working days, the controls say so.
 */
@MainActor
final class CalendarSource: ObservableObject {

    enum Access { case unknown, granted, denied, restricted }

    struct Choice: Identifiable, Hashable {
        let id: String
        let title: String
        let account: String
        var label: String { account.isEmpty ? title : "\(title) — \(account)" }
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var calendars: [Choice] = []
    @Published private(set) var events: [CalEvent] = []
    @Published private(set) var lastRead: Date?
    /// The most recent edit to any event from two weeks back to a month ahead.
    @Published private(set) var newestChange: Date?
    /// Events in the chosen calendar over the next month, to spot a wrong choice.
    @Published private(set) var upcomingCount = 0

    @Published var enabled: Bool { didSet { save(enabled, "calendarEnabled"); refresh() } }
    @Published var calendarID: String? { didSet { save(calendarID, "calendarID"); refresh() } }
    @Published var leadMinutes: Int { didSet { save(leadMinutes, "warnMinutes") } }
    @Published var lateMinutes: Int { didSet { save(lateMinutes, "lateMinutes") } }
    /// Comma-separated title words for your own events.
    @Published var lunchWords: String { didSet { save(lunchWords, "lunchWords") } }
    @Published var dndWords: String { didSet { save(dndWords, "dndWords") } }
    @Published var callWords: String { didSet { save(callWords, "callWords") } }
    @Published var oooWords: String { didSet { save(oooWords, "oooWords") } }

    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init() {
        let d = UserDefaults.standard
        let kw = StatusConfig.Keywords()
        enabled = d.object(forKey: "calendarEnabled") as? Bool ?? true
        calendarID = d.string(forKey: "calendarID")
        leadMinutes = d.object(forKey: "warnMinutes") as? Int ?? 10
        lateMinutes = d.object(forKey: "lateMinutes") as? Int ?? 10
        lunchWords = d.string(forKey: "lunchWords") ?? kw.lunch.joined(separator: ", ")
        dndWords = d.string(forKey: "dndWords") ?? kw.dnd.joined(separator: ", ")
        callWords = d.string(forKey: "callWords") ?? kw.call.joined(separator: ", ")
        oooWords = d.string(forKey: "oooWords") ?? kw.ooo.joined(separator: ", ")
    }

    /// The rules' settings, from the controls.
    var config: StatusConfig {
        var c = StatusConfig()
        c.leadMinutes = Double(leadMinutes)
        c.lateMinutes = Double(lateMinutes)
        let words = { (s: String) in s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        c.keywords.lunch = words(lunchWords)
        c.keywords.dnd = words(dndWords)
        c.keywords.call = words(callWords)
        c.keywords.ooo = words(oooWords)
        return c
    }

    /// The calendar is in use: switched on, allowed, and the chosen one is here.
    var isActive: Bool { enabled && access == .granted && selected != nil }

    var selected: Choice? { calendars.first { $0.id == calendarID } }

    /// No change seen for a couple of working days: Exchange may have stopped syncing.
    var isStale: Bool {
        guard let newestChange, upcomingCount > 0 else { return false }
        let weekday = Calendar.current.component(.weekday, from: Date())    // 1 = Sunday
        let days: Double = (weekday == 2 || weekday == 3) ? 4 : 2           // across a weekend on Mon/Tue
        return Date().timeIntervalSince(newestChange) > days * 24 * 3600
    }

    /// What's wrong, in a sentence, or nil.
    var problem: String? {
        guard enabled else { return nil }
        switch access {
        case .unknown: return "Busy Bar Sign needs your permission to read your calendar."
        case .denied: return "Calendar access is off. Turn on Busy Bar Sign in System Settings ▸ Privacy & Security ▸ Calendars, then reopen the app."
        case .restricted: return "This Mac's settings don't allow apps to read calendars."
        case .granted: break
        }
        if calendars.isEmpty { return "macOS Calendar has no calendars. Add your Outlook account in Calendar ▸ Settings ▸ Accounts." }
        if selected == nil { return "Choose the calendar to follow." }
        if upcomingCount == 0 { return "“\(selected?.title ?? "")” has nothing in the next month. Is it the right calendar?" }
        if isStale, let newestChange {
            let ago = RelativeDateTimeFormatter().localizedString(for: newestChange, relativeTo: Date())
            return "Nothing in this calendar has changed since \(ago). macOS Calendar may have stopped syncing Outlook — check it matches Outlook."
        }
        return nil
    }

    /// One line for the status: what the calendar's doing.
    var statusLine: String {
        guard enabled else { return "Off" }
        if let problem { return problem }
        let read = lastRead.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "not yet"
        return "\(selected?.title ?? "Calendar") · read \(read)"
    }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadCalendars(); self?.refresh() }
        }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        updateAccess()
        if access == .unknown && enabled { requestAccess() } else { reloadCalendars(); refresh() }
    }

    /// Asks once; after that macOS only changes it in System Settings.
    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateAccess()
                self.reloadCalendars()
                self.refresh()
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        let next: Access
        if status == .fullAccess { next = .granted }
        else if status == .notDetermined { next = .unknown }
        else if status == .restricted { next = .restricted }
        else { next = .denied }                                   // denied, or write-only
        if access != next { access = next }
    }

    private func reloadCalendars() {
        guard access == .granted else { return }
        let list = store.calendars(for: .event)
            .filter { $0.type != .birthday }
            .map { Choice(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "") }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        if calendars != list { calendars = list }
        // First run: the Exchange account's own "Calendar", else the default for new events.
        if calendarID == nil {
            let exchange = store.calendars(for: .event).first { $0.type == .exchange && $0.title == "Calendar" }
            if let pick = exchange ?? store.defaultCalendarForNewEvents ?? store.calendars(for: .event).first {
                calendarID = pick.calendarIdentifier
            }
        }
    }

    /// Reads the chosen calendar again.
    func refresh() {
        updateAccess()
        guard enabled, access == .granted, let id = calendarID, let calendar = store.calendar(withIdentifier: id) else {
            if !events.isEmpty { events = [] }
            return
        }
        let now = Date()
        let window = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                              end: now.addingTimeInterval(36 * 3600), calendars: [calendar])
        let read = store.events(matching: window).map(Self.convert)
        if read != events { events = read }

        // how fresh it looks, and whether there's anything in it at all
        let wide = store.predicateForEvents(withStart: now.addingTimeInterval(-14 * 24 * 3600),
                                            end: now.addingTimeInterval(30 * 24 * 3600), calendars: [calendar])
        let all = store.events(matching: wide)
        let newest = all.compactMap(\.lastModifiedDate).max()
        if newestChange != newest { newestChange = newest }
        let ahead = all.filter { $0.startDate > now }.count
        if upcomingCount != ahead { upcomingCount = ahead }
        lastRead = now
    }

    /// An EventKit event as the rules see it.
    static func convert(_ e: EKEvent) -> CalEvent {
        let start = e.startDate ?? Date()
        let end = e.endDate ?? start.addingTimeInterval(30 * 60)
        let availability: CalEvent.Availability
        switch e.availability {
        case .free: availability = .free
        case .tentative: availability = .tentative
        case .unavailable: availability = .ooo                     // Outlook's Out of Office
        default: availability = .busy
        }
        // one key per occurrence: every instance of a series shares an external ID
        let base = e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? UUID().uuidString
        let occurrence = (e.occurrenceDate ?? start).timeIntervalSince1970
        return CalEvent(id: "\(base)#\(Int(occurrence))", title: e.title ?? "",
                        start: start.timeIntervalSince1970 * 1000, end: end.timeIntervalSince1970 * 1000,
                        allDay: e.isAllDay, availability: availability, attendees: e.attendees?.count ?? 0,
                        notes: e.notes ?? "", location: e.location ?? "", url: e.url?.absoluteString ?? "",
                        cancelled: e.status == .canceled)
    }

    private func save(_ value: Any?, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

