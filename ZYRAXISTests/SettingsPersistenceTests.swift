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
}
