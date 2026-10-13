import SwiftUI

/// Microphone button reflecting voice + assistant state. Never claims
/// transcription — it only controls capture.
public struct MicButton: View {

    public var assistantState: AssistantState
    public var voiceState: VoiceState
    public var action: () -> Void

    public init(
        assistantState: AssistantState,
        voiceState: VoiceState,
        action: @escaping () -> Void
    ) {
        self.assistantState = assistantState
        self.voiceState = voiceState
        self.action = action
    }

    private var isLive: Bool {
        assistantState == .listening || assistantState == .userSpeaking || voiceState.isCapturing
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isLive ? ZyraxisTheme.cyan : ZyraxisTheme.charcoal)
                    .frame(width: 72, height: 72)
                    .shadow(color: (isLive ? ZyraxisTheme.cyan : .clear).opacity(0.5), radius: 18)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                Image(systemName: isLive ? "mic.fill" : "mic")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(isLive ? .black : .white)
            }
        }
        .accessibilityLabel(isLive ? "Stop listening" : "Start listening")
    }
}

#Preview {
    ZStack {
        ZyraxisTheme.baseBlack.ignoresSafeArea()
        HStack(spacing: 24) {
            MicButton(assistantState: .idle, voiceState: .ready) {}
            MicButton(assistantState: .listening, voiceState: .listening(level: 0.5)) {}
        }
    }
}
