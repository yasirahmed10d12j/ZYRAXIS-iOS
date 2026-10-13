import Foundation

/// Local mock AI used ONLY for UI development.
///
/// - Honest: every response is prefixed so it can never be mistaken for
///   a real model. Streamed chunks are canned replays, NOT model output.
/// - No network, no keys, deterministic, test-friendly.
/// - Phase 2: emits the same `AIStreamEvent` sequence shape as the backend
///   (connected → thinking → textDelta → completed) so the conversation
///   engine exercises the real streaming path.
public struct MockAIService: AIService, Sendable {

    public let provider: AIProvider = .mock
    private let delayNanoseconds: UInt64

    public init(delayNanoseconds: UInt64 = 600_000_000) {
        self.delayNanoseconds = delayNanoseconds
    }

    public func sendMessage(_ request: AIRequest) async throws -> AIResponse {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        try Task.checkCancellation()
        return AIResponse(text: reply(for: request.text), requestId: request.id)
    }

    public func streamMessage(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let requestId = request.id
                do {
                    continuation.yield(.connected(requestId: requestId))
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                    try Task.checkCancellation()
                    continuation.yield(.thinking(requestId: requestId))
                    let full = reply(for: request.text)
                    // Canned replay in two chunks (exercises delta accumulation).
                    let mid = full.count / 2
                    let first = String(full.prefix(mid))
                    let second = String(full.dropFirst(mid))
                    continuation.yield(.textDelta(requestId: requestId, delta: first, seq: 1))
                    try await Task.sleep(nanoseconds: 150_000_000)
                    try Task.checkCancellation()
                    continuation.yield(.textDelta(requestId: requestId, delta: second, seq: 2))
                    continuation.yield(.completed(
                        requestId: requestId,
                        response: AIResponse(text: full, requestId: requestId)
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func reply(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "[MOCK] I received an empty message. Type a command to test the transcript flow."
        }
        return "[MOCK] Echoing '\(trimmed)'. Select Gemini or Groq in Settings with your API key for real AI."
    }
}
