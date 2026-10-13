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
