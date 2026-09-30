import SwiftUI

@main
struct BusyBarSignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(detector: delegate.detector, window: delegate.window, floating: delegate.floating,
                        openControls: { delegate.controls.show() })
        } label: {
            MenuBarIcon(detector: delegate.detector)
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
    lazy var window = DisplayWindow(detector: detector)
    lazy var floating = FloatingWindow(detector: detector)
    lazy var controls = ControlsWindow(detector: detector, wall: window, floating: floating)

    /// Opens whichever views were up last time — the full-screen display on
    /// first launch, with the controls window so they're easy to find.
    func applicationDidFinishLaunching(_ notification: Notification) {
        detector.start()
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
    @objc private func showOnScreen(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { window.show(onScreenID: id) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        detector.stop()
        window.hide(remember: false)
    }
}

/// Its own view so it redraws when the call state changes.
private struct MenuBarIcon: View {
    @ObservedObject var detector: CallDetector

    var body: some View {
        // the pill's own marks: a microphone on a call, a tick when free
        Image(systemName: detector.isOnCall ? "mic.circle.fill" : "checkmark.circle")
    }
}

private struct MenuContent: View {
    @ObservedObject var detector: CallDetector
    @ObservedObject var window: DisplayWindow
    @ObservedObject var floating: FloatingWindow
    let openControls: () -> Void

    var body: some View {
        Text(detector.isOnCall ? "On a call" : "Free")
        Text(detector.detection.sourceLine)
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
        Toggle("Floating window", isOn: Binding(
            get: { floating.isShown },
            set: { $0 ? floating.show() : floating.hide() }))
        Picker("Floating size", selection: $floating.size) {
            ForEach(FloatingWindow.Size.allCases) { Text($0.label).tag($0) }
        }

        Divider()

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
