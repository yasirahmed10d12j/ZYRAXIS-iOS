import SwiftUI

/// Scrollable conversation transcript — technical log aesthetic,
/// not a generic chatbot bubble list.
public struct ConversationTranscriptView: View {

    public var messages: [ConversationMessage]

    public init(messages: [ConversationMessage]) {
        self.messages = messages
    }

    public var body: some View {
        if messages.isEmpty {
            VStack(spacing: 8) {
                Text("// TRANSCRIPT EMPTY")
                    .font(ZyraxisTheme.tech(11))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(2)
                Text("Issue a command below to begin a session.")
                    .font(ZyraxisTheme.caption())
                    .foregroundStyle(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(messages) { msg in
                            MessageRow(message: msg)
                                .id(msg.id)
                                .equatable()
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

private struct MessageRow: View, Equatable {

    var message: ConversationMessage

    // Only the changed row re-renders while streaming: without this every
    // keystroke rebuilds the whole transcript list (the lag on long chats).
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
    }

    private var accent: Color {
        switch message.role {
        case .user: return ZyraxisTheme.blue
        case .assistant: return ZyraxisTheme.cyan
        case .system: return .gray
        case .tool: return .purple
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
                .cornerRadius(2)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(message.role.rawValue.uppercased())
                        .font(ZyraxisTheme.tech(10))
                        .foregroundStyle(accent)
                        .tracking(1)
                    Spacer()
                    Text(message.timestamp, style: .time)
                        .font(ZyraxisTheme.tech(10))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Text(message.text)
                    .font(ZyraxisTheme.body())
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                if message.isStreaming {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(ZyraxisTheme.cyan)
                        .scaleEffect(0.7)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

#Preview {
    ZStack {
        ZyraxisTheme.baseBlack.ignoresSafeArea()
        ConversationTranscriptView(messages: [
            ConversationMessage(role: .user, text: "Run system diagnostic"),
            ConversationMessage(role: .assistant, text: "[MOCK] Echoing 'Run system diagnostic'. Backend AI is not connected yet.")
        ])
        .padding()
    }
}
