import AppKit
import Combine
import IOKit.pwr_mgt
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
/// - It's a non-activating panel, so clicking it never takes focus from a
///   call. A double-click toggles Do Not Disturb; single clicks do nothing.
/// - It keeps the Mac and its displays awake while it's up — but out of hours,
///   while the wall's dark, it lets the displays sleep (if Settings says they
///   may), and wakes them when the wall lights again.
@MainActor
final class DisplayWindow: NSObject, NSWindowDelegate, ObservableObject {

    private var window: NSWindow?
    private var activity: NSObjectProtocol?
    /// Whether `activity` keeps the displays awake, or only the Mac.
    private var activityHoldsDisplays = false
    /// Out of hours, dark, with the displays allowed to sleep.
    private var displaysMaySleep = false
    private var watching: AnyCancellable?
    private let detector: CallDetector
    /// Whether the user wants the display up (independent of whether its
    /// monitor is currently connected).
    @Published private(set) var wantsVisible = false

    /// Whether it was up when the app last quit. On by default: the wall is
    /// what the app is for.
    static var wasShown: Bool { UserDefaults.standard.object(forKey: "wallShown") as? Bool ?? true }

    /// The connected screens, kept current for the menu.
    @Published private(set) var screens: [NSScreen] = NSScreen.screens
    /// True while the chosen monitor is away and the display is waiting for it.
    @Published private(set) var waitingForScreen = false
    /// Whether the display's screen runs in a scaled mode ("looks like …" at a
    /// size that isn't the panel's own pixels, or exactly half of them). Then
    /// macOS resamples everything and the LEDs can't land on whole pixels.
    @Published private(set) var onScaledScreen = false
    /// The monitor the display is on, or is waiting for (see `identifier(for:)`).
    @Published private(set) var screenID: String? = UserDefaults.standard.string(forKey: "wallScreen")

    /// Which monitor to use. (A new key: version 1 saved a bare display
    /// number under a different one, which can't identify a monitor reliably.)
    private var preferredScreenID: String? {
        get { UserDefaults.standard.string(forKey: "wallScreen") }
        set {
            UserDefaults.standard.set(newValue, forKey: "wallScreen")
            if screenID != newValue { screenID = newValue }
        }
    }

    private let status: StatusModel

    init(detector: CallDetector, status: StatusModel) {
        self.detector = detector
        self.status = status
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        watching = status.$wallDark.combineLatest(status.$wallHours.map(\.sleeps))
            .map { dark, sleeps in dark && sleeps }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] maySleep in MainActor.assumeIsolated { self?.setDisplaysMaySleep(maySleep) } }
    }

    /// Show the display. Passing a screen makes it the chosen monitor.
    func show(on screen: NSScreen? = nil) {
        wantsVisible = true
        UserDefaults.standard.set(true, forKey: "wallShown")
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

    /// Show the display on the monitor with this identifier, if it's connected.
    func show(onScreenID id: String) {
        guard let screen = NSScreen.screens.first(where: { Self.identifier(for: $0) == id }) else { return }
        show(on: screen)
    }

    /// `remember: false` when quitting, so it comes back next launch.
    func hide(remember: Bool = true) {
        wantsVisible = false
        if remember { UserDefaults.standard.set(false, forKey: "wallShown") }
        waitingForScreen = false
        takeDown()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The monitor the display is showing on, by display number, for the
    /// screen saver; nil while it isn't up.
    var displayNumber: UInt32? {
        guard let window, window.isVisible, let screen = window.screen else { return nil }
        return Self.displayID(screen)
    }

    /// The full-screen display's layout (the controls' Layout).
    static var layout: BarLayout { BarLayout(rawValue: UserDefaults.standard.string(forKey: "wallLayout") ?? "") ?? .wide }

    // MARK: - Placement

    private func place(on target: NSScreen, bringForward: Bool) {
        if window == nil {
            let hosting = NSHostingView(rootView: BarDisplayView(status: status))
            let w = NSPanel(contentRect: target.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            w.hidesOnDeactivate = false          // panels hide when their app isn't frontmost by default
            w.becomesKeyOnlyIfNeeded = true
            let container = NSView(frame: NSRect(origin: .zero, size: target.frame.size))
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            let surface = BarSurface(frame: container.bounds)
            surface.autoresizingMask = [.width, .height]
            surface.onDoubleClick = { [weak self] in self?.status.pressStatus() }
            container.addSubview(surface)
            w.contentView = container
            w.backgroundColor = .black
            w.isOpaque = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
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
        let id = Self.identifier(for: target)
        if screenID != id { screenID = id }
        let scaled = Self.isScaledMode(target)
        if scaled != onScaledScreen { onScaledScreen = scaled }

        holdAwake(displays: !displaysMaySleep)
    }

    /// `keepingMacAwake`: the wall's monitor has gone because it was let sleep
    /// out of hours, so the Mac stays up to wake it when the hours begin.
    private func takeDown(keepingMacAwake: Bool = false) {
        window?.orderOut(nil)
        NSApp.presentationOptions = []
        if keepingMacAwake {
            holdAwake(displays: false)
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    // MARK: - Keeping awake

    /// Keep the Mac awake — and the monitor, unless it may sleep out of hours:
    /// this is a display, not a screensaver. (macOS applies this to every
    /// display, not just this one.)
    private func holdAwake(displays: Bool) {
        guard activity == nil || activityHoldsDisplays != displays else { return }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = ProcessInfo.processInfo.beginActivity(
            options: displays ? [.idleDisplaySleepDisabled, .idleSystemSleepDisabled] : [.idleSystemSleepDisabled],
            reason: "Busy Bar Sign is on the wall")
        activityHoldsDisplays = displays
    }

    /// The wall's gone dark out of hours, or lit again.
    private func setDisplaysMaySleep(_ maySleep: Bool) {
        guard maySleep != displaysMaySleep else { return }
        displaysMaySleep = maySleep
        guard window?.isVisible ?? false || waitingForScreen else { return }
        holdAwake(displays: !maySleep)
        if !maySleep { wakeDisplays() }
    }

    /// Lit again after a night's sleep — the hours have begun, or a call's
    /// come in — so the displays come back on. Not while the Mac's locked: they'd
    /// show only its lock screen, and come on when you're back at it.
    private func wakeDisplays() {
        guard !status.away.locked else { return }
        let asleep = window?.screen.flatMap(Self.displayID).map { CGDisplayIsAsleep($0) != 0 } ?? true
        guard asleep || waitingForScreen else { return }
        var assertion: IOPMAssertionID = 0
        guard IOPMAssertionDeclareUserActivity("Busy Bar Sign: the wall's lit again" as CFString,
                                               kIOPMUserActiveLocal, &assertion) == kIOReturnSuccess else { return }
        let id = assertion
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { IOPMAssertionRelease(id) }
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
            takeDown(keepingMacAwake: displaysMaySleep)  // the wall is away; don't cover the desk
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
