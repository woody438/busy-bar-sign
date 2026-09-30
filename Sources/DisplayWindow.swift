import AppKit
import SwiftUI

/// A borderless window that owns one screen: the wall display.
///
/// - It returns to the same monitor after a reboot or a reconnect, and if that
///   monitor goes away (switched off, asleep, unplugged) it waits for it rather
///   than covering another display.
/// - On a secondary screen it sits above that screen's menu bar and Dock, so
///   nothing covers the sign while another app is in front.
/// - Only an explicit "Show on" or launch brings the app forward. Screen
///   changes never take focus, or cover what you're working on.
/// - It ignores the mouse, so a stray click on the wall can't take focus
///   from a call.
@MainActor
final class DisplayWindow: NSObject, NSWindowDelegate, ObservableObject {

    private var window: NSWindow?
    private var activity: NSObjectProtocol?
    private let detector: CallDetector
    /// Whether the user wants the display up (independent of whether its
    /// monitor is currently connected).
    private(set) var wantsVisible = false

    /// The connected screens, kept current for the menu.
    @Published private(set) var screens: [NSScreen] = NSScreen.screens
    /// True while the chosen monitor is away and the display is waiting for it.
    @Published private(set) var waitingForScreen = false
    /// Whether the display's screen runs in a scaled mode ("looks like …" at a
    /// size that isn't the panel's own pixels, or exactly half of them). Then
    /// macOS resamples everything and the LEDs can't land on whole pixels.
    @Published private(set) var onScaledScreen = false

    /// Which monitor to use. (A new key: version 1 saved a bare display
    /// number under a different one, which can't identify a monitor reliably.)
    private var preferredScreenID: String? {
        get { UserDefaults.standard.string(forKey: "wallScreen") }
        set { UserDefaults.standard.set(newValue, forKey: "wallScreen") }
    }

    init(detector: CallDetector) {
        self.detector = detector
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Show the display. Passing a screen makes it the chosen monitor.
    func show(on screen: NSScreen? = nil) {
        wantsVisible = true
        if let screen {
            // the menu may hold a stale screen object: look it up afresh
            let id = Self.identifier(for: screen)
            guard let current = NSScreen.screens.first(where: { Self.identifier(for: $0) == id }) else { return }
            preferredScreenID = id
            place(on: current, bringForward: true)
        } else if let target = resolveScreen() {
            // Remember an automatic pick only if it's a secondary screen, so a
            // first launch before the wall is plugged in doesn't pin the desk.
            if preferredScreenID == nil && !Self.isMenuBarScreen(target) {
                preferredScreenID = Self.identifier(for: target)
            }
            place(on: target, bringForward: true)
        } else {
            waitingForScreen = true
            return
        }
        NSApp.activate()
    }

    func hide() {
        wantsVisible = false
        waitingForScreen = false
        takeDown()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - Placement

    private func place(on target: NSScreen, bringForward: Bool) {
        if window == nil {
            let hosting = NSHostingView(rootView: BarDisplayView(detector: detector))
            let w = NSWindow(contentRect: target.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = hosting
            w.backgroundColor = .black
            w.isOpaque = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.ignoresMouseEvents = true
            w.delegate = self
            window = w
        }
        guard let window else { return }
        let onMenuBarScreen = Self.isMenuBarScreen(target)
        let wasVisible = window.isVisible

        if onMenuBarScreen {
            // It can't sit above the main menu bar, or the Mac becomes
            // unusable; instead the menu bar and Dock hide while we're in front.
            window.level = .normal
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        } else {
            // Above this screen's menu bar, Dock and menu-bar icons.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            NSApp.presentationOptions = []
        }
        window.setFrame(target.frame, display: true)

        if !wasVisible || bringForward {
            if bringForward || !onMenuBarScreen || NSApp.isActive {
                window.orderFrontRegardless()
            } else {
                // coming back on the screen you're working on: behind your
                // windows, not over them
                window.orderBack(nil)
            }
        }

        waitingForScreen = false
        let scaled = Self.isScaledMode(target)
        if scaled != onScaledScreen { onScaledScreen = scaled }

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

    /// The chosen monitor if it's connected (nil if it's away); with nothing
    /// chosen, any screen but the one with the menu bar, else that one.
    private func resolveScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let saved = preferredScreenID {
            return screens.first(where: { Self.matches($0, saved) })
        }
        return screens.first(where: { !Self.isMenuBarScreen($0) }) ?? screens.first
    }

    @objc private func screensChanged() {
        screens = NSScreen.screens
        guard wantsVisible else { return }
        // A monitor may have arrived that suits better than the menu-bar screen.
        if preferredScreenID == nil, let target = resolveScreen(), !Self.isMenuBarScreen(target) {
            preferredScreenID = Self.identifier(for: target)
        }
        if let target = resolveScreen() {
            place(on: target, bringForward: false)       // no activation
        } else {
            takeDown()                                   // the wall is away; don't cover the desk
            waitingForScreen = true
        }
    }

    // MARK: - Screen identity

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Compared by display, not by object: AppKit replaces screen objects when
    /// the arrangement changes.
    static func isMenuBarScreen(_ screen: NSScreen) -> Bool {
        guard let id = displayID(screen) else { return screen == NSScreen.screens.first }
        return CGDisplayIsMain(id) != 0
    }

    /// "vendor-model-serial-number". The serial identifies the monitor even
    /// if it moves port; monitors that report no serial fall back to the
    /// display number, so two identical monitors are never confused.
    static func identifier(for screen: NSScreen) -> String {
        guard let id = displayID(screen) else { return "?-?-0-\(screen.localizedName)" }
        return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))-\(id)"
    }

    private static func matches(_ screen: NSScreen, _ saved: String) -> Bool {
        let mine = identifier(for: screen)
        if mine == saved { return true }
        let a = mine.split(separator: "-"), b = saved.split(separator: "-")
        guard a.count == 4, b.count == 4, a[2] != "0" else { return false }
        return a[0] == b[0] && a[1] == b[1] && a[2] == b[2]
    }

    static func isScaledMode(_ screen: NSScreen) -> Bool {
        guard let display = displayID(screen), let current = CGDisplayCopyDisplayMode(display) else { return false }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else { return false }
        // The panel's own resolution: the largest 1x mode, preferring ones
        // the display flags as native.
        let oneX = modes.filter { $0.width == $0.pixelWidth }
        let nativeFlag: UInt32 = 0x0200_0000     // kDisplayModeNativeFlag
        let flagged = oneX.filter { $0.ioFlags & nativeFlag != 0 }
        guard let native = (flagged.isEmpty ? oneX : flagged).max(by: { $0.pixelWidth < $1.pixelWidth }) else {
            return false
        }
        // Exact when the backing store is the panel's own pixels: native, or a
        // HiDPI mode at exactly half the panel ("looks like 1920 x 1080" on 4K).
        return current.pixelWidth != native.pixelWidth || current.pixelHeight != native.pixelHeight
    }
}
