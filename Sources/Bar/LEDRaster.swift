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
    let width: Int
    let height: Int
    let look: Look

    /// RGBA8, row-major, alpha always 255. Valid until the next `render`.
    let pixels: UnsafeMutableRawBufferPointer
    var bytesPerRow: Int { width * 4 }

    private let mask: [Float]            // pitch x pitch: dot coverage times shading
    private let glassAlpha: [Float]      // per pixel row
    private let glassAdd: [Float]        // per pixel row: white reflection, premultiplied

    private struct TileKey: Hashable { let rgb: UInt64 }
    private final class RowCache { var tiles: [TileKey: [UInt8]] = [:] }
    private let caches: [RowCache]

    init(pitch: Int, look: Look = Look()) {
        let p = max(2, pitch)
        self.pitch = p
        self.look = look
        self.width = LEDFrame.cols * p
        self.height = LEDFrame.rows * p
        self.pixels = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 16)
        self.pixels.initializeMemory(as: UInt8.self, repeating: 0)
        self.mask = LEDRaster.makeMask(pitch: p, look: look)
        self.caches = (0..<LEDFrame.rows).map { _ in RowCache() }

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

    deinit { pixels.deallocate() }

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

    private func makeTile(_ c: SIMD3<Double>, row ly: Int) -> [UInt8] {
        let p = pitch
        let cr = Float(c.x), cg = Float(c.y), cb = Float(c.z)
        var t = [UInt8](repeating: 255, count: p * p * 4)
        for py in 0..<p {
            let y = ly * p + py
            let keep = 1 - glassAlpha[y], add = glassAdd[y]
            for px in 0..<p {
                let k = mask[py * p + px] * keep
                let o = (py * p + px) * 4
                t[o] = UInt8(min(255, max(0, (cr * k + add) * 255 + 0.5)))
                t[o + 1] = UInt8(min(255, max(0, (cg * k + add) * 255 + 0.5)))
                t[o + 2] = UInt8(min(255, max(0, (cb * k + add) * 255 + 0.5)))
            }
        }
        return t
    }

    func render(_ frame: LEDFrame, dim: Double = 1) {
        let p = pitch, rowBytes = width * 4, tileRow = p * 4
        guard let base = pixels.baseAddress else { return }
        DispatchQueue.concurrentPerform(iterations: LEDFrame.rows) { ly in
            let cache = caches[ly]
            if cache.tiles.count > 400 { cache.tiles.removeAll(keepingCapacity: true) }   // ~1.6 MB per row at 4K
            for lx in 0..<LEDFrame.cols {
                let c = ledColour(frame.get(lx, ly), dim: dim)
                let key = TileKey(rgb: LEDRaster.quantise(c))
                let tile: [UInt8]
                if let cached = cache.tiles[key] {
                    tile = cached
                } else {
                    tile = makeTile(c, row: ly)
                    cache.tiles[key] = tile
                }
                tile.withUnsafeBytes { src in
                    guard let s = src.baseAddress else { return }
                    for py in 0..<p {
                        (base + (ly * p + py) * rowBytes + lx * tileRow)
                            .copyMemory(from: s + py * tileRow, byteCount: tileRow)
                    }
                }
            }
        }
    }

    static let glowWidth = (LEDFrame.cols + 1) / 2     // 59
    static let glowHeight = (LEDFrame.rows + 1) / 2    // 8

    /// The light that spills into the gaps and onto the face: only the
    /// brighter LEDs, at half resolution (as the simulator's wide glow),
    /// RGBA8. The GPU scales it up smoothly and adds it over the panel.
    func glow(_ frame: LEDFrame, dim: Double = 1) -> [UInt8] {
        let gw = LEDRaster.glowWidth, gh = LEDRaster.glowHeight
        var sum = [SIMD3<Double>](repeating: .zero, count: gw * gh)
        var count = [Double](repeating: 0, count: gw * gh)
        for y in 0..<LEDFrame.rows {
            for x in 0..<LEDFrame.cols {
                let c = frame.get(x, y) * dim
                let g = SIMD3<Double>(pow(max(c.x, 0), look.gamma), pow(max(c.y, 0), look.gamma),
                                      pow(max(c.z, 0), look.gamma))
                let lum = max(g.x, max(g.y, g.z))
                let k = min(1, max(0, (lum - look.bloomFrom) / (1 - look.bloomFrom)))
                let i = (y / 2) * gw + x / 2
                sum[i] += g * k
                count[i] += 1
            }
        }
        var out = [UInt8](repeating: 255, count: gw * gh * 4)
        for i in 0..<(gw * gh) {
            let v = count[i] > 0 ? sum[i] / count[i] : .zero
            out[i * 4] = UInt8(min(255, (v.x * 255).rounded()))
            out[i * 4 + 1] = UInt8(min(255, (v.y * 255).rounded()))
            out[i * 4 + 2] = UInt8(min(255, (v.z * 255).rounded()))
        }
        return out
    }
}
