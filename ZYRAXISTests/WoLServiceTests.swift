import XCTest
@testable import ZYRAXIS

/// Minimal APIClient double for WoLService tests.
private final class WoLMockAPIClient: APIClient, @unchecked Sendable {
    var capturedRequest: URLRequest?
    var shouldFail = false
    var failError: NetworkError = .transport("mock failure")
    var mockResponseData: Data = "{}".data(using: .utf8)!
    var mockStatusCode: Int = 200

    func sendData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequest = request
        if shouldFail { throw failError }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: mockStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (mockResponseData, response)
    }

    func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, _) = try await sendData(request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func makeRequest(path: String, method: String, body: Data?, headers: [String: String]) throws -> URLRequest {
        var urlComps = URLComponents()
        urlComps.scheme = "https"
        urlComps.host = "test.example.com"
        urlComps.path = path
        var request = URLRequest(url: urlComps.url!)
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }
}

/// BackendAuthProvider double for WoLService tests.
/// @unchecked Sendable: mutable `token`/`shouldFail` are only touched from tests,
/// never crossed actor boundaries, so this is safe.
private final class WoLMockAuthProvider: BackendAuthProvider, @unchecked Sendable {
    var token: String? = "test-token-123"
    var shouldFail = false

    func bearerToken() throws -> String? {
        if shouldFail { throw NetworkError.unauthorized }
        return token
    }
}

/// BackendConfig double for WoLService tests.
private func makeConfig(configured: Bool = true) -> BackendConfig {
    BackendConfig(
        baseURL: configured ? URL(string: "https://test.example.com") : nil,
        websocketURL: nil,
        requestTimeout: 30
    )
}

/// WoLService unit tests. No network — all HTTP goes through a mock client.
@MainActor
final class WoLServiceTests: XCTestCase {

    private var api: WoLMockAPIClient!
    private var auth: WoLMockAuthProvider!
    private var service: WoLService!

    override func setUp() {
        super.setUp()
        api = WoLMockAPIClient()
        auth = WoLMockAuthProvider()
        service = WoLService(
            api: api,
            auth: auth,
            configProvider: { makeConfig(configured: true) }
        )
    }

    override func tearDown() {
        api = nil
        auth = nil
        service = nil
        super.tearDown()
    }

    // MARK: - configure

    func testConfigureSendsMACToHub() async throws {
        try await service.configure(mac: "AA:BB:CC:DD:EE:FF", broadcast: "255.255.255.255")

        guard let request = api.capturedRequest else {
            XCTFail("No request was made")
            return
        }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/wol/config")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-123")

        let body = try JSONDecoder().decode([String: String].self, from: api.capturedRequest!.httpBody ?? Data())
        XCTAssertEqual(body["mac"], "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(body["broadcastAddress"], "255.255.255.255")
        XCTAssertEqual(service.lastStatus, "Configured (HTTP 200)")
        XCTAssertNil(service.lastError)
    }

