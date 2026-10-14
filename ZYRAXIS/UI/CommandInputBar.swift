import SwiftUI

/// Command input bar: technical console aesthetic with send action.
/// When `isBusy` and `onCancel` is set, a Stop button replaces Send so the
/// user can cancel the in-flight AI request.
public struct CommandInputBar: View {

    @Binding public var text: String
    public var isBusy: Bool
    public var onSend: () -> Void
    public var onCancel: (() -> Void)?

    public init(text: Binding<String>, isBusy: Bool, onSend: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        self._text = text
        self.isBusy = isBusy
        self.onSend = onSend
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(">")
                .font(ZyraxisTheme.tech(16))
                .foregroundStyle(ZyraxisTheme.cyan)
            TextField("Issue command...", text: $text)
                .font(ZyraxisTheme.body())
                .foregroundStyle(.white)
                .tint(ZyraxisTheme.cyan)
                .submitLabel(.send)
                .onSubmit { if !isBusy { onSend() } }
                .disabled(isBusy)
            if isBusy {
                if let onCancel {
                    Button(action: onCancel) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(ZyraxisTheme.warning)
                    }
                    .accessibilityLabel("Stop request")
                } else {
                    ProgressView()
                        .tint(ZyraxisTheme.cyan)
                }
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : ZyraxisTheme.cyan)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}
