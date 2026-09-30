import SwiftUI

/// The two-legend sign. Both words are always on the panel; only one is
/// powered, and the dark one stays readable as engraved acrylic.
struct SignView: View {
    let onCall: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color(hex: 0x22262E), Color(hex: 0x14171C), Color(hex: 0x1B1F26)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.6), radius: 30, y: 11)

            RoundedRectangle(cornerRadius: 6)
                .fill(RadialGradient(colors: [Color(hex: 0x101318), Color(hex: 0x08090C)],
                                     center: .init(x: 0.5, y: 0.4), startRadius: 0, endRadius: 700))
                .padding(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.045), lineWidth: 1)
                        .padding(12)
                )

            VStack(spacing: 0) {
                Spacer()
                legend("On a call", lit: onCall, on: Palette.red, off: Palette.redOff)
                Spacer()
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, Palette.ink.opacity(0.14), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                    .padding(.horizontal, 100)
                Spacer()
                legend("Free", lit: !onCall, on: Palette.green, off: Palette.greenOff)
                Spacer()
            }
            .padding(.horizontal, 52)
            .padding(.vertical, 56)

            screws
        }
    }

    private func legend(_ text: String, lit: Bool, on: Color, off: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 118, weight: .heavy, design: .default))
            .tracking(2.4)
            .foregroundStyle(lit ? on : off)
            .shadow(color: lit ? on.opacity(0.85) : .clear, radius: 18)
            .shadow(color: lit ? on.opacity(0.55) : .clear, radius: 58)
            .shadow(color: lit ? on.opacity(0.35) : .clear, radius: 110)
            .animation(.easeInOut(duration: 0.45), value: lit)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private var screws: some View {
        GeometryReader { geo in
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: 0x575D68), Color(hex: 0x2B3038), Color(hex: 0x14171C)],
                                         center: .init(x: 0.34, y: 0.30), startRadius: 0, endRadius: 9))
                    .frame(width: 15, height: 15)
                    .position(x: index % 2 == 0 ? 21 : geo.size.width - 21,
                              y: index < 2 ? 21 : geo.size.height - 21)
            }
        }
    }
}
