import Foundation

/*
 * Turns an engine frame into the pixels of a lit LED panel: rounded
 * emitters, dark gaps, per-dot shading, the firmware's LED gamma, and a
 * glossy face. Port of simulator/painter.js.
 *
 * Pure Swift plus Dispatch, no Apple UI frameworks, so it builds and runs
 * anywhere — which is how it's checked against the simulator. The faint
 * glow is left to the GPU (see `glow`), since it's a blur and cheap there.
 *
 * Speed: a rendered LED depends only on its colour and its row (the glass
 * varies down the panel), and most LEDs in a row share a colour — the
 * pill's gradient, white type, black background. So each distinct tile is
 * drawn once per row and copied everywhere else it's needed, and the 16
 * rows render in parallel, each with its own cache and its own band of
 * pixels.
 *
 * It draws into its own `pixels`, or into a `Canvas`: a buffer the caller
 * owns (the panel's IOSurfaces), which remembers what each of its LEDs
 * shows so that drawing into it again redraws only the LEDs that differ.
 */
final class LEDRaster {
    /// Follows Flipper's own LED preview shader: rounded squares at 85% of
    /// the pitch, corner radius 0.30 of the pitch, each dot shading to 85%
    /// at its corners, unlit LEDs all but invisible on the black face.
    struct Look {
        var ledFill = 0.85          // LED width as a fraction of pitch; the rest is gap
        var ledRadius = 0.353       // corner radius as a fraction of the LED (0.30 of the pitch)
        var unlit = SIMD3<Double>(0.018, 0.018, 0.02)
        var gamma = 1.25            // the firmware drives LEDs at value^2.6-2.8; a monitor at 2.2
        var bloomFrom = 0.35        // only LEDs brighter than this give off glow
        var glassTop = 0.05         // white reflection at the top edge
        var glassBottom = 0.12      // shade at the bottom edge
    }

    let pitch: Int
    /// LEDs across and down: the wide bar's 118 x 16, or the stacked layout's.
    let cols: Int, rows: Int
    let width: Int
    let height: Int
    let glowWidth: Int, glowHeight: Int
    let look: Look
    /// Bytes in B, G, R, A order rather than R, G, B, A: what an IOSurface the
    /// screen shows as it is wants.
    let bgra: Bool

    /// RGBA8 (BGRA8 with `bgra`), row-major, alpha always 255. Valid until the next `render`.
    let pixels: UnsafeMutableRawBufferPointer
    var bytesPerRow: Int { width * 4 }

    private let mask: [Float]            // pitch x pitch: dot coverage times shading
    private let glassAlpha: [Float]      // per pixel row
    private let glassAdd: [Float]        // per pixel row: white reflection, premultiplied

    private struct TileKey: Hashable { let rgb: UInt64 }
    private final class RowCache {
        var tiles: [TileKey: [UInt8]] = [:]
    }
    private let caches: [RowCache]

    /// A buffer of pixels the size of the panel, and what each of its LEDs
    /// shows: an LED that hasn't changed since it was last drawn into this
    /// buffer isn't written again. One for each buffer drawn into.
    final class Canvas {
        /// Each LED's key (its colour on the screen, 16 bits a channel), row by row; .max: not drawn yet.
        let keys: UnsafeMutableBufferPointer<UInt64>
        init(leds: Int) {
            keys = .allocate(capacity: leds)
            keys.initialize(repeating: .max)
        }
        deinit { keys.deallocate() }
        /// Whether it shows exactly these keys.
        func shows(_ wanted: UnsafeBufferPointer<UInt64>) -> Bool {
            guard wanted.count == keys.count, let a = wanted.baseAddress, let b = keys.baseAddress else { return false }
            return memcmp(a, b, keys.count * MemoryLayout<UInt64>.stride) == 0
        }
    }
    /// What `pixels` shows.
    private let own: Canvas
    /// The keys of the frame being drawn by `render(_:dim:)`.
    private let ownKeys: UnsafeMutableBufferPointer<UInt64>
    /// The glow's sums, kept between frames rather than made each time.
    private var glowSum: [SIMD3<Double>], glowCount: [Double]

