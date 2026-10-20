import XCTest
@testable import ZYRAXIS

/// Ecosystem sync: hub-mirrored memory/tasks, offline-first degradation,
/// device identity payloads. Fake HTTP doubles; no backend required.
@MainActor
final class SyncTests: XCTestCase {

    // MARK: - Doubles

    final class FakeAPIClient: APIClient {
        struct Call {
            var path: String
            var method: String
        }
        var calls: [Call] = []
        var failAll = false
        var canned: [String: Data] = [:]
        var deletedIds = Set<String>()

        func makeRequest(path: String, method: String, body: Data?, headers: [String: String]) throws -> URLRequest {
            calls.append(Call(path: path, method: method))
            var request = URLRequest(url: URL(string: "https://hub.test" + path)!)
            request.httpMethod = method
            request.httpBody = body
            return request
        }

        func sendData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if failAll { throw NetworkError.transport("hub down") }
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            if method == "DELETE", let last = path.split(separator: "/").last {
                deletedIds.insert(String(last))
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            var data = canned.first(where: { path.hasPrefix($0.key) })?.value ?? Data("{}".utf8)
            // Stateful fake hub: deleted twins stay deleted for later GETs.
            if method == "GET", !deletedIds.isEmpty,
               let list = try? JSONDecoder().decode(HubMemoryList.self, from: data) {
                let kept = list.memories.filter { !deletedIds.contains($0.id) }
                data = (try? JSONEncoder().encode(HubMemoryList(memories: kept))) ?? data
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
            let (data, _) = try await sendData(request)
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

    struct FakeAuth: BackendAuthProvider {
        var token: String?
        func bearerToken() throws -> String? { token }
    }

    private func hubConfig() -> BackendConfig {
        BackendConfig(baseURL: URL(string: "https://hub.test"), websocketURL: nil)
    }

    private func makeMemory(
        api: FakeAPIClient,
        key: String? = "k",
        breaker: HubCircuitBreaker = HubCircuitBreaker()
    ) -> SyncedMemoryService {
        SyncedMemoryService(
            local: InMemoryMemoryService(),
            api: api,
            auth: FakeAuth(token: key),
            configProvider: { [config = self.hubConfig()] in config },
            breaker: breaker
        )
    }

    private func makeTasks(
        api: FakeAPIClient,
        key: String? = "k",
        breaker: HubCircuitBreaker = HubCircuitBreaker()
    ) -> SyncedTaskService {
        SyncedTaskService(
            local: LocalTaskService(notifications: nil),
            api: api,
            auth: FakeAuth(token: key),
            configProvider: { [config = self.hubConfig()] in config },
            breaker: breaker
        )
    }

    // MARK: - Memory sync

    func testSaveMirrorsToHub() async throws {
        let api = FakeAPIClient()
        api.canned["/api/v1/memory"] = Data(
            #"{"memories":[{"id":"h1","content":"cats","tags":[],"importance":0.5,"createdAt":"2026-01-01T00:00:00","updatedAt":"2026-01-01T00:00:00"}]}"#.utf8)
        let svc = makeMemory(api: api)
        let item = try await svc.save(content: "cats", tags: [], importance: 0.5)
        XCTAssertEqual(item.content, "cats")
        XCTAssertTrue(api.calls.contains { $0.path == "/api/v1/memory" && $0.method == "POST" })
        let found = try await svc.search(query: "cats", limit: 5)
        XCTAssertEqual(found.count, 1, "hub twin dedupes by content")
    }

    func testSaveSurvivesDeadHub() async throws {
        let api = FakeAPIClient()
        api.failAll = true
        let svc = makeMemory(api: api)
        let item = try await svc.save(content: "offline note", tags: [], importance: 0.5)
        XCTAssertEqual(item.content, "offline note")
        let found = try await svc.search(query: "offline", limit: 5)
        XCTAssertEqual(found.count, 1)
    }

    func testSearchMergesWithoutDuplicates() async throws {
        let api = FakeAPIClient()
        api.canned["/api/v1/memory"] = Data(
            #"{"memories":[{"id":"h1","content":"shared fact","tags":[],"importance":0.5,"createdAt":"2026-01-01T00:00:00","updatedAt":"2026-01-01T00:00:00"},{"id":"h2","content":"local fact","tags":[],"importance":0.5,"createdAt":"2026-01-01T00:00:00","updatedAt":"2026-01-01T00:00:00"}]}"#.utf8)
        let svc = makeMemory(api: api)
        _ = try await svc.save(content: "local fact", tags: [], importance: 0.5)
        let found = try await svc.search(query: "fact", limit: 10)
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.contains { $0.content == "shared fact" })
    }

    func testForgetDeletesTwin() async throws {
        let api = FakeAPIClient()
        api.canned["/api/v1/memory"] = Data(
            #"{"memories":[{"id":"h9","content":"bye","tags":[],"importance":0.5,"createdAt":"2026-01-01T00:00:00","updatedAt":"2026-01-01T00:00:00"}]}"#.utf8)
        let svc = makeMemory(api: api)
        let item = try await svc.save(content: "bye", tags: [], importance: 0.5)
        try await svc.forget(id: item.id)
        XCTAssertTrue(api.calls.contains { $0.method == "DELETE" && $0.path.contains("h9") })
        let found = try await svc.search(query: "bye", limit: 5)
        XCTAssertTrue(found.isEmpty)
    }

    func testNoKeyMeansLocalOnly() async throws {
        let api = FakeAPIClient()
        let svc = makeMemory(api: api, key: nil)
        _ = try await svc.save(content: "private", tags: [], importance: 0.5)
        XCTAssertTrue(api.calls.isEmpty, "no key must mean zero network attempts")
    }

    // MARK: - Task sync

    func testTaskCreateAndListMerge() async throws {
        let api = FakeAPIClient()
        api.canned["/api/v1/tasks"] = Data(
            #"{"tasks":[{"id":"t9","title":"Hub job","notes":null,"dueDate":null,"priority":"high","isCompleted":false,"isCancelled":false,"createdAt":"2026-01-01T00:00:00"}]}"#.utf8)
        let svc = makeTasks(api: api)
        let task = try await svc.create(title: "Local job", notes: nil, dueDate: nil, priority: .medium)
        XCTAssertEqual(task.title, "Local job")
        XCTAssertTrue(api.calls.contains { $0.method == "POST" })
        let all = try await svc.list(filter: .all)
        XCTAssertTrue(all.contains { $0.title == "Local job" })
        XCTAssertTrue(all.contains { $0.title == "Hub job" })
        let hub = all.first(where: { $0.title == "Hub job" })
        XCTAssertEqual(hub?.priority, .high)
        XCTAssertNil(hub?.dueDate)
    }

    func testTaskCompleteMirrorsTwin() async throws {
        let api = FakeAPIClient()
        api.canned["/api/v1/tasks"] = Data(
            #"{"tasks":[{"id":"twin-1","title":"Twin job","notes":null,"dueDate":null,"priority":"medium","isCompleted":false,"isCancelled":false,"createdAt":"2026-01-01T00:00:00"}]}"#.utf8)
        let svc = makeTasks(api: api)
        let task = try await svc.create(title: "Twin job", notes: nil, dueDate: nil, priority: .medium)
        _ = try await svc.complete(id: task.id)
        XCTAssertTrue(api.calls.contains { $0.path.contains("twin-1/complete") })
    }

    // MARK: - Identity

    func testSessionPayloadCarriesIdentity() throws {
        let full = SessionStartPayload(sessionId: "s", clientModel: "iPhone",
                                       appVersion: "0.5.0", deviceId: "d1", deviceName: "Yasir")
        let text = try ZyraxisEnvelope(type: .sessionStart, requestId: UUID().uuidString,
                                       payload: ["sessionId": .string("s")]).encode()
        XCTAssertTrue(text.contains("session_start"))
        // Back-compat: nils stay absent from the wire dict.
        let bare = SessionStartPayload(sessionId: "s")
        let dict = try BackendAIService.payload(bare)
        XCTAssertNil(dict["deviceId"])
        XCTAssertEqual(full.deviceId, "d1")
        XCTAssertEqual(full.deviceName, "Yasir")
    }

    func testDeviceIdIsStablePerInstall() {
        let defaults = UserDefaults(suiteName: "zyraxis.sync.tests")!
        defaults.removePersistentDomain(forName: "zyraxis.sync.tests")
        let first = SettingsStore(defaults: defaults).deviceId
        let second = SettingsStore(defaults: defaults).deviceId
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second, "same install must keep its identity")
        XCTAssertEqual(first.components(separatedBy: "-").count, 5, "UUID shape")
    }

    // MARK: - Hub circuit breaker (the "reply took 20-25 s" fix)

    /// The bug: a configured-but-dead hub was contacted on EVERY turn before
    /// the AI ran, costing a full timeout. Now the first failure opens the
    /// breaker and later turns make zero hub calls.
    func testDeadHubIsContactedOnlyOnce() async throws {
        let api = FakeAPIClient()
        api.failAll = true
        let breaker = HubCircuitBreaker()
        let svc = makeMemory(api: api, breaker: breaker)

        // Turn 1: one attempt, fails, breaker opens.
        _ = try await svc.search(query: "a", limit: 5)
        let afterFirst = api.calls.count
        XCTAssertGreaterThan(afterFirst, 0, "the first turn must probe the hub")

        // Turns 2..4: no network at all, and the local answer still works.
        for _ in 0..<3 {
            let found = try await svc.search(query: "a", limit: 5)
            XCTAssertNotNil(found, "local memory must still answer")
        }
        XCTAssertEqual(api.calls.count, afterFirst, "open breaker must not touch the network")
    }

    /// Server-side failures prove the hub is alive — they must NOT open the
    /// breaker, or a healthy hub with a bad request would stop syncing.
    func testServerErrorDoesNotOpenBreaker() {
        let breaker = HubCircuitBreaker()
        XCTAssertTrue(breaker.shouldAttempt())
        breaker.recordFailure(NetworkError.server(statusCode: 500, message: "boom"))
        XCTAssertTrue(breaker.shouldAttempt(), "500 means reachable, not unreachable")
        breaker.recordFailure(NetworkError.unauthorized)
        XCTAssertTrue(breaker.shouldAttempt(), "401 means reachable, not unreachable")
    }

    /// Unreachable-class failures DO open it, and success closes it again.
    func testUnreachableOpensAndSuccessCloses() {
        let breaker = HubCircuitBreaker()
        breaker.recordFailure(NetworkError.timeout)
        XCTAssertFalse(breaker.shouldAttempt())
        breaker.recordSuccess()
        XCTAssertTrue(breaker.shouldAttempt(), "a good call must close the breaker")
    }

    /// The probe timeout must be short — it sits on the chat critical path.
    func testHubProbeTimeoutIsShort() {
        XCTAssertLessThanOrEqual(HubCircuitBreaker.hubProbeTimeout, 3.0)
        XCTAssertGreaterThanOrEqual(HubCircuitBreaker.hubProbeTimeout, 0.5)
    }

    /// Tasks get the same protection as memory.
    func testDeadHubDoesNotSlowTaskListing() async throws {
        let api = FakeAPIClient()
        api.failAll = true
        let breaker = HubCircuitBreaker()
        let svc = makeTasks(api: api, breaker: breaker)
        _ = try await svc.list(filter: .all)
        let afterFirst = api.calls.count
        _ = try await svc.list(filter: .all)
        _ = try await svc.list(filter: .all)
        XCTAssertEqual(api.calls.count, afterFirst, "open breaker must skip hub task calls")
    }
}
