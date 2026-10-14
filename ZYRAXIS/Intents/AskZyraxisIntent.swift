import AppIntents
import Foundation

/// "Hey Siri, ask ZYRAXIS …" — answers without opening the app.
///
/// How it works: reads the user's own provider key from Keychain (same keys
/// the main app uses), calls the provider directly over HTTPS, and returns
/// the text as a Siri dialog (spoken + shown). No custom backend involved.
///
/// Honest limits (do not overclaim):
/// - Needs a saved Gemini or Groq key (Settings → AI Backend in the app);
///   without one it returns a setup dialog instead of calling anything.
/// - Gemini is tried first when its key exists, then Groq — same free tiers
///   as the main app. Rate limits surface as a "try again" dialog.
/// - Keychain/Keychain access requires the device to be unlocked; a locked
///   device yields the setup dialog. Streaming is not supported in a dialog
///   (single final answer, 20 s cap so Siri never hangs).
/// - No tests touch the network; see `ShortcutProviderPolicy` below.
struct AskZyraxisIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask ZYRAXIS"
    static var description = IntentDescription("Ask your ZYRAXIS assistant anything using your saved provider key.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Question")
    var query: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let runner = ZyraxisShortcutRunner(keychain: SystemKeychainService())
        let answer = await runner.answer(query)
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}

/// App Shortcuts entry so Siri suggests "Ask ZYRAXIS …" with a spoken query.
struct ZyraxisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskZyraxisIntent(),
            phrases: ["Ask \(.applicationName)", "Ask ZYRAXIS"],
            shortTitle: "Ask ZYRAXIS",
            systemImageName: "message"
        )
    }
}

/// Testable shortcut logic: provider/key selection only (no network here —
/// the intent drives real provider services, covered by mocked unit tests
/// around `pickProvider` and dialog mapping).
enum ShortcutProviderPolicy {
    enum Choice: Equatable {
        case gemini
        case groq
        case none
    }

    /// Gemini first when its key exists, else Groq, else none. Pure logic.
    static func pickProvider(geminiKey: String?, groqKey: String?) -> Choice {
        if let key = geminiKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .gemini
        }
        if let key = groqKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .groq
        }
        return .none
    }

    static func setupDialog() -> String {
        "Add a Gemini or Groq API key in the ZYRAXIS app Settings, then ask again."
    }

    static func rateLimitDialog() -> String {
        "The AI provider is rate-limiting requests. Try again in a moment."
    }
}

private struct ZyraxisShortcutRunner {
    let keychain: any KeychainService

    func answer(_ query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Ask me something first — say 'Hey Siri, ask ZYRAXIS' with your question."
        }
        let geminiKey = (try? keychain.load(forKey: KeychainKeys.geminiAPIKey)) ?? nil
        let groqKey = (try? keychain.load(forKey: KeychainKeys.groqAPIKey)) ?? nil
        switch ShortcutProviderPolicy.pickProvider(geminiKey: geminiKey, groqKey: groqKey) {
        case .none:
            return ShortcutProviderPolicy.setupDialog()
        case .gemini:
            return await answerViaGemini(trimmed)
        case .groq:
            return await answerViaGroq(trimmed)
        }
    }

    private func answerViaGemini(_ text: String) async -> String {
        do {
            let service = await GeminiDirectService(keychain: keychain, timeout: 20)
            let request = AIRequest(text: text, context: ConversationContext())
            let response = try await service.sendMessage(request)
            return response.text.isEmpty ? "Gemini returned no usable text." : response.text
        } catch {
            return await fallbackToGroq(text, geminiFailedWith: error)
        }
    }

    private func answerViaGroq(_ text: String) async -> String {
        do {
            let service = await GroqDirectService(keychain: keychain, timeout: 20)
            let request = AIRequest(text: text, context: ConversationContext())
            let response = try await service.sendMessage(request)
            return response.text.isEmpty ? "Groq returned no usable text." : response.text
        } catch {
            return dialog(for: error)
        }
    }

    private func fallbackToGroq(_ text: String, geminiFailedWith error: Error) async -> String {
        let groqKey = (try? keychain.load(forKey: KeychainKeys.groqAPIKey)) ?? nil
        guard let key = groqKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return dialog(for: error)
        }
        return await answerViaGroq(text)
    }

    private func dialog(for error: Error) -> String {
        if let net = error as? NetworkError, case .server(let code, _) = net, code == 429 {
            return ShortcutProviderPolicy.rateLimitDialog()
        }
        if (error as? NetworkError) == .unauthorized {
            return ShortcutProviderPolicy.setupDialog()
        }
        if error is CancellationError {
            return "Request cancelled."
        }
        return "Sorry, that request failed. Try again in a moment."
    }
}
