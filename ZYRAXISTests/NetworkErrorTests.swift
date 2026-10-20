import XCTest
@testable import ZYRAXIS

final class NetworkErrorTests: XCTestCase {

    func testStatusCodeMapping() {
        XCTAssertEqual(NetworkError.fromStatusCode(401), .unauthorized)
        XCTAssertEqual(NetworkError.fromStatusCode(403), .forbidden)
        XCTAssertEqual(NetworkError.fromStatusCode(404), .notFound)
        XCTAssertEqual(
            NetworkError.fromStatusCode(500, message: "oops"),
            .server(statusCode: 500, message: "oops")
        )
    }

    /// The fallback chain must advance when a provider is dead, not when the
    /// user's key is wrong (retrying auth/config only burns time or loops).
    func testFallbackWorthyClassification() {
        // Dead or busy provider -> try the next one.
        XCTAssertTrue(NetworkError.timeout.isFallbackWorthy)
        XCTAssertTrue(NetworkError.transport("boom").isFallbackWorthy)
        XCTAssertTrue(NetworkError.noConnection.isFallbackWorthy)
        XCTAssertTrue(NetworkError.server(statusCode: 429, message: "slow down").isFallbackWorthy)
        XCTAssertTrue(NetworkError.server(statusCode: 503, message: "unavailable").isFallbackWorthy)

        // Retired model ID (404 model_not_found) means the provider is dead
        // until reconfigured — NOT falling back here turned "Gemini is slow"
        // into "no answer at all".
        XCTAssertTrue(NetworkError.notFound.isFallbackWorthy)
        XCTAssertTrue(NetworkError.fromStatusCode(404).isFallbackWorthy)
        XCTAssertTrue(NetworkError.server(statusCode: 404, message: "model_not_found").isFallbackWorthy)

        // Never fall back: retrying cannot help and may loop.
        XCTAssertFalse(NetworkError.unauthorized.isFallbackWorthy)
        XCTAssertFalse(NetworkError.forbidden.isFallbackWorthy)
        XCTAssertFalse(NetworkError.cancelled.isFallbackWorthy)
        XCTAssertFalse(NetworkError.invalidURL("nope").isFallbackWorthy)
        XCTAssertFalse(NetworkError.server(statusCode: 400, message: "bad request").isFallbackWorthy)
    }

    func testDescriptionsAreHelpful() {
        XCTAssertTrue(NetworkError.timeout.localizedDescription.lowercased().contains("timed out"))
        XCTAssertTrue(NetworkError.noConnection.localizedDescription.lowercased().contains("connection"))
        XCTAssertTrue(NetworkError.cancelled.localizedDescription.lowercased().contains("cancelled"))
    }

    func testMakeRequestRequiresBackend() throws {
        let client = URLSessionAPIClient(config: .default)
        XCTAssertThrowsError(
            try client.makeRequest(path: "/v1/chat", method: "GET", body: nil, headers: [:])
        ) { error in
            guard let ne = error as? NetworkError else {
                return XCTFail("expected NetworkError, got \(error)")
            }
            if case .transport(let msg) = ne {
                XCTAssertTrue(msg.lowercased().contains("not configured"))
            } else {
                XCTFail("expected .transport, got \(ne)")
            }
        }
    }

    func testMakeRequestBuildsURL() throws {
        let config = BackendConfig(
            baseURL: URL(string: "https://api.example.com"),
            websocketURL: nil
        )
        let client = URLSessionAPIClient(config: config)
        let req = try client.makeRequest(path: "/v1/chat", method: "POST", body: Data("{}".utf8), headers: [:])
        XCTAssertEqual(req.url?.absoluteString, "https://api.example.com/v1/chat")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testBackendConfigParsing() {
        XCTAssertNil(BackendConfig.parseBaseURL(""))
        XCTAssertNil(BackendConfig.parseBaseURL("not a url"))
        XCTAssertNotNil(BackendConfig.parseBaseURL("https://api.example.com"))
        XCTAssertNil(BackendConfig.parseWebSocketURL("https://api.example.com"))
        XCTAssertNotNil(BackendConfig.parseWebSocketURL("wss://api.example.com/live"))
    }

    func testConnectionStateLabels() {
        XCTAssertEqual(ConnectionState.connected.displayLabel, "ONLINE")
        XCTAssertTrue(ConnectionState.connected.isLive)
        XCTAssertFalse(ConnectionState.disconnected.isLive)
        XCTAssertEqual(ConnectionState.reconnecting(attempt: 2).displayLabel, "RECONNECTING (2)")
    }
}
