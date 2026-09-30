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
    private let wall: DisplayWindow
    private let floating: FloatingWindow

    init(detector: CallDetector, wall: DisplayWindow, floating: FloatingWindow) {
        self.detector = detector
        self.wall = wall
        self.floating = floating
        super.init()
    }

    /// True until the controls have been shown once, so a first launch
    /// introduces them.
    static var neverShown: Bool { !UserDefaults.standard.bool(forKey: "controlsShown") }

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: ControlsView(detector: detector, wall: wall, floating: floating))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Busy Bar Sign"
            w.contentView = hosting
            w.setContentSize(hosting.fittingSize)
            w.isReleasedWhenClosed = false
            w.delegate = self
            // on the screen you're working at, not the wall
            if let main = NSScreen.screens.first(where: DisplayWindow.isMenuBarScreen) {
                let v = main.visibleFrame, size = w.frame.size
                w.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2))
            } else {
                w.center()
            }
            w.setFrameAutosaveName("Controls")
            window = w
        }
        UserDefaults.standard.set(true, forKey: "controlsShown")
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Everything the menu-bar menu offers, laid out as a settings window.
struct ControlsView: View {
    @ObservedObject var detector: CallDetector
    @ObservedObject var wall: DisplayWindow
    @ObservedObject var floating: FloatingWindow
    /// Refreshed when monitors come and go.
    @State private var screens = NSScreen.screens
    /// The full-screen display's layout (BarDisplayView reads the same setting).
    @AppStorage("wallLayout") private var wallLayout: BarLayout = .wide

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Circle()
                        .fill(signColour)
                        .frame(width: 12, height: 12)
                    Text(signName)
                        .font(.headline)
                }
                Text(detector.detection.sourceLine)
                    .foregroundStyle(.secondary)
                if wall.waitingForScreen {
                    Label("Waiting for the wall display to reconnect", systemImage: "display.trianglebadge.exclamationmark")
                } else if wall.onScaledScreen {
                    Label("The display is in a scaled mode, so the LEDs may shimmer (see README)",
                          systemImage: "exclamationmark.triangle")
                }
            }

            Section("Do Not Disturb") {
                if detector.dndUntil == nil {
                    Button(detector.dndStartLabel) { detector.startDND() }
                } else {
                    // ticks over once a second
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(detector.dndStatus(at: context.date) ?? "")
                    }
                    Button("End Do Not Disturb") { detector.endDND() }
                }
                Text("Or double-click the bar, full-screen or floating: once to start, again to end. A call still shows ON A CALL; when it ends, the bar goes back to Do Not Disturb for whatever time is left.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Full-screen display") {
                Toggle("Show full-screen display", isOn: Binding(
                    get: { wall.wantsVisible },
                    set: { $0 ? wall.show() : wall.hide() }))
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
                Picker("Layout", selection: $wallLayout) {
                    ForEach(BarLayout.allCases) { Text($0.label).tag($0) }
                }
                Text("Stacked puts the status on top and a big clock beneath, filling small screens such as 960 × 540. The floating window always uses the wide bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Floating window") {
                Toggle("Show floating window", isOn: Binding(
                    get: { floating.isShown },
                    set: { $0 ? floating.show() : floating.hide() }))
                Picker("Size", selection: $floating.size) {
                    ForEach(FloatingWindow.Size.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Drag the floating window to move it, including onto another monitor. Right-click it for sizes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Sign") {
                Picker("Sign", selection: $detector.override) {
                    ForEach(Override.allCases) { Text($0.label).tag($0) }
                }
                Picker("Detect", selection: $detector.policy) {
                    ForEach(DetectionPolicy.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                Text("These controls are also in the menu-bar icon (a tick; a microphone during a call; a moon for Do Not Disturb) and in the Dock icon's right-click menu. Reopen this window by clicking the Dock icon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

    private var signName: String {
        switch detector.sign {
        case .call: return "On a call"
        case .dnd: return "Do Not Disturb"
        case .free: return "Free"
        }
    }

    private var signColour: Color {
        switch detector.sign {
        case .call: return .red
        case .dnd: return .indigo
        case .free: return .green
        }
    }

    private func screenLabel(_ screen: NSScreen) -> String {
        DisplayWindow.isMenuBarScreen(screen) ? "\(screen.localizedName) (main)" : screen.localizedName
    }
}
