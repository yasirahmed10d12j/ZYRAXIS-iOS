import XCTest
@testable import ZYRAXIS

/// Proves the Phase 4 SettingsStore fix: mutations persist to the injected
/// UserDefaults instance — not unconditionally to `.standard`.
/// No backend required.
@MainActor
final class SettingsPersistenceTests: XCTestCase {

    private func suite() -> UserDefaults {
        let name = "zyraxis.persist.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testMutationsPersistToInjectedSuite() {
        let d = suite()
        let s = SettingsStore(defaults: d)
        s.backendBaseURLString = "https://persist.example.com"
        s.websocketURLString = "wss://persist.example.com/live"
        s.requestTimeout = 45
        s.environment = .staging
        s.liveTranscriptionEnabled = true
        s.voiceResponsesEnabled = true

        // A fresh instance over the same suite sees every mutation.
        let reloaded = SettingsStore(defaults: d)
        XCTAssertEqual(reloaded.backendBaseURLString, "https://persist.example.com")
        XCTAssertEqual(reloaded.websocketURLString, "wss://persist.example.com/live")
        XCTAssertEqual(reloaded.requestTimeout, 45, accuracy: 0.001)
        XCTAssertEqual(reloaded.environment, .staging)
        XCTAssertTrue(reloaded.liveTranscriptionEnabled)
        XCTAssertTrue(reloaded.voiceResponsesEnabled)
    }

    func testVoiceTogglesDefaultOff() {
        let s = SettingsStore(defaults: suite())
        XCTAssertFalse(s.voiceResponsesEnabled)
        XCTAssertFalse(s.liveTranscriptionEnabled)
    }

    func testResetRestoresVoiceDefaults() {
        let s = SettingsStore(defaults: suite())
        s.voiceResponsesEnabled = true
        s.liveTranscriptionEnabled = true
        s.resetToDefaults()
        XCTAssertFalse(s.voiceResponsesEnabled)
        XCTAssertFalse(s.liveTranscriptionEnabled)
    }

    // MARK: - backendConfig cache (Settings screen lag fix)

    /// The settings Form reads `backendConfig` several times per render; each
    /// read used to re-parse six URL strings. Caching must never return stale
    /// values, so every input that feeds it has to invalidate the cache.
    func testBackendConfigReflectsURLChanges() {
        let s = SettingsStore(defaults: suite())
        s.environment = .production
        s.backendBaseURLString = "https://first.example.com"
        s.websocketURLString = "wss://first.example.com/live"
        XCTAssertEqual(s.backendConfig.baseURL?.absoluteString, "https://first.example.com")
        XCTAssertEqual(s.backendConfig.websocketURL?.absoluteString, "wss://first.example.com/live")

        // Same instance, new values — the cached value must not survive.
        s.backendBaseURLString = "https://second.example.com"
        s.websocketURLString = "wss://second.example.com/live"
        XCTAssertEqual(s.backendConfig.baseURL?.absoluteString, "https://second.example.com")
        XCTAssertEqual(s.backendConfig.websocketURL?.absoluteString, "wss://second.example.com/live")
    }

    func testBackendConfigReflectsEnvironmentChange() {
        let s = SettingsStore(defaults: suite())
        s.backendBaseURLString = "https://prod.example.com"
        s.devBaseURLString = "http://127.0.0.1:8000"
        s.environment = .production
        XCTAssertEqual(s.backendConfig.baseURL?.absoluteString, "https://prod.example.com")

        s.environment = .development
        XCTAssertEqual(s.backendConfig.baseURL?.absoluteString, "http://127.0.0.1:8000")
    }

    func testBackendConfigReflectsTimeoutChanges() {
        let s = SettingsStore(defaults: suite())
        s.requestTimeout = 30
        XCTAssertEqual(s.backendConfig.requestTimeout, 30, accuracy: 0.001)
        s.requestTimeout = 90
        XCTAssertEqual(s.backendConfig.requestTimeout, 90, accuracy: 0.001)
    }

    func testResetInvalidatesBackendConfig() {
        let s = SettingsStore(defaults: suite())
        s.backendBaseURLString = "https://before-reset.example.com"
        _ = s.backendConfig
        s.resetToDefaults()
        XCTAssertNil(s.backendConfig.baseURL)
    }
}
