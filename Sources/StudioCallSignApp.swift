import SwiftUI

@main
struct StudioCallSignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(detector: delegate.detector, window: delegate.window)
        } label: {
            MenuBarIcon(detector: delegate.detector)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let detector = CallDetector()
    lazy var window = DisplayWindow(detector: detector)

    func applicationDidFinishLaunching(_ notification: Notification) {
        detector.start()
        window.show()
    }

    /// Clicking the Dock icon brings the display back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        detector.stop()
        window.hide()
    }
}

/// Its own view so it redraws when the call state changes.
private struct MenuBarIcon: View {
    @ObservedObject var detector: CallDetector

    var body: some View {
        Image(systemName: detector.isOnCall ? "dot.radiowaves.left.and.right" : "circle")
    }
}

private struct MenuContent: View {
    @ObservedObject var detector: CallDetector
    @ObservedObject var window: DisplayWindow

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

        Menu("Show on") {
            ForEach(window.screens, id: \.self) { screen in
                Button(screen.localizedName) { window.show(on: screen) }
            }
        }
        Button("Hide display") { window.hide() }
        Button("Show display") { window.show() }

        Divider()

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
