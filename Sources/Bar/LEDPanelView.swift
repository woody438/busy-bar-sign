import AppKit
import QuartzCore
import SwiftUI

/// The moment the right of the pill is about: a countdown to it (Do Not
/// Disturb, a call's end, CALL IN), a count up from it (LATE), or just its
/// time (FREE TILL, CALL TBC once it's on).
struct BarMoment: Equatable {
    enum Kind { case countdown, countUp, fixed }
    let at: Date
    let kind: Kind

    /// The engine's timer, at `date`.
    func timer(at date: Date) -> BarTimer {
        let c = Calendar.current.dateComponents([.hour, .minute], from: at)
        let left: Double
        switch kind {
        case .countdown: left = at.timeIntervalSince(date)
        case .countUp: left = date.timeIntervalSince(at)
        case .fixed: left = 0
        }
        return BarTimer(left: left, h: c.hour ?? 0, m: c.minute ?? 0)
    }
}

/// What the bar is showing, and since when. `since` is on the same clock as
/// CACurrentMediaTime(), which is what the panel renders against.
final class BarModel: ObservableObject {
    @Published private(set) var state: BarState = .free
    private(set) var prev: BarState?
    private(set) var since: CFTimeInterval = CACurrentMediaTime()
    /// What the right of the pill counts to, or from; nil for the clock.
    var moment: BarMoment?
    private var hasReading = false

    /// The first reading sets the state without a transition, so the app
    /// opens with its announcement rather than a flash from the wrong colour.
    func update(_ next: BarState) {
        guard hasReading else {
            hasReading = true
            state = next
            return
        }
        guard next != state else { return }
        // muting and unmuting mid-call change the bar quietly, with no announcement
        let onCall: Set<BarState> = [.call, .callMuted]
        if onCall.contains(state) && onCall.contains(next) {
            state = next
            return
        }
        prev = state
        state = next
        since = CACurrentMediaTime()
    }
}

/// The LED panel: the engine and rasteriser run on every display refresh,
/// and the finished pixels go straight into a layer.
struct LEDPanelView: NSViewRepresentable {
    let model: BarModel
    /// Device pixels per LED. Whole pixels, so every dot lands on the grid.
    let pitchPixels: Int
    var layout: BarLayout = .wide
    /// Whether the LEDs ease down after half an hour of nothing going on (BarEngine.restAt): the wall's.
    var rests = false
    /// Stops drawing: the wall while it's dark out of hours.
    var paused = false
    /// Rounded corners, in points: the wide bar's, so it can move inside its case.
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> LEDPanelNSView {
        let view = LEDPanelNSView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: LEDPanelNSView, context: Context) {
        view.model = model
        view.pitchPixels = pitchPixels
        view.barLayout = layout
        view.rests = rests
        view.paused = paused
        view.cornerRadius = cornerRadius
    }
}

final class LEDPanelNSView: NSView {
    var model: BarModel?
    /// Whether to stop drawing while the window's hidden. Off in the screen
    /// saver, whose host may not say its windows are visible.
    var followsOcclusion = true {
        didSet { occlusionChanged() }
    }
    var pitchPixels = 0 {
        didSet { if pitchPixels != oldValue { raster = nil; needsLayout = true } }
    }
    /// Whether the LEDs ease down after half an hour of nothing going on.
    var rests = false
    /// Whether to stop drawing, whatever the window's doing.
    var paused = false {
        didSet { if paused != oldValue { occlusionChanged() } }
    }
    var cornerRadius: CGFloat = 0 {
        didSet { if cornerRadius != oldValue { layer?.cornerRadius = cornerRadius } }
    }
    /// (Not `layout`: that's NSView's layout pass.)
    var barLayout: BarLayout = .wide {
        didSet {
            guard barLayout != oldValue else { return }
            raster = nil
            frameBuffer = LEDFrame(w: barLayout.cols, h: barLayout.rows)
            needsLayout = true
        }
    }

    private var raster: LEDRaster?
    private var frameBuffer = LEDFrame()
    private let dots = CALayer()
    private let glow = CALayer()
    private var link: CADisplayLink?
    private let colourSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// The light spilling into the gaps: laid over the panel, very faintly.
    /// Plain blending rather than additive: where the glow is bright it's the
    /// LED's own colour, so at 7% the two look the same, and it keeps Core
    /// Image out of the layer tree.
    private let glowStrength: Float = 0.07

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-hosting: we own the layer tree outright.
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        root.isOpaque = true
        layer = root
        wantsLayer = true

        dots.contentsGravity = .resize
        dots.magnificationFilter = .nearest
        dots.minificationFilter = .nearest
        dots.isOpaque = true
        root.addSublayer(dots)

        glow.contentsGravity = .resize
        glow.magnificationFilter = .linear      // the smooth upscale is the blur
        glow.opacity = glowStrength
        root.addSublayer(glow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    // SwiftUI sizes the view by setting its frame; lay out then too, rather
    // than rely on a layout pass being scheduled.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dots.frame = bounds
        glow.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let window else { return }
        let l = displayLink(target: self, selector: #selector(step(_:)))
        // Nothing here moves faster than 60 fps; don't run at 120 on a ProMotion panel.
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
        occlusionChanged()
    }

    /// Stop rendering while paused, or while the window is hidden or its screen is away.
    @objc private func occlusionChanged() {
        link?.isPaused = paused || (followsOcclusion && !(window?.occlusionState.contains(.visible) ?? false))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        dots.contentsScale = scale
        glow.contentsScale = scale
    }

    @objc private func step(_ link: CADisplayLink) {
        renderFrame()
    }

    /// Frames drawn so far, and when the last was: the screen saver reports
    /// them, and draws for itself where the display link doesn't run.
    private(set) var framesDrawn = 0
    private(set) var lastDrawn: CFTimeInterval = 0

    /// A frame now, without waiting for the display link.
    func drawNow() { renderFrame() }

    private func renderFrame() {
        guard let model, pitchPixels > 1 else { return }
        framesDrawn &+= 1
        lastDrawn = CACurrentMediaTime()
        if raster == nil { raster = LEDRaster(pitch: pitchPixels, cols: barLayout.cols, rows: barLayout.rows) }
        guard let raster else { return }

        let date = Date(), now = CACurrentMediaTime()
        let timer = model.moment?.timer(at: date)
        switch barLayout {
        case .wide:
            BarEngine.render(into: &frameBuffer, now: now, state: model.state,
                             prev: model.prev, since: model.since, clock: ClockReading(date), timer: timer)
        case .stacked:
            BarEngine.renderStacked(into: &frameBuffer, now: now, state: model.state,
                                    prev: model.prev, since: model.since, clock: ClockReading(date), timer: timer)
        }
        let rest = rests ? BarEngine.restAt(now, model.state, since: model.since) : 1
        raster.render(frameBuffer, dim: rest)

        let panel = image(from: UnsafeRawBufferPointer(raster.pixels), width: raster.width,
                          height: raster.height, bytesPerRow: raster.bytesPerRow)
        let halo = raster.glow(frameBuffer, dim: rest).withUnsafeBytes { bytes in
            image(from: bytes, width: raster.glowWidth, height: raster.glowHeight,
                  bytesPerRow: raster.glowWidth * 4)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dots.contents = panel
        glow.contents = halo
        CATransaction.commit()
    }

    /// Copies the pixels into an image, so the rasteriser can reuse its buffer
    /// while Core Animation is still drawing the last frame.
    private func image(from bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard let base = bytes.baseAddress else { return nil }
        let data = Data(bytes: base, count: bytesPerRow * height) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colourSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

}
