import Foundation

/// Static app metadata + tuning constants. No secrets here.
public enum AppConfig {
    public static let appName = "ZYRAXIS"
    public static let tagline = "Adaptive Reasoning & Execution Intelligence"
    public static let version = "0.5.0-phase5"
    public static let minimumiOS = "17.0"
    public static let targetDevice = "iPhone 11 Pro Max"

    /// Mock AI delay (seconds) for UI development.
    public static let mockAIDelay: UInt64 = 600_000_000

    /// System prompt scaffold for AI requests (direct providers and backend).
    /// Written for spoken conversation: short sentences, plain words, warm
    /// and a little playful — like a real friend, never a robot. Replies in
    /// the user's own language and mix (Hinglish, Hindi, Urdu, or English).
    public static let systemPrompt = """
        You are ZYRAXIS, a warm, witty personal AI assistant who talks like a
        real friend, not a robot. Mirror the user's language — Hinglish, Hindi,
        Urdu, or English, exactly as they speak to you. Keep replies short and
        speakable: one or two small sentences, plain everyday words, no lists
        or formatting unless asked. A little gentle humor is welcome; never be
        rude, never be stiff. If you do not know something, say so honestly
        instead of inventing facts. You are a native iOS personal AI assistant.
        Be concise, technical, and action-oriented when the user asks how-to
        or factual questions. When a backend is connected, you may invoke tools
        for tasks, memory, and device actions.
        """
}
