import SwiftUI

/// Glass-like container used across the ZYRAXIS UI.
public struct GlassPanel<Content: View>: View {

    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(14)
            .background(.ultraThinMaterial.opacity(0.55))
            .background(ZyraxisTheme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(ZyraxisTheme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
    }
}

#Preview {
    ZStack {
        ZyraxisTheme.baseBlack.ignoresSafeArea()
        GlassPanel {
            Text("ZYRAXIS // GLASS PANEL")
                .font(ZyraxisTheme.tech(12))
                .foregroundStyle(.cyan)
        }
        .padding()
    }
}
