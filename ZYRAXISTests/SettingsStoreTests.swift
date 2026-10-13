import XCTest
@testable import ZYRAXIS

@MainActor
final class SettingsStoreTests: XCTestCase {

    private func freshStore() -> (UserDefaults, SettingsStore) {
        let suite = "zyraxis.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, SettingsStore(defaults: defaults))
    }

    func testDefaultsAreSane() {
        let (_, s) = freshStore()
        XCTAssertEqual(s.selectedProvider, .gemini)
        XCTAssertEqual(s.requestTimeout, 30, accuracy: 0.01)
        XCTAssertTrue(s.voiceEnabled)
        XCTAssertTrue(s.notificationsEnabled)
        XCTAssertTrue(s.memoryEnabled)
        XCTAssertFalse(s.backendConfig.isConfigured)
    }

    func testBackendConfigReflectsStoredStrings() {
        let (_, s) = freshStore()
        s.backendBaseURLString = "https://api.example.com"
        s.websocketURLString = "wss://api.example.com/live"
        XCTAssertTrue(s.backendConfig.isConfigured)
        XCTAssertEqual(s.backendConfig.baseURL?.absoluteString, "https://api.example.com")
        XCTAssertEqual(s.backendConfig.websocketURL?.absoluteString, "wss://api.example.com/live")
    }

    func testInvalidURLsYieldUnconfigured() {
        let (_, s) = freshStore()
        s.backendBaseURLString = "not a url"
        XCTAssertFalse(s.backendConfig.isConfigured)
        XCTAssertNil(s.backendConfig.baseURL)
    }

    func testResetToDefaults() {
        let (_, s) = freshStore()
        s.backendBaseURLString = "https://api.example.com"
        s.voiceEnabled = false
        s.resetToDefaults()
        XCTAssertEqual(s.backendBaseURLString, "")
        XCTAssertTrue(s.voiceEnabled)
        XCTAssertEqual(s.selectedProvider, .gemini)
    }
}