    init(pitch: Int, cols: Int = LEDFrame.cols, rows: Int = LEDFrame.rows, look: Look = Look(), bgra: Bool = false) {
        let p = max(2, pitch)
        self.pitch = p
        self.cols = cols
        self.rows = rows
        self.look = look
        self.bgra = bgra
        self.width = cols * p
        self.height = rows * p
        self.glowWidth = (cols + 1) / 2
        self.glowHeight = (rows + 1) / 2
        self.pixels = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 16)
        self.pixels.initializeMemory(as: UInt8.self, repeating: 0)
        self.mask = LEDRaster.makeMask(pitch: p, look: look)
        self.caches = (0..<rows).map { _ in RowCache() }
        self.own = Canvas(leds: cols * rows)
        self.ownKeys = .allocate(capacity: cols * rows)
        self.ownKeys.initialize(repeating: .max)
        self.glowSum = [SIMD3<Double>](repeating: .zero, count: glowWidth * glowHeight)
        self.glowCount = [Double](repeating: 0, count: glowWidth * glowHeight)
        self.drawnPerRow = .allocate(capacity: rows)
        self.drawnPerRow.initialize(repeating: 0)

        // The glass: a faint reflection across the top, shading toward the bottom.
        var alpha = [Float](repeating: 0, count: height)
        var add = [Float](repeating: 0, count: height)
        for y in 0..<height {
            let t = (Double(y) + 0.5) / Double(height)
            if t <= 0.38 {
                let a = look.glassTop * (1 - t / 0.38)
                alpha[y] = Float(a); add[y] = Float(a)          // white, alpha a
            } else {
                alpha[y] = Float(look.glassBottom * (t - 0.38) / 0.62); add[y] = 0   // black
            }
        }
        self.glassAlpha = alpha
        self.glassAdd = add
    }

    deinit {
        pixels.deallocate()
        ownKeys.deallocate()
        drawnPerRow.deallocate()
    }

    /// LEDs in the panel: the length of a frame's keys.
    var leds: Int { cols * rows }

    /// One LED's worth of mask. Coverage comes from the rounded square's
    /// signed distance, anti-aliased over a pixel; shading is flat to 30% of
    /// the cell then falls to 85% by 70%, as Flipper's shader does.
    private static func makeMask(pitch p: Int, look: Look) -> [Float] {
        let size = Double(p)
        let led = size * look.ledFill
        let r = led * look.ledRadius
        let half = led / 2
        var m = [Float](repeating: 0, count: p * p)
        for y in 0..<p {
            for x in 0..<p {
                let px = Double(x) + 0.5 - size / 2, py = Double(y) + 0.5 - size / 2
                let qx = abs(px) - (half - r), qy = abs(py) - (half - r)
                let ox = max(qx, 0), oy = max(qy, 0)
                let d = (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r
                let cover = min(max(0.5 - d, 0), 1)
                let dist = (px * px + py * py).squareRoot() / size
                let shade = dist <= 0.3 ? 1 : max(0.85, 1 - 0.15 * (dist - 0.3) / 0.4)
                m[y * p + x] = Float(cover * shade)
            }
        }
        return m
    }

    /// The colour an LED shows on the monitor: gamma, dimming, and the
    /// barely-there floor of an unlit LED.
    @inline(__always) private func ledColour(_ c: SIMD3<Double>, dim: Double) -> SIMD3<Double> {
        let g = SIMD3<Double>(pow(max(c.x * dim, 0), look.gamma),
                              pow(max(c.y * dim, 0), look.gamma),
                              pow(max(c.z * dim, 0), look.gamma))
        return look.unlit + g * (1 - look.unlit)
    }

    @inline(__always) private static func quantise(_ c: SIMD3<Double>) -> UInt64 {
        let q = { (v: Double) -> UInt64 in UInt64(min(65535, max(0, (v * 65535).rounded()))) }
        return q(c.x) << 32 | q(c.y) << 16 | q(c.z)
    }

    /// The colour a key stands for: what its LED is drawn from.
    @inline(__always) private static func colour(_ key: UInt64) -> SIMD3<Double> {
        SIMD3<Double>(Double(key >> 32 & 0xFFFF), Double(key >> 16 & 0xFFFF), Double(key & 0xFFFF)) / 65535
    }

    /// Draws one LED's p x p pixels into `out`, `stride` bytes per row.
    @inline(__always)
    private func drawTile(_ c: SIMD3<Double>, row ly: Int, into out: UnsafeMutablePointer<UInt8>, stride: Int) {
        let p = pitch
        let cg = Float(c.y)
        let (c0, c2) = bgra ? (Float(c.z), Float(c.x)) : (Float(c.x), Float(c.z))
        mask.withUnsafeBufferPointer { m in
            for py in 0..<p {
                let y = ly * p + py
                let keep = 1 - glassAlpha[y], add = glassAdd[y]
                let line = out + py * stride
                for px in 0..<p {
                    let k = m[py * p + px] * keep
                    let o = px * 4
                    line[o] = UInt8(min(255, max(0, (c0 * k + add) * 255 + 0.5)))
                    line[o + 1] = UInt8(min(255, max(0, (cg * k + add) * 255 + 0.5)))
                    line[o + 2] = UInt8(min(255, max(0, (c2 * k + add) * 255 + 0.5)))
                    line[o + 3] = 255
                }
            }
        }
    }

    private func makeTile(_ c: SIMD3<Double>, row ly: Int) -> [UInt8] {
        var t = [UInt8](repeating: 255, count: pitch * pitch * 4)
        t.withUnsafeMutableBufferPointer { drawTile(c, row: ly, into: $0.baseAddress!, stride: pitch * 4) }
        return t
    }

    /// Tiles kept per row: about 24 MB in all, whatever the size.
    private var maxTilesPerRow: Int { max(16, 24_000_000 / rows / (pitch * pitch * 4)) }
    /// New tiles cached per row per frame. When nearly every LED changes (the
    /// shockwave), the rest are drawn straight in rather than cached unused.
    private let newTilesPerFrame = 12
    /// How many LEDs each row's worker drew in the last `render`.
    private let drawnPerRow: UnsafeMutableBufferPointer<Int>

    /// Draws `frame` into `pixels`: only the LEDs that changed since the last call.
    func render(_ frame: LEDFrame, dim: Double = 1) {
        guard frame.w == cols, frame.h == rows, let start = pixels.baseAddress else { return }
        keys(frame, dim: dim, into: ownKeys)
        render(keys: UnsafeBufferPointer(ownKeys), into: own, base: start, bytesPerRow: bytesPerRow)
    }

    /// Each LED's key for `frame` at `dim` — its colour on the screen, 16 bits
    /// a channel — row by row. An LED is drawn from its key alone, so two
    /// frames with the same keys look the same to the pixel.
    func keys(_ frame: LEDFrame, dim: Double = 1, into out: UnsafeMutableBufferPointer<UInt64>) {
        guard frame.w == cols, frame.h == rows, out.count >= leds else { return }
        for ly in 0..<rows {
            for lx in 0..<cols {
                out[ly * cols + lx] = LEDRaster.quantise(ledColour(frame.get(lx, ly), dim: dim))
            }
        }
    }

    /// Draws a frame, given its keys (keys(_:dim:into:)), into the buffer
    /// `canvas` stands for — at `base`, `bytesPerRow` apart: only the LEDs
    /// whose keys differ from what it shows. Returns how many LEDs it drew.
    @discardableResult
    func render(keys: UnsafeBufferPointer<UInt64>, into canvas: Canvas,
                base: UnsafeMutableRawPointer, bytesPerRow rowBytes: Int) -> Int {
        let p = pitch, tileRow = p * 4, cols = cols
        guard keys.count >= leds, canvas.keys.count >= leds, rowBytes >= width * 4 else { return 0 }
        // Shared across the row workers: each writes only its own rows, and its own LEDs' keys.
        nonisolated(unsafe) let base = base, shown = canvas.keys, wanted = keys, drawn = drawnPerRow
        DispatchQueue.concurrentPerform(iterations: rows) { ly in
            let cache = caches[ly]
            if cache.tiles.count > maxTilesPerRow { cache.tiles.removeAll(keepingCapacity: true) }
            var added = 0, n = 0
            for lx in 0..<cols {
                let i = ly * cols + lx, rgb = wanted[i]
                if shown[i] == rgb { continue }                    // already in the buffer
                shown[i] = rgb
                n += 1
                let at = base + ly * p * rowBytes + lx * tileRow
                let key = TileKey(rgb: rgb)
                let tile: [UInt8]
                if let cached = cache.tiles[key] {
                    tile = cached
                } else if added < newTilesPerFrame {
                    tile = makeTile(LEDRaster.colour(rgb), row: ly)
                    cache.tiles[key] = tile
                    added += 1
                } else {
                    drawTile(LEDRaster.colour(rgb), row: ly, into: at.assumingMemoryBound(to: UInt8.self), stride: rowBytes)
                    continue
                }
                tile.withUnsafeBytes { src in
                    guard let s = src.baseAddress else { return }
                    for py in 0..<p {
                        (at + py * rowBytes).copyMemory(from: s + py * tileRow, byteCount: tileRow)
                    }
                }
            }
            drawn[ly] = n
        }
        return drawn.reduce(0, +)
    }

    /// The light that spills into the gaps and onto the face: only the
    /// brighter LEDs, at half resolution (as the simulator's wide glow),
    /// RGBA8. The GPU scales it up smoothly and adds it over the panel.
    func glow(_ frame: LEDFrame, dim: Double = 1) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: glowWidth * glowHeight * 4)
        out.withUnsafeMutableBytes { glow(frame, dim: dim, into: $0.baseAddress!, bytesPerRow: glowWidth * 4) }
        return out
    }

    /// The glow into a buffer of glowWidth x glowHeight pixels, `bytesPerRow`
    /// apart, in the raster's byte order.
    func glow(_ frame: LEDFrame, dim: Double = 1, into out: UnsafeMutableRawPointer, bytesPerRow: Int) {
        let gw = glowWidth, gh = glowHeight
        for i in 0..<(gw * gh) { glowSum[i] = .zero; glowCount[i] = 0 }
        for y in 0..<min(rows, frame.h) {
            for x in 0..<min(cols, frame.w) {
                let c = frame.get(x, y) * dim
                let g = SIMD3<Double>(pow(max(c.x, 0), look.gamma), pow(max(c.y, 0), look.gamma),
                                      pow(max(c.z, 0), look.gamma))
                let lum = max(g.x, max(g.y, g.z))
                let k = min(1, max(0, (lum - look.bloomFrom) / (1 - look.bloomFrom)))
                let i = (y / 2) * gw + x / 2
                glowSum[i] += g * k
                glowCount[i] += 1
            }
        }
        let bytes = out.assumingMemoryBound(to: UInt8.self)
        for gy in 0..<gh {
            for gx in 0..<gw {
                let i = gy * gw + gx
                let v = glowCount[i] > 0 ? glowSum[i] / glowCount[i] : .zero
                let r = UInt8(min(255, (v.x * 255).rounded())), g = UInt8(min(255, (v.y * 255).rounded()))
                let b = UInt8(min(255, (v.z * 255).rounded()))
                let o = gy * bytesPerRow + gx * 4
                bytes[o] = bgra ? b : r
                bytes[o + 1] = g
                bytes[o + 2] = bgra ? r : b
                bytes[o + 3] = 255
            }
        }
    }
}
