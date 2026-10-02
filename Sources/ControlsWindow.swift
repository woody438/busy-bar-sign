import AppKit
import SwiftUI

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

    init(detector: CallDetector, status: StatusModel, calendar: CalendarSource, wall: DisplayWindow, floating: FloatingWindow) {
        self.detector = detector
        self.status = status
        self.calendar = calendar
        self.wall = wall
        self.floating = floating
        super.init()
    }

    /// True until the controls have been shown once, so a first launch
    /// introduces them.
    static var neverShown: Bool { !UserDefaults.standard.bool(forKey: "controlsShown") }

    func show() {
        if window == nil {
            let view = ControlsView(detector: detector, status: status, calendar: calendar, wall: wall, floating: floating)
            let controller = NSHostingController(rootView: view)
            // the window follows the tab's height
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

/// The controls in four tabs: what the sign says and why, where it shows,
/// what in your calendar drives it, and what counts as a call.
struct ControlsView: View {
    @ObservedObject var detector: CallDetector
    @ObservedObject var status: StatusModel
    @ObservedObject var calendar: CalendarSource
    @ObservedObject var wall: DisplayWindow
    @ObservedObject var floating: FloatingWindow
    @AppStorage("controlsTab") private var tab: Tab = .status

    enum Tab: String, CaseIterable {
        case status, displays, calendar, microphone
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .status: return "switch.2"
            case .displays: return "display"
            case .calendar: return "calendar"
            case .microphone: return "mic"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.symbol).font(.system(size: 18)).frame(height: 22)
                            Text(t.label).font(.system(size: 11))
                        }
                        .frame(width: 78, height: 46)
                        .contentShape(Rectangle())
                        .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 7).fill(tab == t ? Color.primary.opacity(0.08) : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == t ? .isSelected : [])
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                switch tab {
                case .status: StatusTab(detector: detector, status: status, calendar: calendar, wall: wall)
                case .displays: DisplaysTab(wall: wall, floating: floating)
                case .calendar: CalendarTab(calendar: calendar)
                case .microphone: MicrophoneTab(detector: detector)
                }
                Text("Also in the menu-bar icon and the Dock icon's menu. Reopen this window by clicking the Dock icon.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Status

private struct StatusTab: View {
    @ObservedObject var detector: CallDetector
    @ObservedObject var status: StatusModel
    @ObservedObject var calendar: CalendarSource
    @ObservedObject var wall: DisplayWindow

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                BarPreview(status: status)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(status.state.colour).frame(width: 10, height: 10)
                    Text(status.state.name).font(.headline)
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
        }
        Note("Double-click the bar, full-screen or floating, to start or end Do Not Disturb. A call still shows ON A CALL.")

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
        }
        if wall.waitingForScreen {
            Warning(text: "Waiting for the wall display to reconnect.")
        } else if wall.onScaledScreen {
            Warning(text: "The wall display is in a scaled mode, so the LEDs may shimmer. Use its default or native resolution.")
        }
    }
}

/// The bar as it is now, small: the same engine and raster as the wall.
private struct BarPreview: View {
    @ObservedObject var status: StatusModel
    @StateObject private var bar = BarModel()
    @Environment(\.displayScale) private var scale

    var body: some View {
        let pitch = max(Int((4 * scale).rounded()), 2)          // 4 points an LED
        LEDPanelView(model: bar, pitchPixels: pitch, layout: .wide)
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

// MARK: - Calendar

private struct CalendarTab: View {
    @ObservedObject var calendar: CalendarSource

    var body: some View {
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
                Row(label: "Show LATE FOR CALL for up to") {
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

        Heading("What to put in Outlook")
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

        Heading("Words the sign looks for")
        Card {
            keywordRow("LUNCH", $calendar.lunchWords, divider: false)
            keywordRow("DO NOT DISTURB", $calendar.dndWords)
            keywordRow("ON A CALL", $calendar.callWords)
            keywordRow("OUT OF OFFICE", $calendar.oooWords)
        }
        Note("Only your own events — ones with no invitees — are matched by title: whole words, any case, separated by commas. Meetings are sorted by their invitees and join link, so their titles never matter.")
    }

    private func keywordRow(_ label: String, _ text: Binding<String>, divider: Bool = true) -> some View {
        Row(label: label, divider: divider) {
            TextField(label, text: text).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 260)
        }
    }
}

/// Each state as the bar draws it, and what puts it there.
private enum Guide {
    struct Line { let state: BarState?; let how: String; let more: String }
    static let rows: [Line] = [
        Line(state: .call, how: "Automatic when an app uses your microphone.",
             more: "Counts down to when you're free, through back-to-back meetings. Or an event of your own with “call” in the title, e.g. “Call - Linda”, for calls on your phone."),
        Line(state: .meeting, how: "A meeting with invitees and no Teams, Zoom or Meet link.",
             more: "In-person meetings: the room or your office as the location."),
        Line(state: .callIn, how: "10 minutes before a call or a meeting.",
             more: "BUSY IN for a meeting in person. A countdown, then the start time."),
        Line(state: .late, how: "A call has started and your microphone hasn't.",
             more: "Pulses for up to 10 minutes, then FREE. Joining turns it red."),
        Line(state: .freeTil, how: "You left a call before its slot ended.",
             more: "Until the booked end time — the time was set aside."),
        Line(state: .callTbc, how: "Show As: Tentative on a meeting.",
             more: "Counts down to the start, then shows the end. BUSY TBC in person. Never shows LATE."),
        Line(state: .dnd, how: "An event titled “No meetings” or “Focus”.",
             more: "Or double-click the bar for 30 minutes. Warnings for calls still show inside it."),
        Line(state: .lunch, how: "An event of your own with “lunch” in the title.",
             more: "Beats any meeting over it: no warnings during lunch."),
        Line(state: .away, how: "Any other event of your own — no invitees.",
             more: "e.g. “Gym”, “Drive home”, “School run”. Beats meetings too."),
        Line(state: .ooo, how: "Show As: Out of Office, an all-day busy event, or ✈ in the title.",
             more: "Flight apps such as Flighty put the ✈ in."),
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
            .callIn: BarTimer(left: 461, h: 11, m: 0), .late: BarTimer(left: 80, h: 9, m: 45),
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