    func testConfigureRejectsUnconfiguredBackend() async {
        service = WoLService(
            api: api,
            auth: auth,
            configProvider: { makeConfig(configured: false) }
        )
        do {
            try await service.configure(mac: "AA:BB:CC:DD:EE:FF")
            XCTFail("Expected transport error for unconfigured backend")
        } catch let e as NetworkError {
            XCTAssertTrue(e.localizedDescription.contains("Backend not configured"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testConfigureRejectsMissingAuth() async {
        auth.shouldFail = true
        do {
            try await service.configure(mac: "AA:BB:CC:DD:EE:FF")
            XCTFail("Expected unauthorized error")
        } catch let e as NetworkError {
            XCTAssertEqual(e, .unauthorized)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testConfigurePropagatesTransportError() async {
        api.shouldFail = true
        api.failError = .timeout
        do {
            try await service.configure(mac: "AA:BB:CC:DD:EE:FF")
            XCTFail("Expected timeout error")
        } catch let e as NetworkError {
            XCTAssertEqual(e, .timeout)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - wake

    func testWakeSendsMagicPacket() async throws {
        try await service.wake()

        guard let request = api.capturedRequest else {
            XCTFail("No request was made")
            return
        }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/wol/wake")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-123")
        XCTAssertEqual(service.lastStatus, "Magic packet sent (HTTP 200)")
        XCTAssertNil(service.lastError)
    }

    func testWakeRejectsUnconfiguredBackend() async {
        service = WoLService(
            api: api,
            auth: auth,
            configProvider: { makeConfig(configured: false) }
        )
        do {
            try await service.wake()
            XCTFail("Expected transport error for unconfigured backend")
        } catch let e as NetworkError {
            XCTAssertTrue(e.localizedDescription.contains("Backend not configured"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testWakePropagatesTransportError() async {
        api.shouldFail = true
        api.failError = .noConnection
        do {
            try await service.wake()
            XCTFail("Expected noConnection error")
        } catch let e as NetworkError {
            XCTAssertEqual(e, .noConnection)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testResetDiagnostics() {
        service.lastStatus = "some status"
        service.lastError = "some error"
        service.resetDiagnostics()
        XCTAssertNil(service.lastStatus)
        XCTAssertNil(service.lastError)
    }

    // MARK: - Named profiles (multi-PC)

    func testConfigureNamedProfileSendsNameAndBroadcast() async throws {
        try await service.configure(
            name: "Office PC",
            mac: "AA:BB:CC:DD:EE:02",
            broadcast: "192.168.1.255"
        )

        let body = try JSONSerialization.jsonObject(
            with: api.capturedRequest?.httpBody ?? Data()
        ) as? [String: Any]
        XCTAssertEqual(body?["name"] as? String, "Office PC")
        XCTAssertEqual(body?["mac"] as? String, "AA:BB:CC:DD:EE:02")
        XCTAssertEqual(body?["broadcastAddress"] as? String, "192.168.1.255")
        XCTAssertEqual(api.capturedRequest?.url?.path, "/api/v1/wol/config")
    }

    func testConfigureProfileUsesProfileName() async throws {
        let profile = WoLProfile(name: "School PC", mac: "AA:BB:CC:DD:EE:03")
        try await service.configure(profile)

        let body = try JSONSerialization.jsonObject(
            with: api.capturedRequest?.httpBody ?? Data()
        ) as? [String: Any]
        XCTAssertEqual(body?["name"] as? String, "School PC")
        XCTAssertEqual(body?["broadcastAddress"] as? String, "255.255.255.255")
    }

    func testWakeNamedProfileSendsName() async throws {
        try await service.wake(name: "Office PC")

        XCTAssertEqual(api.capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(api.capturedRequest?.url?.path, "/api/v1/wol/wake")
        XCTAssertEqual(api.capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-123")

        let body = try JSONSerialization.jsonObject(
            with: api.capturedRequest?.httpBody ?? Data()
        ) as? [String: Any]
        XCTAssertEqual(body?["name"] as? String, "Office PC")
    }

    func testRemoveProfileUsesDelete() async throws {
        try await service.removeProfile(named: "OfficePC")

        XCTAssertEqual(api.capturedRequest?.httpMethod, "DELETE")
        XCTAssertEqual(api.capturedRequest?.url?.path, "/api/v1/wol/config/OfficePC")
        XCTAssertEqual(api.capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-123")
    }

    func testWakeProfileConfiguresThenWakes() async throws {
        let profile = WoLProfile(name: "HomePC", mac: "AA:BB:CC:DD:EE:01", broadcast: "192.168.1.255")
        try await service.wake(profile)

        // The last request must be the wake call, not the configure upsert.
        XCTAssertEqual(api.capturedRequest?.url?.path, "/api/v1/wol/wake")
        XCTAssertEqual(service.lastStatus, "Magic packet sent (HTTP 200)")
    }

    func testEncodePathSegmentEscapesSpaces() {
        XCTAssertEqual(WoLService.encodePathSegment("Home PC"), "Home%20PC")
        XCTAssertEqual(WoLService.encodePathSegment("OfficePC"), "OfficePC")
        XCTAssertEqual(WoLService.encodePathSegment("School-PC_2"), "School-PC_2")
    }
}
