import AppKit
import Combine
import IOSurface
import QuartzCore
import SwiftUI

/// What the bar is showing, and since when. `since` is on the same clock as
/// CACurrentMediaTime(), which is what the panel renders against. (BarMoment,
/// what the right of the pill is about, is in PanelSchedule.swift.)
final class BarModel: ObservableObject {
    @Published private(set) var state: BarState = .free
    private(set) var prev: BarState?
    private(set) var since: CFTimeInterval = CACurrentMediaTime()
    /// How long the last state had been up when it gave way: the world clocks press FREE's face as it was.
    private(set) var prevFor: CFTimeInterval = 0
    /// What the right of the pill counts to, or from; nil for the clock. A
    /// change draws the panel at once, as a change of state does.
    var moment: BarMoment? {
        didSet { if moment != oldValue { objectWillChange.send() } }
    }
    /// A camera on during the call (the tally: the light in the case, or
    /// stacked, a dot), and the cue the change at `since` announces: CAMERA
    /// ON as a call starts with it on, or as it comes on or goes off mid-call.
    @Published private(set) var camera = BarCamera.off
    private var hasReading = false

    /// The first reading sets the state without a transition, so the app
    /// opens with its announcement rather than a flash from the wrong colour.
    /// `cameraOn`: a camera's on during the call (StatusModel.camera).
    func update(_ next: BarState, cameraOn: Bool = false) {
        guard hasReading else {
            hasReading = true
            state = next
            camera = BarCamera(on: cameraOn)
            return
        }
        guard next != state else {
            if camera.on != cameraOn { camera.on = cameraOn }
            return
        }
        // muting and unmuting mid-call change the bar quietly, with no announcement
        let onCall: Set<BarState> = [.call, .callMuted]
        if onCall.contains(state) && onCall.contains(next) {
            state = next
            if camera.on != cameraOn { camera.on = cameraOn }
            return
        }
        let now = CACurrentMediaTime()
        prev = state
        prevFor = now - since
        // a call that starts with the camera on says so: CAMERA ON, in place of ON A CALL
        camera = BarCamera(on: cameraOn, cue: cameraOn && onCall.contains(next) ? .cameraOn : nil)
        state = next
        since = now
    }

    /// The camera came on, or went off, mid-call: announced as a change of
    /// state is, in its own words — CAMERA ON or CAMERA OFF — with the wave.
    func cue(_ cue: BarCue, cameraOn: Bool) {
        guard hasReading, state == .call || state == .callMuted else { return }
        let now = CACurrentMediaTime()
        prev = state
        prevFor = now - since
        since = now
        camera = BarCamera(on: cameraOn, cue: cue)
    }

    /// Plays the change from `from` to `next` again, from its start: the settings' previews.
    func replay(_ next: BarState, from: BarState) {
        hasReading = true
        prev = from
        prevFor = 0
        camera.cue = nil
        state = next
        since = CACurrentMediaTime()
    }
}

/// The LED panel: the engine and rasteriser run on each display refresh while
/// something on the bar moves, and once a second (as the clock turns) while
/// nothing does; the finished pixels go to the screen in an IOSurface.
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
    /// The world clocks, while the sign says FREE: what to show at a moment, or nil for FREE as it always was.
    var world: ((Date) -> BarEngine.WorldPlan?)? = nil

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
        view.world = world
    }
}

