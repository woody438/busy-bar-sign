import SwiftUI

@main
struct BusyBarSignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(detector: delegate.detector, status: delegate.status, updater: delegate.status.updater,
                        away: delegate.status.away, calendar: delegate.calendar,
                        window: delegate.window, floating: delegate.floating, server: delegate.server,
                        openControls: { delegate.controls.show() })
        } label: {
            MenuBarIcon(status: delegate.status)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.controls.show() }
                    .keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let detector = CallDetector()
    let calendar = CalendarSource()
    lazy var status = StatusModel(detector: detector, calendar: calendar)
    lazy var window = DisplayWindow(detector: detector, status: status)
    lazy var floating = FloatingWindow(detector: detector, status: status)
    lazy var server = LocalServer(detector: detector, status: status, wall: window, saver: saver)
    let saver = SaverInstaller()
    lazy var controls = ControlsWindow(detector: detector, status: status, calendar: calendar, wall: window, floating: floating,
                                       server: server, saver: saver)

    /// Opens whichever views were up last time — the full-screen display on
    /// first launch, with the controls window so they're easy to find.
    func applicationDidFinishLaunching(_ notification: Notification) {
        detector.start()
        calendar.start()
        status.start()
        status.mute.askOnce()
        server.start()
        saver.install()
        if DisplayWindow.wasShown { window.show() }
        if FloatingWindow.wasShown { floating.show() }
        if ControlsWindow.neverShown { controls.show() }
    }

    /// Clicking the Dock icon, or opening the app again, brings up the controls.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controls.show()
        return false
    }

    /// Right-clicking the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let wall = NSMenuItem(title: "Full-Screen Display", action: #selector(toggleWall), keyEquivalent: "")
        wall.state = window.wantsVisible ? .on : .off
        menu.addItem(wall)

        let showOn = NSMenuItem(title: "Show On", action: nil, keyEquivalent: "")
        let screens = NSMenu()
        for screen in NSScreen.screens {
            let id = DisplayWindow.identifier(for: screen)
            let item = NSMenuItem(title: screen.localizedName, action: #selector(showOnScreen(_:)), keyEquivalent: "")
            item.representedObject = id
            item.state = window.wantsVisible && window.screenID == id ? .on : .off
            screens.addItem(item)
        }
        showOn.submenu = screens
        menu.addItem(showOn)

        let dnd = NSMenuItem(title: detector.dndUntil == nil ? detector.dndStartLabel : "End Do Not Disturb",
                             action: #selector(toggleDND), keyEquivalent: "")
        menu.insertItem(dnd, at: 0)
        var top = 1
        // a call the sign's warning about or says you're late for: you're there in person
        if let event = status.inPersonEvent {
            menu.insertItem(NSMenuItem(title: "In Person: “\(event.title)”", action: #selector(markInPerson), keyEquivalent: ""), at: top)
            top += 1
        }
        // the event on the sign finished early
        if let event = status.endableEvent {
            menu.insertItem(NSMenuItem(title: "End Now: “\(event.title)”", action: #selector(endEvent), keyEquivalent: ""), at: top)
            top += 1
        }
        menu.insertItem(.separator(), at: top)

        let float = NSMenuItem(title: "Floating Window", action: #selector(toggleFloating), keyEquivalent: "")
        float.state = floating.isShown ? .on : .off
        menu.addItem(float)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openControls), keyEquivalent: ""))
        for item in menu.items + screens.items where item.action != nil { item.target = self }
        return menu
    }

    @objc private func toggleWall() { window.wantsVisible ? window.hide() : window.show() }
    @objc private func toggleFloating() { floating.isShown ? floating.hide() : floating.show() }
    @objc private func openControls() { controls.show() }
    @objc private func toggleDND() { detector.toggleDND() }
    @objc private func markInPerson() { status.markInPerson() }
    @objc private func endEvent() { status.endEvent() }
    @objc private func showOnScreen(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { window.show(onScreenID: id) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        detector.stop()
        window.hide(remember: false)
    }
}

/// Its own view so it redraws when the sign changes: the pill's own marks —
/// a microphone on a call, a bell before one, a moon for Do Not Disturb,
/// a tick when free.
private struct MenuBarIcon: View {
    @ObservedObject var status: StatusModel

    var body: some View {
        Image(systemName: status.state.symbol)
    }
}

private struct MenuContent: View {
    @ObservedObject var detector: CallDetector
    @ObservedObject var status: StatusModel
    @ObservedObject var updater: Updater
    @ObservedObject var away: Away
    @ObservedObject var calendar: CalendarSource
    @ObservedObject var window: DisplayWindow
    @ObservedObject var floating: FloatingWindow
    @ObservedObject var server: LocalServer
    let openControls: () -> Void
    @AppStorage("wallLayout") private var wallLayout: BarLayout = .wide

    var body: some View {
        if detector.dndUntil != nil, status.state == .dnd {
            Text(detector.dndStatus() ?? "Do Not Disturb")
        } else {
            Text(status.stateName)
        }
        Text(status.decision.why)
        Text(detector.detection.sourceLine)
        if calendar.enabled, let problem = calendar.problem { Text(problem) }
        if let problem = server.problem { Text(problem) }
        if window.waitingForScreen {
            Text("Waiting for the wall display to reconnect")
        } else if window.onScaledScreen {
            Text("Display is in a scaled mode — the LEDs may shimmer (see README)")
        }

        Divider()

        Picker("Sign", selection: $detector.override) {
            ForEach(Override.allCases) { Text($0.label).tag($0) }
        }
        Picker("Detect", selection: $detector.policy) {
            ForEach(DetectionPolicy.allCases) { Text($0.label).tag($0) }
        }
        microphone
        Toggle("Follow My Calendar", isOn: $calendar.enabled)

        Divider()

        if detector.dndUntil == nil {
            Button(detector.dndStartLabel) { detector.startDND() }
        } else {
            Button("End Do Not Disturb") { detector.endDND() }
        }
        // a call the sign's warning about or says you're late for: you're there in person
        if let event = status.inPersonEvent {
            Button("In Person: “\(event.title)”") { status.markInPerson() }
        }
        // the event on the sign finished early
        if let event = status.endableEvent {
            Button("End Now: “\(event.title)”") { status.endEvent() }
        }

        Divider()

        // the away keys, as on the Stream Deck
        Toggle(away.nearbyName, isOn: Binding(get: { away.kind == .nearby }, set: { _ in away.press(.nearby) }))
        Toggle("Lunch", isOn: Binding(get: { away.kind == .lunch }, set: { _ in away.press(.lunch) }))
        Button(away.kind == .backIn ? "Back In: 10 More Minutes" : "Back In 10 Minutes") { away.press(.backIn) }
        if away.kind != nil {
            Button("I'm Back") { away.end() }
        }

        Divider()

        Toggle("Full-screen display", isOn: Binding(
            get: { window.wantsVisible },
            set: { $0 ? window.show() : window.hide() }))
        Picker("Show on", selection: Binding(
            get: { window.screenID ?? "" },
            set: { id in if !id.isEmpty { window.show(onScreenID: id) } })) {
            ForEach(window.screens, id: \.self) { screen in
                Text(screen.localizedName).tag(DisplayWindow.identifier(for: screen))
            }
        }
        Picker("Layout", selection: $wallLayout) {
            ForEach(BarLayout.allCases) { Text($0.label).tag($0) }
        }
        Toggle("Floating window", isOn: Binding(
            get: { floating.isShown },
            set: { $0 ? floating.show() : floating.hide() }))
        Picker("Floating size", selection: $floating.size) {
            ForEach(FloatingWindow.Size.allCases) { Text($0.label).tag($0) }
        }

        Divider()

        if let next = updater.available, updater.phase == .available {
            Button("Install Update (Build \(next.build)) and Reopen") { updater.install() }
        }
        if updater.plugin != nil {
            Button(updater.pluginIncomplete ? "Reinstall the Stream Deck Plugin…" : "Update the Stream Deck Plugin…") { updater.updatePlugin() }
        }
        Button("Check for Updates") { updater.check() }
        Button("Settings…") { openControls() }
            .keyboardShortcut(",")
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// What has the microphone right now, and a way to stop an app lighting
    /// the sign without touching the code.
    @ViewBuilder private var microphone: some View {
        let holders = uniqueByApp(detector.detection.holders)
        if !holders.isEmpty || !detector.userIgnored.isEmpty {
            Menu("Microphone") {
                ForEach(holders, id: \.bundleID) { holder in
                    let id = holder.bundleID ?? ""
                    Toggle("Ignore \(holder.name)", isOn: Binding(
                        get: { detector.userIgnored.contains(id) },
                        set: { detector.setIgnored(id, $0) }))
                }
                let away = detector.userIgnored.subtracting(holders.compactMap(\.bundleID)).sorted()
                if !away.isEmpty {
                    Divider()
                    ForEach(away, id: \.self) { id in
                        Button("Stop ignoring \(id)") { detector.setIgnored(id, false) }
                    }
                }
            }
        }
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
