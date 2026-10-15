import SwiftUI

/// Animated central ZYRAXIS core. Reacts to `AssistantState` + mic level.
///
/// Lightweight by design (stroked circles + rotation, no heavy blurs) so it
/// runs at 60fps on iPhone 11 Pro Max.
public struct ZyraxisCoreView: View {

    public var state: AssistantState
    public var micLevel: Float // 0...1 from VoiceManager
    /// Reduce Motion: static frame, no rotation/pulse (battery + older GPUs).
    public var reduceMotion: Bool

    @State private var rotation: Double = 0
    @State private var pulse: CGFloat = 1.0

    public init(state: AssistantState, micLevel: Float = 0, reduceMotion: Bool = false) {
        self.state = state
        self.micLevel = micLevel
        self.reduceMotion = reduceMotion
    }

    private var glow: Color { ZyraxisTheme.glow(for: state) }

    public var body: some View {
        ZStack {
            // Outer halo driven by mic level / activity.
            Circle()
                .stroke(glow.opacity(0.25 + Double(micLevel) * 0.5), lineWidth: 2)
                .frame(width: coreSize + 56 + CGFloat(micLevel) * 30,
                       height: coreSize + 56 + CGFloat(micLevel) * 30)
                .blur(radius: 6)

            // Rotating dashed rings.
            ForEach(0..<3) { i in
                Circle()
                    .trim(from: 0.08, to: 0.92)
                    .stroke(
                        LinearGradient(colors: [glow.opacity(0.9), glow.opacity(0.15)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: i == 1 ? 3 : 1.5, dash: [10, 7])
                    )
                    .frame(width: coreSize + CGFloat(i * 22), height: coreSize + CGFloat(i * 22))
                    .rotationEffect(.degrees(rotation * (i % 2 == 0 ? 1 : -1) + Double(i * 40)))
                    .opacity(state.isActive ? 1 : 0.55)
            }

            // Solid inner core.
            Circle()
                .fill(
                    RadialGradient(colors: [glow, ZyraxisTheme.charcoal],
                                   center: .center, startRadius: 8, endRadius: coreSize / 2)
                )
                .frame(width: coreSize, height: coreSize)
                .scaleEffect(pulse)
                .shadow(color: glow.opacity(0.6), radius: 24)

            VStack(spacing: 2) {
                Text("ZYRAXIS")
                    .font(ZyraxisTheme.tech(17))
                    .foregroundStyle(.white)
                    .tracking(4)
                Text(state.rawValue)
                    .font(ZyraxisTheme.tech(10))
                    .foregroundStyle(glow)
                    .tracking(2)
            }
        }
        .frame(width: 260, height: 260)
        // Flattened to one GPU layer: gradients + blur + shadow re-render
        // every mic-level tick, and compositing them separately each frame
        // is what drops frames on older GPUs.
        .drawingGroup()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: state.isActive ? 1.1 : 2.4).repeatForever(autoreverses: true)) {
                pulse = state.isActive ? 1.06 : 1.0
            }
        }
        .onChange(of: state) { _, new in
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: new.isActive ? 1.1 : 2.4).repeatForever(autoreverses: true)) {
                pulse = new.isActive ? 1.06 : 1.0
            }
        }
        .accessibilityLabel("ZYRAXIS core, state \(state.rawValue)")
    }

    private var coreSize: CGFloat { 128 }
}

#Preview {
    ZStack {
        ZyraxisTheme.baseBlack.ignoresSafeArea()
        VStack(spacing: 20) {
            ZyraxisCoreView(state: .processing, micLevel: 0.4)
            ZyraxisCoreView(state: .idle)
        }
    }
}
