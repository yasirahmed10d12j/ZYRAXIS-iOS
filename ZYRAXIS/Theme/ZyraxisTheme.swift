import SwiftUI

/// ZYRAXIS visual identity: dark futuristic, black/charcoal + cyan/blue glow.
///
/// Keep all color/font decisions here so views stay consistent and
/// the theme can evolve without touching feature code.
public enum ZyraxisTheme {

    // MARK: - Base

    public static let baseBlack = Color(red: 0.02, green: 0.03, blue: 0.05)      // #05070D
    public static let charcoal = Color(red: 0.04, green: 0.07, blue: 0.13)       // #0B1220
    public static let panel = Color(red: 0.07, green: 0.11, blue: 0.19).opacity(0.72)
    public static let hairline = Color.white.opacity(0.08)

    // MARK: - Illumination

    public static let cyan = Color(red: 0.13, green: 0.83, blue: 0.93)           // #22D3EE
    public static let blue = Color(red: 0.23, green: 0.51, blue: 0.96)           // #3B82F6
    public static let dimCyan = Color(red: 0.13, green: 0.83, blue: 0.93).opacity(0.35)
    public static let warning = Color(red: 1.0, green: 0.45, blue: 0.35)
    public static let success = Color(red: 0.2, green: 0.9, blue: 0.6)

    public static let coreGradient = LinearGradient(
        colors: [cyan, blue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let backgroundGradient = LinearGradient(
        colors: [baseBlack, charcoal, baseBlack],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Typography

    /// Technical/mono accent for IDs, timestamps, status.
    public static func tech(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    public static func headline() -> Font {
        .system(size: 22, weight: .semibold, design: .default)
    }

    public static func body() -> Font {
        .system(size: 15, weight: .regular, design: .default)
    }

    public static func caption() -> Font {
        .system(size: 12, weight: .regular, design: .default)
    }

    // MARK: - State colors

    public static func glow(for state: AssistantState) -> Color {
        switch state {
        case .idle: return dimCyan
        case .listening: return cyan
        case .userSpeaking: return cyan
        case .processing: return blue
        case .speaking: return cyan
        case .executing: return blue
        case .vision: return .purple
        case .error: return warning
        }
    }
}

// MARK: - Shared view styling

public struct ZyraxisPanelStyle: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial.opacity(0.6))
            .background(ZyraxisTheme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(ZyraxisTheme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

public extension View {
    func zyraxisPanel() -> some View {
        modifier(ZyraxisPanelStyle())
    }
}
