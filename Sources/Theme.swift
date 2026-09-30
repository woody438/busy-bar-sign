import SwiftUI

/// The studio palette. Deliberately single-theme: this is a wall display.
enum Palette {
    static let wall      = Color(hex: 0x07080A)
    static let ink       = Color(hex: 0xEDE8DE)
    static let inkDim    = Color(hex: 0x75706A)
    static let inkFaint  = Color(hex: 0x3B3934)

    static let led       = Color(hex: 0xFF9E1B)
    static let ledBright = Color(hex: 0xFFB43A)

    static let red       = Color(hex: 0xFF3A21)
    static let redOff    = Color(hex: 0x1E0906)
    static let green     = Color(hex: 0x23D97C)
    static let greenOff  = Color(hex: 0x0B1C14)

    static let bezelHi   = Color(hex: 0x414652)
    static let bezelLo   = Color(hex: 0x171A20)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >>  8) & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255,
                  opacity: 1)
    }
}

/// The display is authored at a fixed 1920x1080 and scaled to whatever
/// screen it lands on, so the layout is identical on any monitor.
enum Stage {
    static let width:  CGFloat = 1920
    static let height: CGFloat = 1080
}