final class LEDPanelNSView: NSView {
    var model: BarModel? {
        didSet {
            guard model !== oldValue else { return }
            // a change of state, or of its moment, draws at once
            watching = model?.objectWillChange.sink { [weak self] _ in
                MainActor.assumeIsolated { self?.drawSoon() }
            }
            drawSoon()
        }
    }
    /// The world clocks' plan at a moment (LEDPanelView.world); nil: none.
    /// Read on every frame drawn; while it gives a plan, every display frame is drawn.
    var world: ((Date) -> BarEngine.WorldPlan?)?
    /// Whether to stop drawing while the window's hidden. Off in the screen
    /// saver, whose host may not say its windows are visible.
    var followsOcclusion = true {
        didSet { occlusionChanged() }
    }
    var pitchPixels = 0 {
        didSet { if pitchPixels != oldValue { raster = nil; needsLayout = true; drawSoon() } }
    }
    /// Whether the LEDs ease down after half an hour of nothing going on.
    var rests = false {
        didSet { if rests != oldValue { drawSoon() } }
    }
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
            drawSoon()
        }
    }

    private var raster: LEDRaster? {
        didSet {
            guard raster !== oldValue else { return }
            panels = nil
            glows = nil
            frameKeys = nil
        }
    }
    private var frameBuffer = LEDFrame()
    /// The keys of the frame just worked out (LEDRaster.keys): what decides whether it's drawn.
    private var frameKeys: LEDRaster.Canvas?
    /// The buffers the panel and its glow are drawn into and shown from.
    private var panels: SurfaceChain?, glows: SurfaceChain?
    private let dots = CALayer()
    private let glow = CALayer()
    private var link: CADisplayLink?
    /// Wakes the panel for the next turn of the clock, or the next thing to move, while nothing moves.
    private var wake: Timer?
    private var drawQueued = false
    private var watching: AnyCancellable?
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
        stopClock()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let window else { return }
        let l = displayLink(target: self, selector: #selector(step(_:)))
        // Nothing here moves faster than 60 fps; don't run at 120 on a ProMotion panel.
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.isPaused = true                       // until something moves
        l.add(to: .main, forMode: .common)
        link = l
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
        occlusionChanged()
    }

    /// Whether to draw at all: not while paused, or while the window is hidden or its screen is away.
    private var showing: Bool {
        !paused && (!followsOcclusion || (window?.occlusionState.contains(.visible) ?? false))
    }

    @objc private func occlusionChanged() {
        if showing { drawSoon() } else { stopClock() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        dots.contentsScale = scale
        glow.contentsScale = scale
    }

    @objc private func step(_ link: CADisplayLink) {
        step()
    }

    /// Frames worked out so far — drawn, or found the same as what's on the
    /// screen — and when the last was: the screen saver reports them, and
    /// draws for itself where the display link doesn't run.
    private(set) var framesDrawn = 0
    private(set) var lastDrawn: CFTimeInterval = 0
    /// When the next frame is due: now while something moves, the next turn of
    /// the clock while nothing does, never while waiting for a change.
    private var nextDue: CFTimeInterval = .infinity

    /// A frame now, without waiting for the display link.
    func drawNow() { step() }

    /// Whether a frame that was due hasn't come: where the display link doesn't
    /// run (the screen saver's host can leave a second monitor's idle), the
    /// screen saver draws instead.
    func isOverdue(at time: CFTimeInterval) -> Bool { time - nextDue > 0.1 }

    /// A frame on the next turn of the run loop: a change has come in.
    private func drawSoon() {
        guard !drawQueued else { return }
        drawQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.drawQueued = false
                if self.showing { self.step() }
            }
        }
    }

    private func step() {
        schedule(after: renderFrame())
    }

    /// Draws every display frame (nil), or wakes after `delay` seconds; .infinity: on a change.
    private func schedule(after delay: Double?) {
        wake?.invalidate()
        wake = nil
        let now = CACurrentMediaTime()
        guard let delay else {
            link?.isPaused = false
            nextDue = now
            return
        }
        link?.isPaused = true
        guard delay.isFinite, window != nil, showing else {
            nextDue = .infinity
            return
        }
        nextDue = now + delay
        let t = Timer(fire: Date().addingTimeInterval(delay), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wake = nil
                if self.showing { self.step() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        wake = t
    }

    private func stopClock() {
        link?.isPaused = true
        wake?.invalidate()
        wake = nil
        nextDue = .infinity
    }

    /// Works out the frame for now and, if it isn't what's on the screen, draws
    /// it. Returns when to next: nil on the next display frame, else in seconds.
    private func renderFrame() -> Double? {
        guard let model, pitchPixels > 1 else { return .infinity }
        framesDrawn &+= 1
        lastDrawn = CACurrentMediaTime()
        if raster == nil {
            raster = LEDRaster(pitch: pitchPixels, cols: barLayout.cols, rows: barLayout.rows, bgra: true)
        }
        guard let raster else { return .infinity }

        let date = Date(), now = CACurrentMediaTime()
        let timer = model.moment?.timer(at: date), clock = ClockReading(date)
        // the world clocks only matter while FREE is up, or just giving way
        let plan = model.state == .free || model.prev == .free ? world?(date) : nil
        switch (barLayout, plan) {
        case (.wide, let p?):
            BarEngine.renderWorld(into: &frameBuffer, now: now, state: model.state, prev: model.prev, since: model.since,
                                  clock: clock, timer: timer, world: p, prevFor: model.prevFor, camera: model.camera)
        case (.stacked, let p?):
            BarEngine.renderStackedWorld(into: &frameBuffer, now: now, state: model.state, prev: model.prev, since: model.since,
                                         clock: clock, timer: timer, world: p, prevFor: model.prevFor, camera: model.camera)
        case (.wide, nil):
            BarEngine.render(into: &frameBuffer, now: now, state: model.state,
                             prev: model.prev, since: model.since, clock: clock, timer: timer, rests: rests, camera: model.camera)
        case (.stacked, nil):
            BarEngine.renderStacked(into: &frameBuffer, now: now, state: model.state,
                                    prev: model.prev, since: model.since, clock: clock, timer: timer, rests: rests,
                                    camera: model.camera)
        }
        let rest = rests ? BarEngine.restAt(now, model.state, since: model.since) : 1

        // the same LEDs as on the screen: nothing to draw
        let keys = frameKeys ?? LEDRaster.Canvas(leds: raster.leds)
        frameKeys = keys
        raster.keys(frameBuffer, dim: rest, into: keys.keys)
        if !(panels?.front?.canvas.shows(UnsafeBufferPointer(keys.keys)) ?? false) {
            guard present(raster, keys: keys, dim: rest) else { return nil }    // no buffer free: next frame
        }
        return PanelSchedule.delay(now: now, date: date, state: model.state, since: model.since, layout: barLayout,
                                   rests: rests, moment: model.moment, world: plan != nil, camera: model.camera.on)
    }

    /// Draws the frame into a buffer the window server isn't showing — only
    /// the LEDs that differ from what that buffer holds — and shows it.
    private func present(_ raster: LEDRaster, keys: LEDRaster.Canvas, dim: Double) -> Bool {
        let panels = self.panels ?? SurfaceChain(width: raster.width, height: raster.height, leds: raster.leds)
        let glows = self.glows ?? SurfaceChain(width: raster.glowWidth, height: raster.glowHeight, leds: 0)
        self.panels = panels
        self.glows = glows
        guard let buffer = panels.next() else {
            panels.forget()
            return presentCopy(raster, keys: keys, dim: dim)
        }
        guard buffer.lock() else { return false }
        raster.render(keys: UnsafeBufferPointer(keys.keys), into: buffer.canvas, base: buffer.base,
                      bytesPerRow: buffer.bytesPerRow)
        buffer.unlock()
        var halo = glows.next()
        if let h = halo, h.lock() {
            raster.glow(frameBuffer, dim: dim, into: h.base, bytesPerRow: h.bytesPerRow)
            h.unlock()
        } else {
            halo = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dots.contents = buffer.surface
        if let halo { glow.contents = halo.surface }
        CATransaction.commit()
        panels.shown(buffer)
        if let halo { glows.shown(halo) }
        return true
    }

    /// Where no IOSurface can be made: the frame copied into images, as before 2.8.8.
    private func presentCopy(_ raster: LEDRaster, keys: LEDRaster.Canvas, dim: Double) -> Bool {
        raster.render(frameBuffer, dim: dim)
        let panel = image(from: UnsafeRawBufferPointer(raster.pixels), width: raster.width,
                          height: raster.height, bytesPerRow: raster.bytesPerRow)
        let halo = raster.glow(frameBuffer, dim: dim).withUnsafeBytes { bytes in
            image(from: bytes, width: raster.glowWidth, height: raster.glowHeight, bytesPerRow: raster.glowWidth * 4)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dots.contents = panel
        glow.contents = halo
        CATransaction.commit()
        return true
    }

    /// Copies BGRA pixels into an image.
    private func image(from bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard let base = bytes.baseAddress else { return nil }
        let data = Data(bytes: base, count: bytesPerRow * height) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colourSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/*
 * The buffers a panel is drawn into, which Core Animation shows as they are:
 * IOSurfaces, so a frame isn't copied, or converted to the display's colours
 * on the CPU, on its way to the screen — the window server does that as it
 * composites, as it did for the images before. Each frame goes into a buffer
 * the window server has let go of, never the one on the screen, and each
 * buffer remembers what its LEDs show (LEDRaster.Canvas), so only the LEDs
 * that changed since it was last shown are drawn into it.
 */
private final class SurfaceChain {
    final class Buffer {
        let surface: IOSurface
        let canvas: LEDRaster.Canvas
        /// When it last went to the screen, counted in frames shown.
        var shownAt = 0

        init(surface: IOSurface, leds: Int) {
            self.surface = surface
            canvas = LEDRaster.Canvas(leds: leds)
        }

        /// Its pixels: only between lock() and unlock().
        var base: UnsafeMutableRawPointer { surface.baseAddress }
        var bytesPerRow: Int { surface.bytesPerRow }
        func lock() -> Bool { surface.lock(options: [], seed: nil) == KERN_SUCCESS }
        func unlock() { _ = surface.unlock(options: [], seed: nil) }
    }

    let width: Int, height: Int, leds: Int
    /// Three at most: one on the screen, one the window server may still be letting go of, one to draw into.
    private let most = 3
    private var buffers: [Buffer] = []
    private(set) var front: Buffer?
    private var shows = 0
    /// Tagged sRGB, as the images were: the window server converts it for the display.
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList()

    init(width: Int, height: Int, leds: Int) {
        self.width = width
        self.height = height
        self.leds = leds
    }

    /// A buffer to draw the next frame into: one the window server isn't using,
    /// else a new one, else — if it's slow to let go — the one shown longest ago.
    func next() -> Buffer? {
        if let free = buffers.first(where: { $0 !== front && !$0.surface.isInUse }) { return free }
        if buffers.count < most, let made = make() {
            buffers.append(made)
            return made
        }
        return buffers.filter { $0 !== front }.min { $0.shownAt < $1.shownAt }
    }

    /// None of them is on the screen any more.
    func forget() { front = nil }

    /// `buffer` is now the one on the screen.
    func shown(_ buffer: Buffer) {
        shows += 1
        buffer.shownAt = shows
        front = buffer
    }

    private func make() -> Buffer? {
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width, .height: height, .bytesPerElement: 4,
            .pixelFormat: UInt32(0x4247_5241)          // 'BGRA' (kCVPixelFormatType_32BGRA): shown without converting
        ]
        guard let surface = IOSurface(properties: properties) else { return nil }
        if let sRGB { surface.setAttachment(sRGB, forKey: "IOSurfaceColorSpace") }
        return Buffer(surface: surface, leds: leds)
    }
}
