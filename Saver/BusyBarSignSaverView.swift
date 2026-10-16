import AppKit
import ScreenSaver

/*
 * The Busy Bar Sign screen saver: the sign on every screen while you're
 * away from the Mac. The lock screen covers every display and no app can
 * draw over it; a screen saver can, locked or not.
 *
 * It asks the app what the sign says once a second (SaverStatus), and draws
 * it with the wall's own engine and LEDs: on the wall's monitor as the
 * full-screen display is laid out (wide or stacked), on every other screen
 * as the wide bar. Just the LEDs, as large as whole pixels allow — no case.
 * While the app doesn't answer it says WANDERING: the screen saver's on, so
 * you're not at the Mac.
 *
 * It runs inside macOS's legacyScreenSaver, which since Sonoma keeps savers
 * going after they're dismissed and starts more than it stops. So when the
 * screen saver ends it stops drawing and asking, and a couple of seconds
 * later quits its host, as Aerial and the others do; the next start gets a
 * fresh one.
 */
@objc(BusyBarSignSaverView)
final class BusyBarSignSaverView: ScreenSaverView {
    private let bar = BarModel()
    private let panel = LEDPanelNSView(frame: .zero)
    private let client = SaverStatusClient()
    private var poll: Timer?
    private var startedAt = Date()
    private var heardAt: Date?
    private var wall: SaverStatus.Wall?
    private var drift = CGSize.zero
    private var ticks = 0
    private var ending = false
    private var observers: [NSObjectProtocol] = []

    /// What it's showing, for Checks/saver: a BarState raw value, or "" before it knows.
    @objc var shownState: String { panel.isHidden ? "" : bar.state.rawValue }
    /// How it's laid out on this screen: wide or stacked.
    @objc var shownLayout: String { panel.barLayout.rawValue }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        panel.model = bar
        panel.followsOcclusion = false
        panel.isHidden = true                   // until it knows what to say: no flash of FREE
        addSubview(panel)
        let centre = DistributedNotificationCenter.default()
        for name in ["com.apple.screensaver.willstop", "com.apple.screensaver.didstart"] {
            observers.append(centre.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let starting = note.name.rawValue == "com.apple.screensaver.didstart"
                MainActor.assumeIsolated {
                    if starting { self?.screenSaverStarted() } else { self?.screenSaverEnding() }
                }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    override func startAnimation() {
        super.startAnimation()
        begin()
    }

    override func stopAnimation() {
        super.stopAnimation()
        halt()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { halt() } else { begin() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    // drawn by the panel's layers; the black is the view's own layer
    override func draw(_ rect: NSRect) {}
    override func animateOneFrame() {}

    // MARK: - Asking the app

    private func begin() {
        guard poll == nil, !ending else { return }
        startedAt = Date()
        if panel.superview == nil { addSubview(panel) }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ask() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        poll = t
        place()
        ask()
    }

    private func halt() {
        poll?.invalidate()
        poll = nil
        panel.removeFromSuperview()             // and with it, its display link
    }

    private func ask() {
        client.ask { [weak self] status in
            MainActor.assumeIsolated { self?.heard(status) }
        }
        // burn-in: every three minutes the bar moves a few pixels
        ticks += 1
        if ticks % 180 == 0 {
            let scale = window?.backingScaleFactor ?? 2
            drift = CGSize(width: CGFloat(Int.random(in: -3...3)) / scale, height: CGFloat(Int.random(in: -3...3)) / scale)
            place()
        }
    }

    private func heard(_ status: SaverStatus?) {
        guard poll != nil else { return }
        let now = Date()
        if let status, let state = BarState(rawValue: status.state) {
            heardAt = now
            if wall != status.wall {
                wall = status.wall
                place()
            }
            bar.moment = status.moment.map { m in
                BarMoment(at: Date(timeIntervalSince1970: m.at / 1000),
                          kind: m.kind == "countUp" ? .countUp : m.kind == "fixed" ? .fixed : .countdown)
            }
            show(state)
        } else if now.timeIntervalSince(heardAt ?? startedAt) > (heardAt == nil ? 2 : 30) {
            // the app isn't answering (or is reopening after an update, which takes a second or two)
            bar.moment = nil
            show(.wandering)
        }
    }

    private func show(_ state: BarState) {
        bar.update(state)
        if panel.isHidden {
            place()
            panel.isHidden = false
        }
    }

    // MARK: - Where the bar goes

    /// The wall's layout on the wall's monitor; the wide bar everywhere else.
    private var barLayout: BarLayout {
        guard !isPreview, let wall, let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              number.uint32Value == wall.display else { return .wide }
        return BarLayout(rawValue: wall.layout) ?? .wide
    }

    /// The LEDs centred on the screen, on whole pixels.
    private func place() {
        let layout = barLayout
        let scale = max(window?.backingScaleFactor ?? 2, 1)
        let pitch = BarGeometry(size: bounds.size, scale: scale, layout: layout).pitchPixels
        let w = CGFloat(layout.cols * pitch) / scale, h = CGFloat(layout.rows * pitch) / scale
        let snap = { (v: CGFloat) -> CGFloat in (v * scale).rounded() / scale }
        panel.barLayout = layout
        panel.pitchPixels = pitch
        panel.frame = NSRect(x: snap((bounds.width - w) / 2 + drift.width), y: snap((bounds.height - h) / 2 + drift.height),
                             width: w, height: h)
    }

    // MARK: - The host's bugs

    /// The screen saver is ending: stop, and quit the host shortly, so
    /// copies of this view don't pile up running in it.
    private func screenSaverEnding() {
        ending = true
        halt()
        guard !isPreview else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                if self?.ending ?? false { exit(0) }
            }
        }
    }

    /// It started again before the host quit.
    private func screenSaverStarted() {
        guard ending else { return }
        ending = false
        if window != nil { begin() }
    }
}
