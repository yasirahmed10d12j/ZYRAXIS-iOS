import XCTest
@testable import ZYRAXIS

/// Environment resolution: Development / Staging / Production URL selection
/// with production fallback. No backend required.
@MainActor
final class EnvironmentConfigTests: XCTestCase {

    private func freshStore() -> SettingsStore {
        let suite = "zyraxis.env.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // NOTE: SettingsStore persists mutations to .standard (pre-existing
        // Phase 1 behavior); reads here come from the isolated suite.
        return SettingsStore(defaults: defaults)
    }

    func testProductionIsDefault() {
        let s = freshStore()
        XCTAssertEqual(s.environment, .production)
        XCTAssertFalse(s.backendConfig.isConfigured)
    }

    func testStagingResolutionWithFallback() {
        let s = freshStore()
        s.backendBaseURLString = "https://prod.example.com"
        s.stagingBaseURLString = "https://staging.example.com"
        s.environment = .staging
        XCTAssertEqual(s.backendConfig.baseURL?.absoluteString, "https://staging.example.com")
        s.stagingBaseURLString = ""
        XCTAssertEqual(s.backendConfig.baseURL?.absoluteString, "https://prod.example.com")
    }

    func testDevelopmentOverridesProduction() {
        let s = freshStore()
        s.backendBaseURLString = "https://prod.example.com"
        s.devBaseURLString = "https://dev.example.com"
        s.environment = .development
        XCTAssertEqual(s.backendConfig.baseURL?.absoluteString, "https://dev.example.com")
    }

    func testWebSocketFollowsEnvironment() {
        let s = freshStore()
        s.websocketURLString = "wss://prod.example.com/live"
        s.stagingWebSocketURLString = "wss://staging.example.com/live"
        s.environment = .staging
        XCTAssertEqual(s.backendConfig.websocketURL?.absoluteString, "wss://staging.example.com/live")
        s.environment = .production
        XCTAssertEqual(s.backendConfig.websocketURL?.absoluteString, "wss://prod.example.com/live")
    }

    func testResetClearsEnvironments() {
        let s = freshStore()
        s.stagingBaseURLString = "https://staging.example.com"
        s.devBaseURLString = "https://dev.example.com"
        s.environment = .staging
        s.resetToDefaults()
        XCTAssertEqual(s.environment, .production)
        XCTAssertEqual(s.stagingBaseURLString, "")
        XCTAssertEqual(s.devBaseURLString, "")
    }
}
