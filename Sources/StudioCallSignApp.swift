import SwiftUI

@main
struct StudioCallSignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Studio Call Sign", systemImage: delegate.detector.isOnCall ? "dot.radiowaves.left.and.right" : "circle") {
            MenuContent(detector: delegate.detector, window: delegate.window)
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

    func applicationWillTerminate(_ notification: Notification) {
        detector.stop()
        window.hide()
    }
}

private struct MenuContent: View {
    @ObservedObject var detector: CallDetector
    let window: DisplayWindow

    var body: some View {
        Text(detector.isOnCall ? "On a call" : "Free")
        Text(detector.detection.sourceLine)

        Divider()

        Picker("Sign", selection: $detector.override) {
            ForEach(Override.allCases) { Text($0.label).tag($0) }
        }
        Picker("Detect", selection: $detector.policy) {
            ForEach(DetectionPolicy.allCases) { Text($0.label).tag($0) }
        }

        Divider()

        Menu("Show on") {
            ForEach(NSScreen.screens, id: \.self) { screen in
                Button(screen.localizedName) { window.show(on: screen) }
            }
        }
        Button("Hide display") { window.hide() }
        Button("Show display") { window.show() }

        Divider()

        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
