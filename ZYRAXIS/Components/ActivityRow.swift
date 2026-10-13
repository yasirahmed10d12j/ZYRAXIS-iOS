import SwiftUI

/// Single activity-feed row under the core.
public struct ActivityRow: View {

    public var activity: AssistantActivity

    public init(activity: AssistantActivity) {
        self.activity = activity
    }

    private var icon: String {
        switch activity.kind {
        case .listening: return "mic"
        case .thinking: return "brain.head.profile"
        case .speaking: return "speaker.wave.2"
        case .tool: return "wrench.and.screwdriver"
        case .vision: return "eye"
        case .system: return "info.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        activity.kind == .error ? ZyraxisTheme.warning : ZyraxisTheme.cyan
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(ZyraxisTheme.tech(11))
                    .foregroundStyle(.white.opacity(0.9))
                if let detail = activity.detail {
                    Text(detail)
                        .font(ZyraxisTheme.caption())
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(activity.timestamp, style: .time)
                .font(ZyraxisTheme.tech(10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.vertical, 4)
    }
}
