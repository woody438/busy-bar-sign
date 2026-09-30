import AppKit
import SwiftUI

/// A borderless window pinned to one screen, with the menu bar and Dock
/// hidden while it's frontmost.
@MainActor
final class DisplayWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var activity: NSObjectProtocol?
    private let detector: CallDetector

    /// Persisted so the app returns to the same monitor after a reboot or a
    /// display reconnect.
    private var preferredScreenID: String? {
        get { UserDefaults.standard.string(forKey: "preferredScreenID") }
        set { UserDefaults.standard.set(newValue, forKey: "preferredScreenID") }
    }

    init(detector: CallDetector) {
        self.detector = detector
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func show(on screen: NSScreen? = nil) {
        let target = screen ?? resolveScreen()
        preferredScreenID = Self.identifier(for: target)

        if window == nil {
            let hosting = NSHostingView(rootView: DisplayView(detector: detector))
            let w = NSWindow(contentRect: target.frame,
                             styleMask: [.borderless],
                             backing: .buffered,
                             defer: false)
            w.contentView = hosting
            w.backgroundColor = .black
            w.isOpaque = true
            w.hasShadow = false
            w.level = .normal
            w.collectionBehavior = [.fullScreenAuxiliary, .stationary]
            w.delegate = self
            window = w
        }

        window?.setFrame(target.frame, display: true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]

        // Keep the monitor awake — this is a display, not a screensaver.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "Studio Call Sign is on the wall")
        }
    }

    func hide() {
        window?.orderOut(nil)
        NSApp.presentationOptions = []
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Prefer the saved screen; then any external screen; then the main one.
    private func resolveScreen() -> NSScreen {
        let screens = NSScreen.screens
        if let saved = preferredScreenID,
           let match = screens.first(where: { Self.identifier(for: $0) == saved }) {
            return match
        }
        return screens.first(where: { $0 != NSScreen.main }) ?? screens.first ?? NSScreen.main!
    }

    @objc private func screensChanged() {
        guard isVisible else { return }
        show(on: resolveScreen())
    }

    static func identifier(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? screen.localizedName
    }
}
