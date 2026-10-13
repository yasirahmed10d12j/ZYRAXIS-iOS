import SwiftUI

/// Connection status pill for the top bar.
public struct ConnectionBadge: View {

    public var connectionState: ConnectionState
    public var backendConfigured: Bool

    public init(connectionState: ConnectionState, backendConfigured: Bool) {
        self.connectionState = connectionState
        self.backendConfigured = backendConfigured
    }

    private var dot: Color {
        if !backendConfigured { return .gray }
        switch connectionState {
        case .connected: return ZyraxisTheme.success
        case .connecting, .reconnecting: return ZyraxisTheme.cyan
        case .disconnected, .suspended: return .gray
        case .failed: return ZyraxisTheme.warning
        }
    }

    private var label: String {
        if !backendConfigured { return "NO BACKEND" }
        return connectionState.displayLabel
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(label)
                .font(ZyraxisTheme.tech(10))
                .foregroundStyle(.white.opacity(0.85))
                .tracking(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

#Preview {
    ZStack {
        ZyraxisTheme.baseBlack.ignoresSafeArea()
        VStack(spacing: 12) {
            ConnectionBadge(connectionState: .connected, backendConfigured: true)
            ConnectionBadge(connectionState: .disconnected, backendConfigured: false)
            ConnectionBadge(connectionState: .reconnecting(attempt: 2), backendConfigured: true)
        }
    }
}
