import SwiftUI

/*
 * The wall display: a black screen with the bar across its middle, full
 * width, drawn as the BUSY Bar's black edition — glossy face in a thin metal
 * rim, controls along the top. Geometry matches simulator/index.html.
 *
 * Everything is measured in "4K pixels" (the simulator's units) and scaled
 * so that one LED is a whole number of device pixels: 118 LEDs plus a
 * one-LED rim either side span the screen, which on a 3840-wide display is
 * exactly 32 pixels per LED.
 */
/// Where the bar is shown: filling a screen, or as a floating window that
/// is just the device.
enum BarStyle { case wall, floating }

struct BarDisplayView: View {
    @ObservedObject var detector: CallDetector
    let style: BarStyle
    @StateObject private var bar = BarModel()
    @Environment(\.displayScale) private var displayScale

    init(detector: CallDetector, style: BarStyle = .wall) {
        _detector = ObservedObject(wrappedValue: detector)
        self.style = style
    }

    /// Burn-in protection: every few minutes the whole bar moves a few
    /// device pixels. Whole pixels, so the dots stay sharp.
    @State private var drift = CGSize.zero
    private let driftTimer = Timer.publish(every: 180, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let g = BarGeometry(size: geo.size, scale: displayScale)
            ZStack(alignment: .topLeading) {
                if style == .wall {
                    Color.black
                    Spill(state: bar.state, g: g)
                } else {
                    Color.clear
                }
                DeviceBody(g: g, castsShadow: style == .wall)
                LEDPanelView(model: bar, pitchPixels: g.pitchPixels)
                    .frame(width: g.field.width, height: g.field.height)
                    .offset(x: g.field.minX, y: g.field.minY)
            }
            .offset(style == .wall ? drift : .zero)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(style == .wall ? Color.black : Color.clear)
        .ignoresSafeArea()
        .onAppear { bar.update(onCall: detector.isOnCall) }
        .onChange(of: detector.isOnCall) { _, onCall in bar.update(onCall: onCall) }
        .onReceive(driftTimer) { _ in
            let px = { CGFloat(Int.random(in: -3...3)) / max(displayScale, 1) }
            drift = CGSize(width: px(), height: px())
        }
    }
}

/// The glow the bar throws onto the wall around it, in the state's colour.
private struct Spill: View {
    let state: BarState
    let g: BarGeometry

    var body: some View {
        let r = g.rect(384, -125, 3072, 874)
        Ellipse()
            .fill(state == .call ? Color(red: 1, green: 0.114, blue: 0.208)
                                 : Color(red: 0.090, green: 0.922, blue: 0.475))
            .frame(width: r.width, height: r.height)
            .blur(radius: 100 * g.u)
            .opacity(0.12)
            .offset(x: r.minX, y: r.minY)
            .animation(.easeInOut(duration: 0.6), value: state)
    }
}

/// The BUSY Bar's black edition, after the bezel art in its firmware.
private struct DeviceBody: View {
    let g: BarGeometry
    /// Off in a floating window, which casts its own shadow.
    let castsShadow: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            // controls along the top, behind the case
            part(330, -40, 360, 46) { knob }
            part(1330, -22, 1180, 28) {
                Rectangle().fill(LinearGradient(colors: [grey(0x141516), grey(0x0B0B0C)], startPoint: .top, endPoint: .bottom))
            }
            part(1290, -40, 1260, 26) {
                RoundedRectangle(cornerRadius: 8 * g.u)
                    .fill(LinearGradient(colors: [grey(0x3B3E42), grey(0x26282B), grey(0x1C1D20)],
                                         startPoint: .top, endPoint: .bottom))
            }
            part(3050, -18, 70, 24) {
                UnevenRoundedRectangle(topLeadingRadius: 6 * g.u, topTrailingRadius: 6 * g.u)
                    .fill(LinearGradient(colors: [grey(0x1B1C1E), grey(0x2E3033), grey(0x18191B)],
                                         startPoint: .leading, endPoint: .trailing))
            }
            part(3150, -40, 360, 46) { knurledKnob }

            // the case: a thin metal rim around a glossy black face
            part(0, 0, 3840, 624) {
                RoundedRectangle(cornerRadius: 96 * g.u)
                    .fill(LinearGradient(stops: [
                        .init(color: grey(0x5B5F63), location: 0),
                        .init(color: grey(0x34373A), location: 0.06),
                        .init(color: grey(0x222427), location: 0.5),
                        .init(color: grey(0x17181A), location: 0.94),
                        .init(color: grey(0x3A3D40), location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(castsShadow ? 0.65 : 0), radius: 40 * g.u, y: 30 * g.u)
            }
            part(10, 10, 3820, 604) {
                RoundedRectangle(cornerRadius: 86 * g.u)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 86 * g.u)
                            .fill(LinearGradient(stops: [
                                .init(color: .white.opacity(0.07), location: 0),
                                .init(color: .white.opacity(0), location: 0.32),
                                .init(color: .white.opacity(0), location: 0.8),
                                .init(color: .white.opacity(0.025), location: 1)
                            ], startPoint: .top, endPoint: .bottom))
                    )
            }
            // the light-sensor notch at top centre
            part(1830, 10, 180, 18) {
                UnevenRoundedRectangle(bottomLeadingRadius: 10 * g.u, bottomTrailingRadius: 10 * g.u)
                    .fill(grey(0x0D0D0E))
            }
        }
    }

    private func part<Content: View>(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        let r = g.rect(x, y, w, h)
        return content().frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
    }

    private var knob: some View {
        UnevenRoundedRectangle(topLeadingRadius: 14 * g.u, topTrailingRadius: 14 * g.u)
            .fill(LinearGradient(stops: [
                .init(color: grey(0x141517), location: 0),
                .init(color: grey(0x34373B), location: 0.24),
                .init(color: grey(0x26282B), location: 0.46),
                .init(color: grey(0x161719), location: 0.78),
                .init(color: grey(0x0F1011), location: 1)
            ], startPoint: .leading, endPoint: .trailing))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 14 * g.u, topTrailingRadius: 14 * g.u)
                    .fill(LinearGradient(colors: [grey(0x2A2C2F), grey(0x4A4D51), grey(0x2C2E31), grey(0x1C1D1F)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 7 * g.u)
            }
    }

    private var knurledKnob: some View {
        knob.overlay {
            HStack(spacing: 5 * g.u) {
                ForEach(0..<26, id: \.self) { _ in
                    Rectangle().fill(grey(0x2F3135).opacity(0.8)).frame(width: 9 * g.u)
                }
            }
            .padding(.top, 7 * g.u)
            .clipped()
        }
    }

    private func grey(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
