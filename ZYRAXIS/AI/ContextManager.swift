import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Lightweight context engine. Prepares the bounded snapshot every AI
/// request carries:
///
/// system context + recent conversation + relevant memory +
/// assistant state + available tools + device context.
///
/// Rules:
/// - NEVER sends unlimited history (see `ContextLimits`).
/// - Truncates oldest-first, keeping the newest turns (referent resolution
///   for follow-ups like "open that again" needs recent context).
/// - Memories tagged secret/credential/password/key are NEVER included.
/// - Memory content is length-capped per item and in total.
public struct ContextManager: Sendable {

    public var limits: ContextLimits

    public init(limits: ContextLimits = .default) {
        self.limits = limits
    }

    public func build(
        history: [ConversationMessage],
        memories: [MemoryItem],
        state: AssistantState,
        availableTools: [String] = [],
        systemPrompt: String? = nil,
        device: DeviceContext? = nil
    ) -> ConversationContext {
        let boundedMessages = boundMessages(history)
        let safeMemories = filterMemories(memories)
        return ConversationContext(
            systemPrompt: systemPrompt,
            messages: boundedMessages,
            memories: safeMemories,
            assistantState: state.rawValue,
            availableTools: availableTools,
            device: device ?? DeviceContext.current()
        )
    }

    // MARK: - Message bounding (newest wins, chronological out)

    func boundMessages(_ history: [ConversationMessage]) -> [ConversationMessage] {
        var recent = Array(history.suffix(limits.maxMessages))
        // Enforce the character budget from the oldest side.
        var total = recent.reduce(0) { $0 + $1.text.count }
        while total > limits.maxTotalChars, !recent.isEmpty {
            total -= recent[0].text.count
            recent.removeFirst()
        }
        return recent
    }

    // MARK: - Memory filtering

    /// Drops secret-tagged memories, sorts by importance, caps count + chars.
    func filterMemories(_ memories: [MemoryItem]) -> [MemoryItem] {
        let forbiddenTags: Set<String> = ["secret", "credential", "password", "api_key", "apikey", "token", "private_key"]
        let safe = memories.filter { item in
            !item.tags.contains { forbiddenTags.contains($0.lowercased()) }
        }
        let ranked = safe.sorted {
            if $0.importance != $1.importance { return $0.importance > $1.importance }
            return $0.updatedAt > $1.updatedAt
        }
        var out: [MemoryItem] = []
        var chars = 0
        for var item in ranked.prefix(limits.maxMemories) {
            if item.content.count > limits.maxMemoryChars {
                item.content = String(item.content.prefix(limits.maxMemoryChars)) + "…"
            }
            chars += item.content.count
            if chars > limits.maxTotalChars { break }
            out.append(item)
        }
        return out
    }
}

public extension DeviceContext {
    /// Non-sensitive device facts only. No identifiers, no location.
    static func current() -> DeviceContext {
        #if canImport(UIKit)
        return DeviceContext(
            deviceModel: UIDevice.current.model,
            osVersion: UIDevice.current.systemVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            locale: Locale.current.identifier
        )
        #else
        return DeviceContext(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            locale: Locale.current.identifier
        )
        #endif
    }
}
