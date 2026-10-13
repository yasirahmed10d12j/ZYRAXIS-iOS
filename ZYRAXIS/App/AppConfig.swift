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

    /// System prompt scaffold for future backend wiring.
    public static let systemPrompt = """
        You are ZYRAXIS, a native iOS personal AI assistant. \
        Be concise, technical, and action-oriented. \
        When a backend is connected, you may invoke tools for tasks, memory, and device actions.
        """
}
