import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An ordinary window with every setting in it, for when the menu-bar icon is
/// out of sight — hidden on a crowded menu bar, or under the wall display.
/// Opens on first launch, from the Dock icon, from Settings… (⌘,) and from the
/// menu-bar menu.
@MainActor
final class ControlsWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let detector: CallDetector
    private let status: StatusModel
    private let calendar: CalendarSource
    private let wall: DisplayWindow
    private let floating: FloatingWindow
    private let server: LocalServer
    private let saver: SaverInstaller

    init(detector: CallDetector, status: StatusModel, calendar: CalendarSource, wall: DisplayWindow, floating: FloatingWindow,
         server: LocalServer, saver: SaverInstaller) {
        self.detector = detector
        self.status = status
        self.calendar = calendar
        self.wall = wall
        self.floating = floating
        self.server = server
        self.saver = saver
        super.init()
    }

    /// True until the controls have been shown once, so a first launch
    /// introduces them.
    static var neverShown: Bool { !UserDefaults.standard.bool(forKey: "controlsShown") }

    func show() {
        if window == nil {
            let view = ControlsView(detector: detector, status: status, calendar: calendar, wall: wall, floating: floating,
                                    server: server, saver: saver)
            let controller = NSHostingController(rootView: view)
            // a fixed size: each section scrolls inside it
            controller.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: controller)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.title = "Busy Bar Sign"
            w.isReleasedWhenClosed = false
            w.delegate = self
            // on the screen you're working at, not the wall
            if let main = NSScreen.screens.first(where: DisplayWindow.isMenuBarScreen) {
                let v = main.visibleFrame, size = w.frame.size
                w.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.maxY - size.height - 80))
            } else {
                w.center()
            }
            window = w
        }
        UserDefaults.standard.set(true, forKey: "controlsShown")
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The controls in a sidebar of sections, as System Settings has them: what
/// the sign says now; where it shows and how it looks after the screen; what
/// it follows; and the Stream Deck and updates.
struct ControlsView: View {
    @ObservedObject var detector: CallDetector
    @ObservedObject var status: StatusModel
    @ObservedObject var calendar: CalendarSource
    @ObservedObject var wall: DisplayWindow
    @ObservedObject var floating: FloatingWindow
    @ObservedObject var server: LocalServer
    @ObservedObject var saver: SaverInstaller
    @AppStorage("settingsSection") private var section: Section = .status

    enum Section: String, CaseIterable, Identifiable {
        case status, displays, worldClocks, screenCare, away, calendar, microphone, callApps, streamDeck, updates
        var id: String { rawValue }
        var label: String {
            switch self {
            case .status: return "Status"
            case .displays: return "Displays"
            case .worldClocks: return "World clocks"
            case .screenCare: return "Screen care"
            case .away: return "Away & screen saver"
            case .calendar: return "Calendar"
            case .microphone: return "Microphone"
            case .callApps: return "Call apps"
            case .streamDeck: return "Stream Deck"
            case .updates: return "Updates"
            }
        }
        var symbol: String {
            switch self {
            case .status: return "switch.2"
            case .displays: return "display"
            case .worldClocks: return "globe"
            case .screenCare: return "moon.fill"
            case .away: return "door.left.hand.open"
            case .calendar: return "calendar"
            case .microphone: return "mic.fill"
            case .callApps: return "video.fill"
            case .streamDeck: return "square.grid.3x2.fill"
            case .updates: return "arrow.triangle.2.circlepath"
            }
        }
        var tint: Color {
            switch self {
            case .status, .updates: return .gray
            case .displays: return .blue
            case .worldClocks: return .teal
            case .screenCare: return .indigo
            case .away: return .orange
            case .calendar: return .red
            case .microphone: return .pink
            case .callApps: return .purple
            case .streamDeck: return Color(white: 0.3)
            }
        }
    }

    /// The sidebar's groups, Status on its own at the top.
    static let groups: [(title: String?, sections: [Section])] = [
        (nil, [.status]),
        ("The sign", [.displays, .worldClocks, .screenCare, .away]),
        ("What it follows", [.calendar, .microphone, .callApps]),
        ("Devices and the app", [.streamDeck, .updates])
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(section.label).font(.title2.weight(.semibold))
                    pane
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(section)            // each section opens at its top
        }
        .frame(width: 840, height: 660)
        // switches and checkboxes green when on, as the sign's FREE; off stays grey
        .tint(.green)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Self.groups.indices, id: \.self) { g in
                        if let title = Self.groups[g].title {
                            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 3)
                        }
                        ForEach(Self.groups[g].sections) { s in
                            SidebarRow(section: s, selected: section == s, updater: status.updater) { section = s }
                        }
                    }
                }
                .padding(10)
            }
            Text("Also in the menu-bar icon and the Dock icon's menu. Reopen this window by clicking the Dock icon.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .frame(width: 210)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder private var pane: some View {
        switch section {
        case .status: StatusTab(detector: detector, status: status, away: status.away, calendar: calendar, wall: wall,
                                server: server, updater: status.updater)
        case .displays: DisplaysTab(wall: wall, floating: floating)
        case .worldClocks: WorldClocksTab()
        case .screenCare: ScreenCareTab(status: status)
        case .away: AwayTab(away: status.away, saver: saver)
        case .calendar: CalendarTab(calendar: calendar)
        case .microphone: MicrophoneTab(detector: detector)
        case .callApps: CallAppsTab(detector: detector, meeting: status.meeting, mute: status.mute)
        case .streamDeck: StreamDeckTab(updater: status.updater, meeting: status.meeting, server: server)
        case .updates: UpdatesTab(updater: status.updater)
        }
    }
}

/// A section in the sidebar: its icon in a coloured tile, its name; click to open it.
private struct SidebarRow: View {
    let section: ControlsView.Section
    let selected: Bool
    /// For the dot on Updates and Stream Deck while there's something to install.
    let updater: Updater
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(section.tint))
                Text(section.label).lineLimit(1)
                Spacer(minLength: 0)
                UpdateDot(section: section, updater: updater)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(selected ? 0.1 : hovering ? 0.05 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A red dot on Updates while a new build waits, and on Stream Deck while a
/// newer plugin does (or the one in Stream Deck needs installing again), as
/// System Settings marks a section with something to do.
private struct UpdateDot: View {
    let section: ControlsView.Section
    @ObservedObject var updater: Updater

    var body: some View {
        if waiting {
            Circle().fill(Color.red).frame(width: 8, height: 8)
                .accessibilityLabel(section == .updates ? "Update available" : "Plugin update available")
        }
    }

    private var waiting: Bool {
        switch section {
        case .updates: return updater.available != nil && updater.phase == .available
        case .streamDeck: return updater.plugin != nil
        default: return false
        }
    }
}

// MARK: - Building blocks

/// A rounded group of rows, as System Settings draws them.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A row in a card: a label on the left, a control on the right.
private struct Row<Trailing: View>: View {
    let label: String
    var divider = true
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            if divider { Divider().padding(.leading, 12) }
            HStack(spacing: 12) {
                Text(label)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
        }
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.headline).foregroundStyle(.secondary).padding(.bottom, -6)
    }
}

