import AppKit
import SwiftUI

/// A borderless window that owns one screen: the wall display.
///
/// - It returns to the same screen after a reboot or a reconnect, and if that
///   screen goes away (switched off, asleep, unplugged) it waits for it rather
///   than covering another display.
/// - On a secondary screen it sits above that screen's menu bar and Dock, so
///   nothing covers the sign while another app is in front.
/// - Only an explicit "Show on" or launch brings the app forward; screen
///   changes never steal focus from the call you're on.
@MainActor
final class DisplayWindow: NSObject, NSWindowDelegate, ObservableObject {

    private var window: NSWindow?
    private var activity: NSObjectProtocol?
    private let detector: CallDetector
    /// Whether the user wants the display up (independent of whether its
    /// screen is currently connected).
    private(set) var wantsVisible = false

    /// Whether the display's screen runs in a scaled mode ("looks like …" at a
    /// size that isn't the panel's own pixels, or exactly half of them). Then
    /// macOS resamples everything and the LEDs can't land on whole pixels.
    @Published private(set) var onScaledScreen = false

    /// Persisted, so the app returns to the same monitor.
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

    /// Show the display. Passing a screen makes it the preferred one.
    func show(on screen: NSScreen? = nil) {
        wantsVisible = true
        if let screen { preferredScreenID = Self.identifier(for: screen) }
        guard let target = screen ?? resolveScreen() else { return }
        if preferredScreenID == nil { preferredScreenID = Self.identifier(for: target) }
        place(on: target)
        NSApp.activate()
        // On the menu-bar screen the window can't sit above the menu bar, so
        // hide it (and the Dock) while we're frontmost instead.
        NSApp.presentationOptions = target == NSScreen.screens.first ? [.autoHideDock, .autoHideMenuBar] : []
    }

    func hide() {
        wantsVisible = false
        takeDown()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - Placement

    private func place(on target: NSScreen) {
        if window == nil {
            let hosting = NSHostingView(rootView: BarDisplayView(detector: detector))
            let w = NSWindow(contentRect: target.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = hosting
            w.backgroundColor = .black
            w.isOpaque = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            w.delegate = self
            window = w
        }
        guard let window else { return }
        // Above the menu bar and Dock — but never on the screen that has the
        // main menu bar, or the Mac becomes unusable.
        window.level = target == NSScreen.screens.first
            ? .normal
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        window.setFrame(target.frame, display: true)
        window.orderFrontRegardless()
        onScaledScreen = Self.isScaledMode(target)

        // Keep the monitor awake — this is a display, not a screensaver.
        // (macOS applies this to every display, not just this one.)
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "Studio Call Sign is on the wall")
        }
    }

    private func takeDown() {
        window?.orderOut(nil)
        NSApp.presentationOptions = []
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// The saved screen if it's connected; with nothing saved, any screen but
    /// the one with the menu bar, else that one.
    private func resolveScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let saved = preferredScreenID {
            if let exact = screens.first(where: { Self.identifier(for: $0) == saved }) { return exact }
            // display numbers can change across reconnects; the name doesn't
            let name = Self.name(fromIdentifier: saved)
            if let byName = screens.first(where: { $0.localizedName == name }) { return byName }
            return nil     // its screen is away: wait for it
        }
        let primary = screens.first
        return screens.first(where: { $0 != primary }) ?? primary
    }

    @objc private func screensChanged() {
        guard wantsVisible else { return }
        if let target = resolveScreen() {
            place(on: target)          // no activation: don't take focus from a call
        } else {
            takeDown()                 // the wall display is away; don't cover the desk
        }
    }

    // MARK: - Screen identity

    static func identifier(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return "\(number?.stringValue ?? "?")|\(screen.localizedName)"
    }

    private static func name(fromIdentifier id: String) -> String {
        guard let bar = id.firstIndex(of: "|") else { return id }
        return String(id[id.index(after: bar)...])
    }

    static func isScaledMode(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        let display = CGDirectDisplayID(number.uint32Value)
        guard let current = CGDisplayCopyDisplayMode(display) else { return false }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else { return false }
        let nativeFlag: UInt32 = 0x0200_0000     // kDisplayModeNativeFlag
        guard let native = modes.first(where: { $0.ioFlags & nativeFlag != 0 }) else { return false }
        // Exact when the backing store is the panel's own pixels: native, or a
        // HiDPI mode at exactly half the panel ("looks like 1920 x 1080" on 4K).
        return current.pixelWidth != native.pixelWidth
    }
}
