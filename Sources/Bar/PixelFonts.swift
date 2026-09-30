import Foundation

/// One glyph of a BUSY Bar pixel font. `bits` holds rows top to bottom,
/// each pixel's intensity in 0...1 (these fonts are 1-bit, so 0 or 1).
struct PixelGlyph {
    let adv: Int      // pen advance
    let w: Int, h: Int
    let ox: Int       // pen to the left edge of the glyph box
    let oy: Int       // baseline up to the bottom of the glyph box
    let bits: [[Double]]
}

final class PixelFont {
    let lineHeight: Int
    let baseline: Int
    private let glyphs: [Character: PixelGlyph]

    init(lineHeight: Int, baseline: Int, glyphs: [Character: PixelGlyph]) {
        self.lineHeight = lineHeight
        self.baseline = baseline
        self.glyphs = glyphs
    }

    /// Falls back to the capital, then '?', as engine.js does.
    func glyph(_ ch: Character) -> PixelGlyph? {
        if let g = glyphs[ch] { return g }
        if let upper = ch.uppercased().first, let g = glyphs[upper] { return g }
        return glyphs["?"]
    }
}

/// The fonts decoded from the BUSY Status Bar firmware, loaded once from the
/// JSON in FontData.swift (the same data the simulator's fonts.js carries).
enum PixelFonts {
    private struct RawGlyph: Decodable {
        let adv: Int, w: Int, h: Int, ox: Int, oy: Int
        let rows: [String]
    }
    private struct RawFont: Decodable {
        let lineHeight: Int
        let baseline: Int
        let glyphs: [String: RawGlyph]
    }

    private static let fonts: [String: PixelFont] = {
        guard let data = busyFontsJSON.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: RawFont].self, from: data) else {
            assertionFailure("Bundled pixel fonts failed to decode")
            return [:]
        }
        var out: [String: PixelFont] = [:]
        for (name, font) in raw {
            var glyphs: [Character: PixelGlyph] = [:]
            for (key, g) in font.glyphs {
                guard key.count == 1, let ch = key.first else { continue }
                let bits = g.rows.map { row in
                    row.map { c -> Double in
                        if c == "#" { return 1 }
                        if let d = c.wholeNumberValue, d > 0 { return Double(d) / 9 }
                        return 0
                    }
                }
                glyphs[ch] = PixelGlyph(adv: g.adv, w: g.w, h: g.h, ox: g.ox, oy: g.oy, bits: bits)
            }
            out[name] = PixelFont(lineHeight: font.lineHeight, baseline: font.baseline, glyphs: glyphs)
        }
        return out
    }()

    static func font(_ name: String) -> PixelFont? { fonts[name] }
}