private struct Warning: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row that says what something is, in two lines: its name, and a line about it.
private struct InfoRow: View {
    let title: String
    let detail: String
    var divider = true

    var body: some View {
        VStack(spacing: 0) {
            if divider { Divider().padding(.leading, 12) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

// MARK: - Status

/// What the sign says and why, the controls you reach for day to day, and
/// whether everything it depends on is working.
private struct StatusTab: View {
    @ObservedObject var detector: CallDetector
    @ObservedObject var status: StatusModel
    @ObservedObject var away: Away
    @ObservedObject var calendar: CalendarSource
    @ObservedObject var wall: DisplayWindow
    @ObservedObject var server: LocalServer
    @ObservedObject var updater: Updater

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                BarPreview(status: status)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(status.state.colour).frame(width: 10, height: 10)
                    Text(status.stateName).font(.headline)
                    Text(status.decision.why).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(14)
        }
        Card {
            Row(label: "Sign", divider: false) {
                Picker("Sign", selection: $detector.override) {
                    Text("Automatic").tag(Override.auto)
                    Text("On a call").tag(Override.onCall)
                    Text("Free").tag(Override.free)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            Row(label: "Do Not Disturb") {
                if detector.dndUntil == nil {
                    Button(detector.dndStartLabel) { detector.startDND() }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(detector.dndStatus(at: context.date)?.replacingOccurrences(of: "Do Not Disturb · ", with: "") ?? "")
                            .foregroundStyle(.secondary)
                    }
                    Button("End") { detector.endDND() }
                }
            }
            if let event = status.inPersonEvent {
                Row(label: "In person") {
                    Text(event.title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("I'm Here") { status.markInPerson() }
                }
            }
            // finished early: the sign moves on to what's next
            if let event = status.endableEvent {
                Row(label: "Finished early?") {
                    Text(event.title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("End Now") { status.endEvent() }
                }
            }
            Row(label: "Away") {
                if away.kind != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(away.statusLine(at: context.date) ?? "").foregroundStyle(.secondary)
                    }
                }
                Button(away.nearbyName) { away.press(.nearby) }
                Button("Lunch") { away.press(.lunch) }
                Button("Back In +10") { away.press(.backIn) }
                if away.kind != nil { Button("I'm Back") { away.end() } }
            }
        }
        if let problem = away.problem { Warning(text: problem) }
        Note("Double-click the bar, full-screen or floating, to start or end Do Not Disturb — or, while it says LATE FOR, to say you're there in person: MEETING till it ends. A call still shows ON A CALL. The away keys' word and the screen saver are under Away & screen saver.")

        Heading("Working")
        Card {
            Row(label: "Microphone", divider: false) {
                Text(detector.detection.sourceLine).foregroundStyle(.secondary).lineLimit(1)
            }
            Row(label: "Calendar") {
                HStack(spacing: 6) {
                    Circle().fill(calendar.enabled && calendar.problem == nil ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(calendar.enabled && calendar.problem == nil ? calendar.statusLine : (calendar.enabled ? "Needs attention — see Calendar" : "Off"))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Row(label: "Stream Deck") {
                HStack(spacing: 6) {
                    Circle().fill(server.problem == nil ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(server.problem == nil ? (updater.pluginInstalled.map { "Plugin \($0)" } ?? "The keys can reach the app")
                                               : "Can't reach the app — see Stream Deck")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Row(label: "Updates") {
                Text(updater.statusLine).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        if wall.waitingForScreen {
            Warning(text: "Waiting for the wall display to reconnect.")
        } else if wall.onScaledScreen {
            Warning(text: "The wall display is in a scaled mode, so the LEDs may shimmer. Use its default or native resolution.")
        }
    }
}

/// Which build this is, and newer ones from GitHub.
private struct UpdatesTab: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Card {
            Row(label: "Version", divider: false) {
                Text("\(updater.version) (build \(updater.build))").foregroundStyle(.secondary)
            }
            // a pull request's build, not main's: plainly, so it's not taken for the release
            if updater.channel == "preview" {
                Row(label: "Release") {
                    Text(updater.previewPR.map { "From pull request #\($0)" } ?? "From a pull request").foregroundStyle(.secondary)
                    Text("PREVIEW").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange))
                }
            }
            Row(label: "Updates") {
                Text(updater.statusLine).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                switch updater.phase {
                case .available, .failed where updater.available != nil:
                    Button("Install Now") { updater.install() }
                case .checking, .downloading, .installing:
                    ProgressView().controlSize(.small)
                default:
                    Button("Check Now") { updater.check() }
                }
            }
            Row(label: "Install updates automatically") {
                Toggle("Install updates automatically", isOn: $updater.automatic).labelsHidden().toggleStyle(.switch)
            }
            Row(label: "Get preview builds") {
                Toggle("Get preview builds", isOn: $updater.previews).labelsHidden().toggleStyle(.switch)
            }
            // previews off on a preview: main's build is older by number, so going back is by hand
            if let main = updater.mainRelease {
                Row(label: "Main release") {
                    Text("Build \(main.build)").foregroundStyle(.secondary)
                    Button("Back to Main Release") { updater.backToMain() }
                        .disabled(updater.phase == .downloading || updater.phase == .installing)
                }
            }
        }
        if updater.channel == "preview" {
            let pr = updater.previewPR.map { "pull request #\($0)" } ?? "a pull request"
            Note("This copy is a preview, built from \(pr) to try before it's merged. With Get preview builds on, it takes newer previews and main's releases. Off, it waits for main's next build — or Back to Main Release goes back now.")
        }
        if let problem = updater.installProblem { Warning(text: problem) }
        Note("Busy Bar Sign looks for a new build every four hours and installs it when you're not on a call or in a meeting: it closes and reopens itself in a second or two, keeping its permissions. Only a build signed with the project's certificate is installed. Get preview builds takes a pull request's build too, before it's merged, to try a change early: one at a time, whichever pull request was pushed last. The Stream Deck plugin's updates are under Stream Deck.")
    }
}

/// The bar as it is now, small: the same engine and raster as the wall.
private struct BarPreview: View {
    @ObservedObject var status: StatusModel
    @StateObject private var bar = BarModel()
    @Environment(\.displayScale) private var scale

    var body: some View {
        let pitch = max(Int((4 * scale).rounded()), 2)          // 4 points an LED
        // as the wall shows it, world clocks and all
        LEDPanelView(model: bar, pitchPixels: pitch, layout: .wide, world: { WorldClocks.shared.plan(for: .wall, at: $0) })
            .frame(width: CGFloat(BarEngine.cols * pitch) / scale, height: CGFloat(BarEngine.rows * pitch) / scale)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .frame(maxWidth: .infinity)
            .onAppear { bar.moment = status.moment; bar.update(status.state) }
            .onChange(of: status.state) { _, state in bar.moment = status.moment; bar.update(state) }
            .onChange(of: status.moment) { _, moment in bar.moment = moment }
    }
}

// MARK: - Displays

private struct DisplaysTab: View {
    @ObservedObject var wall: DisplayWindow
    @ObservedObject var floating: FloatingWindow
    @State private var screens = NSScreen.screens
    @AppStorage("wallLayout") private var wallLayout: BarLayout = .wide

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Card {
                header("Full-screen display", isOn: Binding(get: { wall.wantsVisible }, set: { $0 ? wall.show() : wall.hide() }))
                Picture(floating: false)
                Row(label: "Monitor") {
                    Picker("Monitor", selection: Binding(
                        get: { wall.screenID ?? "" },
                        set: { id in if !id.isEmpty { wall.show(onScreenID: id) } })) {
                        if !screens.contains(where: { DisplayWindow.identifier(for: $0) == wall.screenID }) {
                            Text(wall.screenID == nil ? "Automatic" : "Not connected").tag(wall.screenID ?? "")
                        }
                        ForEach(screens, id: \.self) { screen in
                            Text(screenLabel(screen)).tag(DisplayWindow.identifier(for: screen))
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                Row(label: "Layout") {
                    Picker("Layout", selection: $wallLayout) {
                        Text("Wide bar").tag(BarLayout.wide)
                        Text("Stacked").tag(BarLayout.stacked)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                if wall.waitingForScreen {
                    Warning(text: "Waiting for this monitor to reconnect.").padding([.horizontal, .bottom], 12)
                } else if wall.onScaledScreen {
                    Warning(text: "Scaled display mode: the LEDs may shimmer.").padding([.horizontal, .bottom], 12)
                }
            }
            Card {
                header("Floating window", isOn: Binding(get: { floating.isShown }, set: { $0 ? floating.show() : floating.hide() }))
                Picture(floating: true)
                Row(label: "Size") {
                    Picker("Size", selection: $floating.size) {
                        ForEach(FloatingWindow.Size.allCases) { Text(String($0.label.prefix(1))).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                Row(label: "Drag it anywhere; right-click for sizes.") { EmptyView() }
                    .foregroundStyle(.secondary).font(.callout)
            }
        }
        Note("Stacked fills small screens such as 960 × 540: the status on top and a big clock beneath. The floating window always uses the wide bar and stays above other windows, on every Space.")
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                screens = NSScreen.screens
            }
    }

    private func header(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }

    private func screenLabel(_ screen: NSScreen) -> String {
        DisplayWindow.isMenuBarScreen(screen) ? "\(screen.localizedName) (main)" : screen.localizedName
    }

    /// A little drawing of where the bar goes.
    private struct Picture: View {
        let floating: Bool
        var body: some View {
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.31), Color(red: 0.17, green: 0.13, blue: 0.27)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(BarState.call.colour)
                        .frame(width: g.size.width * (floating ? 0.34 : 0.88), height: g.size.height * (floating ? 0.16 : 0.3))
                        .offset(x: g.size.width * (floating ? 0.6 : 0.06), y: g.size.height * (floating ? 0.12 : 0.35))
                }
            }
            .frame(height: 58)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

/// When the wall is lit, and dark the rest of the time: Settings ▸ Screen care ▸ Working hours.
private struct OutOfHours: View {
    @ObservedObject var status: StatusModel

    var body: some View {
        Heading("Working hours")
        Card {
            Row(label: "Go dark outside working hours", divider: false) {
                if status.wallDark { Text("Dark now").foregroundStyle(.secondary) }
                Toggle("Go dark outside working hours", isOn: $status.wallHours.on).labelsHidden().toggleStyle(.switch)
            }
            if status.wallHours.on {
                Row(label: "Lit during") {
                    DatePicker("From", selection: time(\.from), displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                    Text("to")
                    DatePicker("To", selection: time(\.to), displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                    HStack(spacing: 3) {
                        ForEach(Self.weekdays, id: \.self) { day in
                            Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                                get: { status.wallHours.days.contains(day) },
                                set: { on in
                                    if on { status.wallHours.days.insert(day) } else { status.wallHours.days.remove(day) }
                                }))
                                .toggleStyle(.button)
                        }
                    }
                }
                InfoRow(title: "So", detail: summary)
                Row(label: "Let the displays sleep while it's dark") {
                    Toggle("Let the displays sleep while it's dark", isOn: $status.wallHours.sleeps).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        Note("The times are when the wall is lit: your working hours. The rest of the time, while the sign would say FREE or that you're not here, the wall goes black — an OLED's pixels off — and so does the screen saver; a call, a meeting or a warning still lights it. Left to sleep, the displays go off by Lock Screen ▸ “Turn display off when inactive”, and come back on when working hours begin, unless the Mac's locked. Turn that off if the wall's TV doesn't come back on by itself. While it's lit, the wall's LEDs move a pixel at a time, and ease down after half an hour with nothing going on.")
    }

    /// The hours in a sentence: "Lit 07:30–19:00, Mon Tue Wed Thu Fri. Dark the rest of the time, unless something's on."
    private var summary: String {
        let h = status.wallHours
        let t = { (m: Int) in String(format: "%02d:%02d", m / 60, m % 60) }
        let days = Self.weekdays.filter { h.days.contains($0) }.map { Calendar.current.shortWeekdaySymbols[$0 - 1] }
        guard !days.isEmpty else { return "No day ticked: dark all week, unless something's on." }
        return "Lit \(t(h.from))–\(t(h.to)), \(days.joined(separator: " ")). Dark the rest of the time, unless something's on."
    }

    /// The days of the week, as this Mac starts them: Monday first in the UK.
    private static let weekdays = (0..<7).map { (Calendar.current.firstWeekday - 1 + $0) % 7 + 1 }

    /// One end of the wall's hours, as a time of day for a picker.
    private func time(_ end: WritableKeyPath<WallHours, Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = status.wallHours[keyPath: end]
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                status.wallHours[keyPath: end] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}

// MARK: - Away & screen saver

/// The away keys' word, and the screen saver that keeps the sign up while the Mac's locked.
private struct AwayTab: View {
    @ObservedObject var away: Away
    @ObservedObject var saver: SaverInstaller
    /// The Nearby key's word as it's being typed: set on Return, on leaving the field, or on closing
    /// Settings or quitting, once it fits; emptied, NEARBY at once.
    @State private var nearbyDraft = ""
    @FocusState private var nearbyFocused: Bool

    var body: some View {
        Card {
            Row(label: "The Nearby key says", divider: false) {
                TextField("Nearby", text: $nearbyDraft)
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 140)
                    .focused($nearbyFocused)
                    .onSubmit(setNearbyWord)
                    .onChange(of: nearbyFocused) { _, focused in if !focused { setNearbyWord() } }
                    // emptied: NEARBY straight away, as the field's placeholder now says
                    .onChange(of: nearbyDraft) { _, draft in if BarEngine.signWord(draft).isEmpty { setNearbyWord() } }
                    .onAppear { nearbyDraft = away.nearbyWord }
                    .onDisappear(perform: setNearbyWord)
                    // Settings closed, or the app quit, before Return: keep the word typed
                    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                        if (note.object as? NSWindow)?.contentViewController is NSHostingController<ControlsView> { setNearbyWord() }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in setNearbyWord() }
            }
            Row(label: "Start the screen saver (and lock the Mac)") {
                Toggle("Start the screen saver", isOn: $away.startsScreenSaver).labelsHidden().toggleStyle(.switch)
            }
        }
        if let warning = nearbyWarning { Warning(text: warning) }
        if let problem = away.problem { Warning(text: problem) }
        Note("As the Stream Deck's Nearby, Lunch and Back In keys, and the buttons under Status: Nearby and Lunch on or off, Back In ten minutes a press. Three seconds after the last press the screen saver starts, with the sign on every screen. Unlocking clears it. With no key on, a locked Mac says NEARBY — unless the calendar has something to say.")
        Note("The Nearby key's word is yours to change: W HOUSE, STUDIO 2, ON SITE — about seven letters. Press Return, or close Settings, and the sign says it wherever it would say NEARBY: on the wall, the Stream Deck and the screen saver. Empty it for NEARBY: that takes at once, no Return needed.")

        Heading("Screen saver")
        Card {
            Row(label: "Busy Bar Sign screen saver", divider: false) {
                Text(saver.installed ? "Installed" : "Not installed").foregroundStyle(.secondary)
                Button("Choose It…") { saver.openSettings() }
            }
            Row(label: "Lock when it starts") {
                Button("Lock Screen Settings…") { saver.openLockScreenSettings() }
            }
            Row(label: "Last showed on") {
                if saver.seen.isEmpty {
                    Text("Not yet, since the app opened").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(saver.seen.sorted { $0.value.name < $1.value.name }, id: \.key) { entry in
                            Text(entry.value.name + (entry.value.drawing ? " — drawing · " : " — not drawing · ")
                                 + DateFormatter.localizedString(from: entry.value.at, dateStyle: .none, timeStyle: .short))
                                .foregroundStyle(entry.value.drawing ? Color.secondary : Color.orange)
                        }
                    }
                }
            }
        }
        if let problem = saver.problem { Warning(text: problem) }
        Note("The lock screen covers every display, the wall included, and no app can draw over it. A screen saver can. macOS gives each monitor its own screen saver, and sets the one System Settings is on: so drag System Settings to each monitor in turn and choose Busy Bar Sign under Wallpaper ▸ Screen Saver. Set Lock Screen ▸ “Require password after screen saver begins” to Immediately. Then an away key locks the Mac with the sign on every screen — the wall as it's set under Displays, the others as the wide bar. A monitor missing from Last showed on never ran it.")
    }

    /// The word typed, once the sign can show it.
    private func setNearbyWord() {
        guard BarEngine.nearbyProblem(nearbyDraft) == nil, nearbyDraft != away.nearbyWord else { return }
        away.nearbyWord = nearbyDraft
    }

    /// Why the sign can't show the word typed, or nil.
    private var nearbyWarning: String? {
        guard let problem = BarEngine.nearbyProblem(nearbyDraft) else { return nil }
        let still = " The sign says \(BarEngine.nearbyWord) till then."
        switch problem {
        case .characters: return "Plain letters, numbers and punctuation only: the sign's LED fonts have no accents or symbols." + still
        case .sign, .key: return "Too long: about seven letters fit, the most a Stream Deck key shows, so W HOUSE rather than WAREHOUSE." + still
        }
    }
}

// MARK: - World clocks

/// Local time and three more cities on the sign while it says FREE: which layouts, how often,
/// how they meet, and the cities. WorldClocks reads these settings for the sign.
private struct WorldClocksTab: View {
    @AppStorage(WorldClocks.Key.on) private var on = WorldClocks.Settings.defaults.on
    @AppStorage(WorldClocks.Key.onWall) private var onWall = WorldClocks.Settings.defaults.onWall
    @AppStorage(WorldClocks.Key.onFloating) private var onFloating = WorldClocks.Settings.defaults.onFloating
    @AppStorage(WorldClocks.Key.turns) private var turns = WorldClocks.Settings.defaults.turns
    @AppStorage(WorldClocks.Key.turnsSecs) private var turnsSecs = WorldClocks.Settings.defaults.turnsSecs
    @AppStorage(WorldClocks.Key.rest) private var rest = WorldClocks.Settings.defaults.rest
    @AppStorage(WorldClocks.Key.restMins) private var restMins = WorldClocks.Settings.defaults.restMins
    @AppStorage(WorldClocks.Key.board) private var board = WorldClocks.Settings.defaults.board
    @AppStorage(WorldClocks.Key.boardMins) private var boardMins = WorldClocks.Settings.defaults.boardMins
    @AppStorage(WorldClocks.Key.boardSecs) private var boardSecs = WorldClocks.Settings.defaults.boardSecs
    @AppStorage(WorldClocks.Key.ticker) private var ticker = WorldClocks.Settings.defaults.ticker
    @AppStorage(WorldClocks.Key.tickerMins) private var tickerMins = WorldClocks.Settings.defaults.tickerMins
    @AppStorage(WorldClocks.Key.restHolds) private var restHolds = WorldClocks.Settings.defaults.restHolds
    @AppStorage(WorldClocks.Key.clash) private var clash = WorldClocks.Settings.defaults.clash
    @AppStorage(WorldClocks.Key.tickerForScroll) private var tickerForScroll = WorldClocks.Settings.defaults.tickerForScroll
    @AppStorage(WorldClocks.Key.localCode) private var localCode = WorldClocks.Settings.defaults.localCode
    @AppStorage(WorldClocks.Key.city(1)) private var city1 = WorldClocks.Settings.defaults.cities[0]
    @AppStorage(WorldClocks.Key.city(2)) private var city2 = WorldClocks.Settings.defaults.cities[1]
    @AppStorage(WorldClocks.Key.city(3)) private var city3 = WorldClocks.Settings.defaults.cities[2]
    @AppStorage("worldWatch") private var watch: WorldClocks.Watch = .asSet
    @State private var replays = 0

    var body: some View {
        Card {
            Row(label: "Show world clocks", divider: false) {
                Toggle("Show world clocks", isOn: $on).labelsHidden().toggleStyle(.switch)
            }
            Row(label: "Show on") {
                Toggle("Wall display", isOn: $onWall).toggleStyle(.checkbox)
                Toggle("Floating window", isOn: $onFloating).toggleStyle(.checkbox)
            }
        }
        Note("Only while the sign says FREE: a call, a warning or Do Not Disturb takes the bar back at once, as it always has. The screen saver keeps to the sign as it is.")

        Heading("Layouts · tick any or all")
        Card {
            LayoutRow(title: "In turns, split", detail: "Local on the right, the others in turn on the left", isOn: $turns, divider: false) {
                Text("A city every")
                NumberStepper(value: $turnsSecs, range: 3...60, unit: "s")
            }
            LayoutRow(title: "Resting", detail: "All four and a green chip, till anything changes", isOn: $rest) {
                Text("After")
                NumberStepper(value: $restMins, range: 1...120, unit: "min of FREE")
            }
            LayoutRow(title: "Now and then", detail: "The bar rolls over to a world board", isOn: $board) {
                Text("Every")
                NumberStepper(value: $boardMins, range: 1...60, unit: "min for")
                NumberStepper(value: $boardSecs, range: 5...60, step: 5, unit: "s")
            }
            LayoutRow(title: "Ticker", detail: "The other cities run through the pill", isOn: $ticker) {
                Text("Every")
                NumberStepper(value: $tickerMins, range: 5...120, step: 5, unit: "min")
            }
        }
        if turns && ticker {
            Warning(text: "With In turns on, the ticker shows the cities a second time, in a pill a third narrower. You may not want both.")
        }
        if !(turns || rest || board || ticker) {
            Warning(text: "No layout ticked: FREE looks as it always has.")
        }

        Heading("Preview")
        Card {
            WorldPreview(watch: watch, replays: replays).padding(12)
            Divider().padding(.leading, 12)
            // five layouts and a button: the picker takes the row, so nothing is squeezed
            HStack(spacing: 12) {
                Picker("Watch", selection: $watch) {
                    ForEach(WorldClocks.Watch.allCases) { w in Text(w.label).tag(w) }
                }
                .labelsHidden().pickerStyle(.segmented)
                Button { replays += 1 } label: { Label("Play again", systemImage: "arrow.counterclockwise") }
                    .fixedSize()
                    .help("Play the preview again, from a call ending")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        Note("The preview plays from a call ending, with your cities, whether or not the world clocks are on. Each layout comes round a few seconds in, and again every few seconds; As set keeps your timings, so its first board or ticker is minutes away.")

        Heading("When layouts meet")
        Card {
            Row(label: "While Resting is up", divider: false) {
                Picker("While Resting is up", selection: $restHolds) {
                    Text("Hold the board").tag(true)
                    Text("Board still runs").tag(false)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            .disabled(!(rest && board))
            Row(label: "When two fall together") {
                Picker("When two fall together", selection: $clash) {
                    Text("Second waits").tag("wait")
                    Text("Skip the second").tag("skip")
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            .disabled(!(board && ticker))
            Row(label: "The ticker") {
                Picker("The ticker", selection: $tickerForScroll) {
                    Text("Instead of the word's scroll").tag(true)
                    Text("As well as it").tag(false)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            .disabled(!ticker)
        }
        Note("In turns sets how FREE looks. Resting takes over after its wait, till anything changes. Now and then and the ticker come in at their times, one at a time; the ticker needs the pill, so it never runs while Resting is up. A rule that doesn't apply to what's ticked is greyed out.")

        Heading("Cities")
        Card {
            LocalCityRow(code: $localCode)
            CityRow(slot: 1)
            CityRow(slot: 2)
            CityRow(slot: 3)
        }
        if [city1, city2, city3].allSatisfy({ WorldClocks.city(named: $0) == nil }) {
            Warning(text: "No cities but local: FREE looks as it always has.")
        }
        Note("Each list runs west to east by the city's offset today, from macOS, so it stays right when the clocks change. Set a clock to None for fewer: the layouts close up around the ones left. Local is the Mac's own time zone, from System Settings ▸ General ▸ Date & Time, and always shows. The sign calls each city by three letters: type your own, or leave it empty for the city's.")
    }
}

/// A layout to tick, and its timing, greyed out while it's unticked.
private struct LayoutRow<Controls: View>: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var divider = true
    @ViewBuilder var controls: Controls

    var body: some View {
        VStack(spacing: 0) {
            if divider { Divider().padding(.leading, 12) }
            HStack(spacing: 12) {
                Toggle(isOn: $isOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                HStack(spacing: 6) { controls }
                    .disabled(!isOn)
                    .opacity(isOn ? 1 : 0.5)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

/// A whole number typed or stepped, kept to its range.
private struct NumberStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let unit: String

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 44)
            Stepper("", value: $value, in: range, step: step).labelsHidden()
            Text(unit)
        }
        .onChange(of: value) { _, v in
            let c = min(max(v, range.lowerBound), range.upperBound)
            if c != v { value = c }
        }
    }
}

/// The world clocks on their own little bar, playing one layout or all of them as set.
private struct WorldPreview: View {
    let watch: WorldClocks.Watch
    let replays: Int
    @StateObject private var bar = BarModel()
    @Environment(\.displayScale) private var scale

    var body: some View {
        let pitch = max(Int((4 * scale).rounded()), 2)          // 4 points an LED
        LEDPanelView(model: bar, pitchPixels: pitch, layout: .wide,
                     world: { [watch] date in WorldClocks.shared.preview(watch, at: date) })
            .frame(width: CGFloat(BarEngine.cols * pitch) / scale, height: CGFloat(BarEngine.rows * pitch) / scale)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .frame(maxWidth: .infinity)
            .onAppear { bar.replay(.free, from: .call) }
            .onChange(of: watch) { _, _ in bar.replay(.free, from: .call) }
            .onChange(of: replays) { _, _ in bar.replay(.free, from: .call) }
    }
}

/// A clock's row: what it is and how far from local on the left, its city and code on the right.
private struct CityLine<Controls: View>: View {
    let title: String
    let detail: String
    var divider = true
    @ViewBuilder var controls: Controls

    var body: some View {
        VStack(spacing: 0) {
            if divider { Divider().padding(.leading, 12) }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                controls
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

/// What the sign calls a city: three letters, or empty for the city's own.
private struct CodeField: View {
    @Binding var code: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            Text("as").foregroundStyle(.secondary)
            TextField(placeholder, text: Binding(get: { code }, set: { code = WorldClocks.code($0) }))
                .textFieldStyle(.roundedBorder).frame(width: 48)
        }
    }
}

private struct LocalCityRow: View {
    @Binding var code: String

    var body: some View {
        CityLine(title: "Local", detail: "From the Mac", divider: false) {
            Text(WorldClocks.localLabel(at: Date())).foregroundStyle(.secondary)
            CodeField(code: $code, placeholder: WorldClocks.localCode)
        }
    }
}

/// One of the other three clocks: a city from the list, and what the sign calls it.
private struct CityRow: View {
    let slot: Int
    @AppStorage private var city: String
    @AppStorage private var code: String

    init(slot: Int) {
        self.slot = slot
        _city = AppStorage(wrappedValue: WorldClocks.Settings.defaults.cities[slot - 1], WorldClocks.Key.city(slot))
        _code = AppStorage(wrappedValue: "", WorldClocks.Key.code(slot))
    }

    var body: some View {
        let now = Date()
        let picked = WorldClocks.city(named: city)
        CityLine(title: "Clock \(slot + 1)", detail: picked.map { WorldClocks.fromLocal($0.timeZone, at: now) } ?? "Not shown") {
            Picker("Clock \(slot + 1)", selection: $city) {
                Text("None").tag("")
                Divider()
                ForEach(WorldClocks.listed(at: now)) { c in Text(c.label(at: now)).tag(c.name) }
            }
            .labelsHidden().frame(width: 260)
            CodeField(code: $code, placeholder: picked?.code ?? "")
                .disabled(picked == nil)
        }
        // a new city goes by its own code
        .onChange(of: city) { _, _ in code = "" }
    }
}

// MARK: - Screen care

/// Looking after the wall's screen: dark out of hours, and what it does in hours.
private struct ScreenCareTab: View {
    @ObservedObject var status: StatusModel

    var body: some View {
        OutOfHours(status: status)
        Heading("Always on, on the wall")
        Card {
            InfoRow(title: "The orbit", detail: "The LEDs move a pixel at a time through every position within an LED: one pass an hour.", divider: false)
            InfoRow(title: "Resting", detail: "After half an hour of FREE or a not-here state unchanged, the LEDs ease down to about 60% of their light.")
            InfoRow(title: "The scroll", detail: "Every 15 minutes of a quiet state, the pill's icon and word scroll out and back in: or the world clocks' ticker runs in its place, if it's set to (World clocks).")
        }
        Note("Calls, meetings, warnings and Do Not Disturb never dim, scroll or go dark. The floating window, on your desk screen among everything else, does none of this.")
    }
}

// MARK: - Calendar

private struct CalendarTab: View {
    @ObservedObject var calendar: CalendarSource
    @AppStorage("calendarPage") private var page: Page = .calendar

    enum Page: String, CaseIterable {
        case calendar, guide, words
        var label: String {
            switch self {
            case .calendar: return "Calendar"
            case .guide: return "Event guide"
            case .words: return "Words"
            }
        }
    }

    var body: some View {
        Picker("Page", selection: $page) {
            ForEach(Page.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .labelsHidden().pickerStyle(.segmented).fixedSize()
        switch page {
        case .calendar: settings
        case .guide: guide
        case .words: words
        }
    }

    @ViewBuilder private var settings: some View {
        Card {
            Row(label: "Follow my calendar", divider: false) {
                Toggle("Follow my calendar", isOn: $calendar.enabled).labelsHidden().toggleStyle(.switch)
            }
            if calendar.enabled {
                if calendar.access == .unknown {
                    Row(label: "Busy Bar Sign needs permission to read your calendar.") {
                        Button("Allow…") { calendar.requestAccess() }
                    }
                } else if calendar.access != .granted {
                    Row(label: "Calendar access is off.") {
                        Button("Open Privacy Settings") { calendar.openPrivacySettings() }
                    }
                } else {
                    Row(label: "Calendar") {
                        Picker("Calendar", selection: Binding(get: { calendar.calendarID ?? "" },
                                                              set: { calendar.calendarID = $0.isEmpty ? nil : $0 })) {
                            if calendar.selected == nil { Text("Choose…").tag("") }
                            ForEach(calendar.calendars) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                Row(label: "Warn before calls and meetings") {
                    Picker("Warn", selection: $calendar.leadMinutes) {
                        ForEach([5, 10, 15], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Row(label: "Show LATE FOR CALL or MTG for up to") {
                    Picker("Late", selection: $calendar.lateMinutes) {
                        ForEach([5, 10, 15], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Row(label: "Status") {
                    Text(calendar.problem == nil ? calendar.statusLine : "Needs attention").foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        if calendar.enabled, let problem = calendar.problem { Warning(text: problem) }
        Note("The sign reads macOS Calendar, so any calendar synced to it works: Outlook or Exchange, Google, iCloud. Declined meetings leave the calendar, so they never count.")
    }

    @ViewBuilder private var guide: some View {
        Heading("What to put in your calendar")
        Card {
            ForEach(Array(Guide.rows.enumerated()), id: \.offset) { i, row in
                VStack(spacing: 0) {
                    if i > 0 { Divider().padding(.leading, 12) }
                    HStack(alignment: .center, spacing: 12) {
                        Group {
                            if let state = row.state, let image = Guide.image(state) {
                                Image(decorative: image, scale: 2).interpolation(.none)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 177, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.how)
                            Text(row.more).font(.callout).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder private var words: some View {
        Heading("Words the sign looks for")
        Card {
            keywordRow("LUNCH", $calendar.lunchWords, divider: false)
            keywordRow("DO NOT DISTURB", $calendar.dndWords)
            keywordRow("ON A CALL", $calendar.callWords)
            keywordRow("OUT OF OFFICE", $calendar.oooWords)
            keywordRow("OUT ON SITE", $calendar.onSiteWords)
        }
        Note("Only your own events — ones with no invitees — are matched by title, and all-day and Out of Office ones for OUT ON SITE: whole words, any case, separated by commas. With no title word, one of your own with a location somewhere else is OUT ON SITE. Meetings are sorted by their location, invitees and join link, so their titles never matter.")

        Heading("Where meetings are")
        Card {
            keywordRow("YOUR OFFICE", $calendar.officeWords, divider: false)
            keywordRow("MEETING ROOMS", $calendar.roomWords)
            keywordRow("COMPANY SITES", $calendar.siteWords, placeholder: "Your company's name")
        }
        Note("A meeting's location says where you'll be; a Teams or Zoom link only that others can dial in. Your office, a meeting room — a room booked on the invite, a location with one of these words, or a code like MTL-210 — or one of your company's sites — a location with one of the Company sites words, such as your company's name — is MEETING, even with a link (a room, and LATE FOR MTG if you're still at the Mac). Anywhere else is OUT ON SITE. No location, or one like “TBC” or a dial-in, goes by the link: a call, else MEETING.")
    }

    private func keywordRow(_ label: String, _ text: Binding<String>, divider: Bool = true, placeholder: String? = nil) -> some View {
        Row(label: label, divider: divider) {
            TextField(placeholder ?? label, text: text).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 260)
        }
    }
}

/// Each state as the bar draws it, and what puts it there.
private enum Guide {
    struct Line { let state: BarState?; let how: String; let more: String }
    static let rows: [Line] = [
        Line(state: .call, how: "Automatic when an app uses your microphone.",
             more: "Counts down to when you're free, through back-to-back meetings. Or an event of your own with “call” in the title, e.g. “Call - Linda”, for calls on your phone."),
        Line(state: .meeting, how: "A meeting in your office, a meeting room or one of your company's sites, or with invitees and no Teams, Zoom or Meet link.",
             more: "A link doesn't matter with the room or your office as the location. Or a call never joined, once LATE gives up."),
        Line(state: .callIn, how: "10 minutes before a call or a meeting.",
             more: "BUSY IN for a meeting in person. A countdown, then the start time."),
        Line(state: .late, how: "A call has started and your microphone hasn't.",
             more: "Pulses for up to 10 minutes, then MEETING. Joining turns it red; the Status key or a double-click says you're there in person."),
        Line(state: .lateMtg, how: "A meeting in a meeting room has started, and you're still at the Mac.",
             more: "Pulses for up to 10 minutes, or till you leave the Mac, then MEETING."),
        Line(state: .callTbc, how: "Show As: Tentative on a meeting.",
             more: "Counts down to the start, then shows the end. BUSY TBC in person. Never shows LATE."),
        Line(state: .dnd, how: "An event titled “No meetings” or “Focus”.",
             more: "Or double-click the bar for 30 minutes. Warnings for calls still show inside it."),
        Line(state: .lunch, how: "An event of your own with “lunch” in the title — Show As Out of Office too.",
             more: "Counts down to when you're back. Beats any meeting over it: no warnings during lunch."),
        Line(state: .away, how: "Any other event of your own — no invitees — with no location, or one that says nothing about where.",
             more: "e.g. “Gym”, “Drive home”, “School run”. Beats meetings too."),
        Line(state: .ooo, how: "Show As: Out of Office, an all-day busy event, or ✈ in the title.",
             more: "Flight apps such as Flighty put the ✈ in."),
        Line(state: .onSite, how: "A meeting, or an event of your own, somewhere other than your office, a meeting room or your company's sites, or “on site” in the title.",
             more: "A client, a venue, a restaurant — anywhere with an address, the dentist's too. Or your own event — all-day or Show As Out of Office too — titled “On site”."),
        Line(state: nil, how: "Ignored: Show As Free, cancelled meetings, and all-day events that aren't busy.",
             more: "Declined meetings leave your Outlook calendar, so they never count.")
    ]

    private static var cache: [BarState: CGImage] = [:]

    /// The settled bar for `state` at 10:52 on a Friday, 3 pixels an LED, no glow.
    static func image(_ state: BarState) -> CGImage? {
        if let hit = cache[state] { return hit }
        let raster = LEDRaster(pitch: 3)
        var frame = LEDFrame()
        let timers: [BarState: BarTimer] = [
            .call: BarTimer(left: 2832, h: 11, m: 30), .meeting: BarTimer(left: 1080, h: 11, m: 30),
            .callIn: BarTimer(left: 461, h: 11, m: 0), .late: BarTimer(left: 80, h: 9, m: 45), .lateMtg: BarTimer(left: 80, h: 10, m: 30),
            .lunch: BarTimer(left: 1980, h: 13, m: 25),
            .freeTil: BarTimer(left: 0, h: 11, m: 0), .callTbc: BarTimer(left: 461, h: 12, m: 0)
        ]
        BarEngine.render(into: &frame, now: 1060, state: state, prev: nil, since: 1000,
                         clock: ClockReading(h: 10, m: 52, s: 0, ms: 0, dow: 5, date: 2), timer: timers[state])
        raster.render(frame)
        let data = Data(bytes: raster.pixels.baseAddress!, count: raster.bytesPerRow * raster.height) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let image = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: raster.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        cache[state] = image
        return image
    }
}

// MARK: - Microphone

private struct MicrophoneTab: View {
    @ObservedObject var detector: CallDetector

    var body: some View {
        Card {
            Row(label: "Count as a call", divider: false) {
                Picker("Count as a call", selection: $detector.policy) {
                    ForEach(DetectionPolicy.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            Row(label: "Status") {
                Text(detector.detection.sourceLine).foregroundStyle(.secondary).lineLimit(1)
            }
        }

        Heading("Using the microphone now")
        Card {
            let holders = uniqueByApp(detector.detection.holders)
            if holders.isEmpty {
                Row(label: "Nothing", divider: false) { EmptyView() }.foregroundStyle(.secondary)
            }
            ForEach(Array(holders.enumerated()), id: \.offset) { i, holder in
                let id = holder.bundleID ?? ""
                Row(label: holder.name, divider: i > 0) {
                    if holder.counts || detector.userIgnored.contains(id) {
                        Toggle("Ignore", isOn: Binding(get: { detector.userIgnored.contains(id) },
                                                       set: { detector.setIgnored(id, $0) }))
                            .toggleStyle(.switch)
                    } else {
                        Text("Ignored already").foregroundStyle(.secondary)
                    }
                }
            }
        }
        let ignored = detector.userIgnored.sorted()
        if !ignored.isEmpty {
            Heading("Ignored")
            Card {
                ForEach(Array(ignored.enumerated()), id: \.offset) { i, id in
                    Row(label: id, divider: i > 0) {
                        Button("Stop ignoring") { detector.setIgnored(id, false) }
                    }
                }
            }
        }
        Note("The sign lights 2 seconds after an app takes the microphone and goes dark 10 seconds after it lets go. Dictation tools and Apple's own listeners are ignored already; switch on Ignore for anything else that isn't a call. Nothing is ever recorded.")
    }

    /// One entry per app: an app can hold the mic in several processes.
    private func uniqueByApp(_ holders: [MicHolder]) -> [MicHolder] {
        var seen = Set<String>()
        return holders.filter { holder in
            guard let id = holder.bundleID else { return false }
            return seen.insert(id).inserted
        }
    }
}

// MARK: - Call apps

/// The apps calls happen in: whether you're muted (for the sign), the
/// post-call survey, and what to send if a call app isn't read right. Which
/// apps light the sign is under Microphone; the Mute and Leave keys, Stream Deck.
private struct CallAppsTab: View {
    @ObservedObject var detector: CallDetector
    @ObservedObject var meeting: MeetingKeys
    @ObservedObject var mute: MuteDetector
    @State private var output: String?
    @State private var working = false
    @State private var notAnApp: String?

    var body: some View {
        Group {
            Card {
                Row(label: "Accessibility", divider: false) {
                    if mute.trusted {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Allow…") { mute.requestTrust() }
                        Button("Reset and ask again") { mute.resetTrust() }
                    }
                }
            }
            if !mute.trusted {
                Warning(text: "Without Accessibility the sign can't tell you're muted, and the Stream Deck's Mute and Leave keys can't press anything. Switched on already? Then that entry belongs to an older build, signed differently, and switching it off and on doesn't help. Press Reset and ask again, then switch Busy Bar Sign on when System Settings opens.")
            }
        }
        Group {
            Heading("Which apps count, and what the sign can do in them")
            Card {
                ForEach(Array(MeetingApp.allCases.enumerated()), id: \.element) { i, app in
                    CallAppRow(name: app == .teams ? "Microsoft Teams" : "Zoom", can: "On a call · muted · Mute and Leave keys",
                               now: line(app), divider: i > 0)
                }
                CallAppRow(name: "Google Meet, FaceTime, Slack, WhatsApp, Webex, Discord, Skype, Signal, Telegram, RingCentral, GoTo, BlueJeans",
                           can: "On a call · muted, when it finds the app's mute button · no Mute or Leave keys", now: nil)
                ForEach(detector.addedCallApps) { app in
                    CallAppRow(name: app.name, can: "Added by you · on a call · muted, when it finds a mute button", now: nil) {
                        Button("Remove") { detector.removeCallApp(app.id) }
                    }
                }
                Row(label: "Another call app") {
                    Button("Add App…") { addApps() }
                }
            }
            if let notAnApp { Warning(text: notAnApp) }
            Note("Meet counts in Chrome, Edge, Arc, Brave, Firefox and Safari. With Microphone ▸ Detect on Any app except ignored, as it starts, any app using the mic lights the sign, so most apps never need adding. An app added here counts under Known call apps only too, is never ignored, and is searched for a mute button while you're on a call in it. The END on the Leave key works whatever the app: it ends the calendar event, not the call.")
        }
        Group {
            Heading("On the sign")
            Card {
                Row(label: "Show when I'm muted", divider: false) {
                    Toggle("Show when I'm muted", isOn: $mute.enabled).labelsHidden().toggleStyle(.switch)
                }
                if mute.enabled {
                    Row(label: "Now") {
                        Text(mute.statusLine).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Note("While you're muted the bar still says ON A CALL, with the pill dimmed and a slashed mic that flashes slowly: bright means quiet, dim and flashing means the room can talk. Teams and Zoom are read from their own mute control; Meet, Webex, Slack and FaceTime from a button that says mute. Dictation apps are never read. If it can't tell, it shows the mic as live.")
        }
        Group {
            Heading("After a call")
            Card {
                Row(label: "Close the call-quality survey", divider: false) {
                    Toggle("Close the call-quality survey", isOn: $meeting.closeSurveys).labelsHidden().toggleStyle(.switch)
                }
                Row(label: "Last popup after a call") {
                    if let p = meeting.lastPopup {
                        Button("\(p.at.formatted(date: .omitted, time: .shortened)) · \(p.popup.app.label): \(p.popup.action)") {
                            output = "\(p.popup.app.label) “\(p.popup.window)” — \(p.popup.matched ? "looked like a survey" : "not recognised, left alone")\n\n\(p.popup.text)"
                        }
                        .buttonStyle(.link)
                    } else {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                }
            }
            Note("Teams' “rate your call” and Zoom's “How was the audio and video?” are only ever closed with a Dismiss, Close or Skip-type button, never Submit or a thumbs.")
        }
        Group {
            Heading("If a call app isn't read right")
            HStack {
                Button("Inspect meeting controls") { run { meeting.inspect(then: $0) } }
                Button("Capture popups") { run { meeting.capture(then: $0) } }
                Spacer()
                Button("Edit patterns…") { meeting.revealPatterns() }
                Button("Reload") { meeting.reloadPatterns() }
            }
            .disabled(working)
            .sheet(isPresented: Binding(get: { output != nil }, set: { if !$0 { output = nil } })) {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        Text(output ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
                    HStack {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(output ?? "", forType: .string)
                        }
                        Spacer()
                        Button("Done") { output = nil }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
                .frame(width: 620, height: 460)
            }
            ForEach(meeting.problems, id: \.self) { Warning(text: $0) }
            Note("Inspect lists the buttons Busy Bar Sign can see in a Teams meeting window and Zoom's Meeting menu; Capture lists what's open after a call, touching nothing. Copy either and send it over if the sign or a key gets it wrong. The words it reads are in a patterns file (Edit patterns…), the same format as Teams Meeting Keys' teams-ui.json.")
        }
    }

    /// Apps from Applications (or anywhere), counted as calls from now on.
    private func addApps() {
        let panel = NSOpenPanel()
        panel.title = "Add a call app"
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        notAnApp = nil
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
                notAnApp = "\(url.deletingPathExtension().lastPathComponent) has no bundle ID, so the sign can't tell it's using the mic."
                continue
            }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            detector.addCallApp(CallApp(id: id, name: name))
        }
    }

    /// One line for an app: its meeting, mute button and state.
    private func line(_ app: MeetingApp) -> String {
        guard let s = meeting.snapshot.apps[app], s.running else { return "Not running" }
        guard s.inMeeting else { return "Not in a meeting" }
        let muted = s.muted.map { $0 ? "muted" : "mic live" } ?? "mute unknown"
        let label = s.muteLabel.isEmpty ? "" : " · “\(s.muteLabel)”"
        return "“\(s.window)”\(label) · \(muted)\(meeting.snapshot.active == app ? " · the keys act here" : "")"
    }

    private func run(_ work: (@escaping (String) -> Void) -> Void) {
        working = true
        work { text in
            output = text
            working = false
        }
    }
}

/// A call app, or a group of them: what the sign can do there, and what it sees now.
private struct CallAppRow<Trailing: View>: View {
    let name: String
    let can: String
    let now: String?
    var divider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if divider { Divider().padding(.leading, 12) }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).fixedSize(horizontal: false, vertical: true)
                    Text(can).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let now { Text(now).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                trailing
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

extension CallAppRow where Trailing == EmptyView {
    init(name: String, can: String, now: String?, divider: Bool = true) {
        self.init(name: name, can: can, now: now, divider: divider, trailing: { EmptyView() })
    }
}

// MARK: - Stream Deck

/// The Stream Deck plugin: its version and updates, whether its keys reach the app, and what each key does.
private struct StreamDeckTab: View {
    @ObservedObject var updater: Updater
    @ObservedObject var meeting: MeetingKeys
    @ObservedObject var server: LocalServer

    var body: some View {
        Card {
            Row(label: "Plugin", divider: false) {
                if let plugin = updater.plugin {
                    Text(updater.pluginIncomplete ? "\(plugin.installed) not fully installed"
                                                  : "\(plugin.installed) installed · \(plugin.available) ready to install")
                        .foregroundStyle(.secondary)
                    Button(updater.pluginIncomplete ? "Reinstall…" : "Update…") { updater.updatePlugin() }
                } else if let installed = updater.pluginInstalled {
                    // up to date only once checked, with the app up to date too
                    Text(updater.pluginIncomplete ? "\(installed) not fully installed"
                         : updater.phase == .upToDate ? "\(installed) · up to date" : installed).foregroundStyle(.secondary)
                } else {
                    Text("Not installed").foregroundStyle(.secondary)
                }
            }
            Row(label: "Connection") {
                Text(server.problem == nil ? "The keys reach the app on 127.0.0.1:\(LocalAPI.port)" : "The keys can't reach the app")
                    .foregroundStyle(server.problem == nil ? Color.secondary : Color.orange)
            }
            Row(label: "Last key press") {
                Text(meeting.lastPress.map { "\($0.at.formatted(date: .omitted, time: .shortened)) · \($0.message)" } ?? "None yet")
                    .foregroundStyle(meeting.lastPress?.ok == false ? Color.orange : Color.secondary)
                    .lineLimit(2).multilineTextAlignment(.trailing)
            }
        }
        .onAppear { updater.refreshPlugin() }
        if updater.pluginIncomplete {
            Warning(text: "Stream Deck has the plugin's new version number but older code: an install stopped part way, so the keys may not do what this version does. Reinstall it; if the keys don't change, quit Stream Deck and open it again.")
        }
        if let problem = server.problem { Warning(text: problem) }
        Note("The plugin comes with each release as BusyBarSign.streamDeckPlugin. A new one is opened in Stream Deck once, when you're off calls; Stream Deck asks before installing it.")

        Heading("Keys")
        Card {
            InfoRow(title: "Status", detail: "Shows the sign. Press for Do Not Disturb, or while it says LATE FOR, to say you're there in person.", divider: false)
            InfoRow(title: "Mute", detail: "LIVE or MUTED in your Teams or Zoom meeting. Press to switch.")
            InfoRow(title: "Leave", detail: "Leaves the meeting. Hold it a second to end a Zoom meeting you're hosting for everyone.")
            InfoRow(title: "Nearby, Lunch, Back In", detail: "The away keys: the Mac locks, with the sign on every screen (Away & screen saver).")
        }
        Note("The Mute and Leave keys (Busy Bar Sign ▸ Mute, ▸ Leave in Stream Deck) press the meeting's own button; if that doesn't take, they bring the meeting window forward and send its shortcut — Teams ⌘⇧M and ⌘⇧H, Zoom ⌘⇧A and ⌘W — then hand you back the app you were in. With both apps in meetings they act on the one joined last. Each key's own options, such as Leave only when held, are in Stream Deck. Remove the old Teams Meeting Keys plugin: it does the same, and the two would both press.")
    }
}
