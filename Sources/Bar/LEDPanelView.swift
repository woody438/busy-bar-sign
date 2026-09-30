import AppKit
import QuartzCore
import SwiftUI

/// What the bar is showing, and since when. `since` is on the same clock as
/// CACurrentMediaTime(), which is what the panel renders against.
final class BarModel: ObservableObject {
    @Published private(set) var state: BarState = .free
    private(set) var prev: BarState?
    private(set) var since: CFTimeInterval = CACurrentMediaTime()
    /// When Do Not Disturb ends, for its countdown.
    var dndUntil: Date?
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

    func makeNSView(context: Context) -> LEDPanelNSView {
        let view = LEDPanelNSView(frame: .zero)
        view.model = model
        view.pitchPixels = pitchPixels
        return view
    }

    func updateNSView(_ view: LEDPanelNSView, context: Context) {
        view.model = model
        view.pitchPixels = pitchPixels
    }
}

final class LEDPanelNSView: NSView {
    var model: BarModel?
    var pitchPixels = 0 {
        didSet { if pitchPixels != oldValue { raster = nil; needsLayout = true } }
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

    /// Stop rendering while the window is hidden or its screen is away.
    @objc private func occlusionChanged() {
        link?.isPaused = !(window?.occlusionState.contains(.visible) ?? false)
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

    private func renderFrame() {
        guard let model, pitchPixels > 1 else { return }
        if raster == nil { raster = LEDRaster(pitch: pitchPixels) }
        guard let raster else { return }

        let date = Date()
        var timer: DNDTimer?
        if let until = model.dndUntil {
            let end = Calendar.current.dateComponents([.hour, .minute], from: until)
            timer = DNDTimer(left: until.timeIntervalSince(date), h: end.hour ?? 0, m: end.minute ?? 0)
        }
        BarEngine.render(into: &frameBuffer, now: CACurrentMediaTime(), state: model.state,
                         prev: model.prev, since: model.since, clock: ClockReading(date), timer: timer)
        raster.render(frameBuffer)

        let panel = image(from: UnsafeRawBufferPointer(raster.pixels), width: raster.width,
                          height: raster.height, bytesPerRow: raster.bytesPerRow)
        let halo = raster.glow(frameBuffer).withUnsafeBytes { bytes in
            image(from: bytes, width: LEDRaster.glowWidth, height: LEDRaster.glowHeight,
                  bytesPerRow: LEDRaster.glowWidth * 4)
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
