import SwiftUI

/// The whole wall display, authored at 1920x1080 and scaled to fit whatever
/// screen it's shown on.
struct DisplayView: View {
    @ObservedObject var detector: CallDetector
    @State private var drift = CGSize.zero

    private let driftTimer = Timer.publish(every: 180, on: .main, in: .common).autoconnect()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / Stage.width, geo.size.height / Stage.height)
            ZStack {
                Palette.wall.ignoresSafeArea()
                bounce
                stage
                    .frame(width: Stage.width, height: Stage.height)
                    .scaleEffect(scale)
                    .offset(drift)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Palette.wall)
        .onReceive(tick) { now = $0 }
        .onReceive(driftTimer) { _ in
            // Slow sub-pixel wander so nothing burns into the panel.
            withAnimation(.easeInOut(duration: 30)) {
                drift = CGSize(width: .random(in: -3...3), height: .random(in: -3...3))
            }
        }
    }

    private var stateColour: Color { detector.isOnCall ? Palette.red : Palette.green }

    /// The colour a real lamp would throw onto the wall behind it.
    private var bounce: some View {
        RadialGradient(colors: [stateColour.opacity(detector.isOnCall ? 0.18 : 0.13), .clear],
                       center: .init(x: 0.68, y: 0.46), startRadius: 0, endRadius: 900)
            .blur(radius: 90)
            .animation(.easeInOut(duration: 0.7), value: detector.isOnCall)
            .ignoresSafeArea()
    }

    private var stage: some View {
        VStack(spacing: 26) {
            topStrip
            HStack(spacing: 74) {
                ClockView().frame(width: 776, height: 776)
                SignView(onCall: detector.isOnCall)
            }
            .frame(maxHeight: .infinity)
            bottomStrip
        }
        .padding(EdgeInsets(top: 78, leading: 80, bottom: 72, trailing: 80))
        .background(
            LinearGradient(colors: [Color(hex: 0x0E1116), Color(hex: 0x08090C), Color(hex: 0x0B0D11)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private var topStrip: some View {
        HStack {
            Text(dateText).strip(size: 22)
            Spacer()
            HStack(spacing: 0) {
                if let city { Text("\(city)  ·  ").strip(size: 22) }
                Text(zoneAbbreviation).strip(size: 22, bright: true)
            }
        }
        .overlay(Rectangle().fill(Palette.ink.opacity(0.07)).frame(height: 1), alignment: .bottom)
        .padding(.bottom, 22)
    }

    private var bottomStrip: some View {
        HStack {
            HStack(spacing: 12) {
                Circle()
                    .fill(stateColour)
                    .frame(width: 11, height: 11)
                    .shadow(color: stateColour, radius: 7)
                Text(detector.isOnCall ? "ON A CALL" : "FREE").strip(size: 19, bright: true)
                Text(elapsedText).strip(size: 19, faint: true)
            }
            Spacer()
            Text(detector.detection.sourceLine.uppercased()).strip(size: 19)
        }
        .overlay(Rectangle().fill(Palette.ink.opacity(0.07)).frame(height: 1), alignment: .top)
        .padding(.top, 22)
    }

    // MARK: - Strings

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter.string(from: now).uppercased()
    }

    private var city: String? {
        let id = TimeZone.current.identifier
        guard let last = id.split(separator: "/").last, id.contains("/") else { return nil }
        return last.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    private var zoneAbbreviation: String {
        TimeZone.current.abbreviation() ?? TimeZone.current.identifier
    }

    private var elapsedText: String {
        let seconds = Int(now.timeIntervalSince(detector.changedAt))
        return seconds < 60 ? "  \(seconds) SEC" : "  \(seconds / 60) MIN"
    }
}

private extension Text {
    /// The data strips that run above and below the instruments.
    func strip(size: CGFloat, bright: Bool = false, faint: Bool = false) -> some View {
        self.font(.system(size: size, weight: bright ? .semibold : .medium, design: .monospaced))
            .tracking(size * 0.2)
            .foregroundStyle(faint ? Palette.inkFaint : (bright ? Palette.ink : Palette.inkDim))
    }
}
