import Foundation

/// Ecosystem sync: shared memory + tasks on the user's own hub (laptop
/// server), mirroring the local stores. iOS is one client among many
/// (Android/Desktop use the same REST contract).
///
/// Policy — offline-first, local truth wins:
/// - save/create: local first, hub best-effort after (a dead server never
///   blocks saving; the item syncs on a later op — no silent loss, but no
///   cross-device guarantee for that write either).
/// - search/list: local + hub merged, deduped by content/title (hub items
///   are display copies with fresh local IDs — never written back, no loops).
/// - complete/cancel/forget: applied locally, then to the hub twin matched
///   by title/content (hub IDs differ per store — matched, never assumed).
/// - update/snooze: local only in v1 (documented; hub twins keep old values
///   until the next create/complete cycle replaces them).
/// - Unconfigured backend or missing key: pure local, zero network attempts.
///
/// Mirrors BackendAIService's dependencies (api/auth/configProvider) so
/// AppDependencies wires it identically. Auth failures are swallowed like
/// any transport failure — sync degrades, the app keeps working.
public struct HubMemoryDTO: Codable, Sendable {
    public var id: String
    public var content: String
    public var tags: [String]
    public var importance: Double
    public var createdAt: String
    public var updatedAt: String
}

public struct HubMemoryList: Codable, Sendable {
    public var memories: [HubMemoryDTO]
}

public struct HubTaskDTO: Codable, Sendable {
    public var id: String
    public var title: String
    public var notes: String?
    public var dueDate: String?
    public var priority: String
    public var isCompleted: Bool
    public var isCancelled: Bool
    public var createdAt: String
}

public struct HubTaskList: Codable, Sendable {
    public var tasks: [HubTaskDTO]
}

private struct HubSaveMemoryBody: Encodable {
    var content: String
    var tags: [String]
    var importance: Double
}

private struct HubCreateTaskBody: Encodable {
    var title: String
    var notes: String?
    var dueDate: String?
    var priority: String
}

private func hubDate(from string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter.date(from: string)
}

/// Shared circuit breaker for hub sync.
///
/// Why it exists: every chat turn asks the memory service for context BEFORE
/// the AI request is dispatched. When the hub URL is configured but the
/// laptop is asleep/off, that per-turn hub round-trip used to sit on the
/// connection until the 30 s request timeout — the reply "took 20-25 s"
/// even though Gemini itself answers in ~2 s.
///
/// Behaviour:
/// - A hub call costs one short attempt (`hubProbeTimeout`).
/// - On failure the breaker OPENS for `openSeconds`; every call in that
///   window returns immediately without touching the network, so a dead hub
///   is free rather than slow.
/// - The very next call after the window probes again, so the hub coming
///   back is picked up automatically (no manual reconnect, no toggle).
///
/// Deliberately NOT `@MainActor`: it is referenced from default-argument
/// expressions (`= .shared`), which are nonisolated, and from the sendable
/// fallback path. State is guarded by a lock instead, so it is safe to touch
/// from any context.
public final class HubCircuitBreaker: @unchecked Sendable {
    public static let shared = HubCircuitBreaker()

    /// How long a hub request may take before we call the hub unreachable.
    /// Deliberately short: this sits on the critical path of a chat turn.
    public static let hubProbeTimeout: TimeInterval = 2.0
    /// How long the breaker stays open after a failure.
    public static let openSeconds: TimeInterval = 30.0

    private let lock = NSLock()
    private var openUntil: Date?

    public init() {}

    /// True when the caller may attempt a hub request right now.
    public func shouldAttempt(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let openUntil else { return true }
        return now >= openUntil
    }

    public func recordSuccess() {
        lock.lock()
        defer { lock.unlock() }
        openUntil = nil
    }

    /// Opens the breaker on a failure that means "hub unreachable"
    /// (timeout/transport/no-connection). Server-side responses — even
    /// errors — prove the hub is up and must NOT open it.
    public func recordFailure(_ error: Error) {
        guard Self.isUnreachable(error) else { return }
        lock.lock()
        defer { lock.unlock() }
        openUntil = Date().addingTimeInterval(Self.openSeconds)
    }

    /// Test/seatbelt hook: forget any open state.
    public func reset() {
        recordSuccess()
    }

    static func isUnreachable(_ error: Error) -> Bool {
        if let net = error as? NetworkError {
            switch net {
            case .timeout, .transport, .noConnection:
                return true
            default:
                return false
            }
        }
        return (error as NSError).domain == NSURLErrorDomain
    }
}

@MainActor
public final class SyncedMemoryService: MemoryService {

    private let local: any MemoryService
    private let api: any APIClient
    private let auth: any BackendAuthProvider
    private let configProvider: () -> BackendConfig
    private let breaker: HubCircuitBreaker

    public init(
        local: any MemoryService,
        api: any APIClient,
        auth: any BackendAuthProvider,
        configProvider: @escaping () -> BackendConfig,
        breaker: HubCircuitBreaker = .shared
    ) {
        self.local = local
        self.api = api
        self.auth = auth
        self.configProvider = configProvider
        self.breaker = breaker
    }

    private struct Target: Sendable {
        var version: String
        var key: String
    }

    private func target() -> Target? {
        let config = configProvider()
        guard config.isConfigured else { return nil }
        guard let key = try? auth.bearerToken(), !key.isEmpty else { return nil }
        return Target(version: config.apiVersion, key: key)
    }

    private func authorized(path: String, method: String, body: Data?, target: Target) throws -> URLRequest {
        var request = try api.makeRequest(path: path, method: method, body: body, headers: [:])
        request.setValue("Bearer \(target.key)", forHTTPHeaderField: "Authorization")
        // Hub sync never stalls a chat turn: the probe timeout wins over the
        // general request timeout (which is tuned for the AI backend).
        request.timeoutInterval = min(request.timeoutInterval, HubCircuitBreaker.hubProbeTimeout)
        return request
    }

    public func save(content: String, tags: [String], importance: Double) async throws -> MemoryItem {
        let item = try await local.save(content: content, tags: tags, importance: importance)
        guard let hub = target() else { return item }
        do {
            let body = try JSONEncoder().encode(HubSaveMemoryBody(content: item.content, tags: item.tags, importance: item.importance))
            let request = try authorized(path: "/api/\(hub.version)/memory", method: "POST", body: body, target: hub)
            _ = try await api.sendData(request)
        } catch {
            ZyraxisLogger.log(.memory, "hub mirror failed (local kept): \(error.localizedDescription)")
        }
        return item
    }

    public func search(query: String, limit: Int) async throws -> [MemoryItem] {
        var out = try await local.search(query: query, limit: limit)
        // Local answer is already in hand; the hub only adds cross-device
        // extras. Skip it entirely while the breaker is open so a down hub
        // costs this turn nothing.
        guard let hub = target(), breaker.shouldAttempt() else { return out }
        do {
            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
            let path = "/api/\(hub.version)/memory" + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
            let request = try authorized(path: path, method: "GET", body: nil, target: hub)
            let list: HubMemoryList = try await api.send(request, as: HubMemoryList.self)
            breaker.recordSuccess()
            var seen = Set(out.map { $0.content })
            for dto in list.memories where !seen.contains(dto.content) {
                seen.insert(dto.content)
                out.append(MemoryItem(content: dto.content, tags: dto.tags, importance: dto.importance))
            }
        } catch {
            breaker.recordFailure(error)
            ZyraxisLogger.log(.memory, "hub search failed (local only): \(error.localizedDescription)")
        }
        return out
    }

    public func update(id: UUID, content: String?, tags: [String]?, importance: Double?) async throws -> MemoryItem {
        // Local-only in v1 (see policy above).
        return try await local.update(id: id, content: content, tags: tags, importance: importance)
    }

    public func forget(id: UUID) async throws {
        // Resolve content BEFORE deleting (needed for the hub-twin lookup).
        let condemned = try? await local.search(query: "", limit: 100).first(where: { $0.id == id })
        try await local.forget(id: id)
        guard let hub = target(), let content = condemned?.content else { return }
        do {
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "query", value: content), URLQueryItem(name: "limit", value: "5")]
            let path = "/api/\(hub.version)/memory" + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
            let request = try authorized(path: path, method: "GET", body: nil, target: hub)
            let list: HubMemoryList = try await api.send(request, as: HubMemoryList.self)
            for twin in list.memories where twin.content == content {
                let del = try authorized(path: "/api/\(hub.version)/memory/\(twin.id)", method: "DELETE", body: nil, target: hub)
                _ = try? await api.sendData(del)
            }
        } catch {
            ZyraxisLogger.log(.memory, "hub forget failed (local done): \(error.localizedDescription)")
        }
    }

    public func listAll() async throws -> [MemoryItem] {
        return try await search(query: "", limit: 100)
    }
}

@MainActor
public final class SyncedTaskService: TaskService {

    private let local: any TaskService
    private let api: any APIClient
    private let auth: any BackendAuthProvider
    private let configProvider: () -> BackendConfig
    private let breaker: HubCircuitBreaker

    public init(
        local: any TaskService,
        api: any APIClient,
        auth: any BackendAuthProvider,
        configProvider: @escaping () -> BackendConfig,
        breaker: HubCircuitBreaker = .shared
    ) {
        self.local = local
        self.api = api
        self.auth = auth
        self.configProvider = configProvider
        self.breaker = breaker
    }

    private struct Target: Sendable {
        var version: String
        var key: String
    }

    private func target() -> Target? {
        let config = configProvider()
        guard config.isConfigured else { return nil }
        guard let key = try? auth.bearerToken(), !key.isEmpty else { return nil }
        return Target(version: config.apiVersion, key: key)
    }

    private func authorized(path: String, method: String, body: Data?, target: Target) throws -> URLRequest {
        var request = try api.makeRequest(path: path, method: method, body: body, headers: [:])
        request.setValue("Bearer \(target.key)", forHTTPHeaderField: "Authorization")
        // Same rule as memory sync: never let hub chatter stall a user action.
        request.timeoutInterval = min(request.timeoutInterval, HubCircuitBreaker.hubProbeTimeout)
        return request
    }

    /// Hub twin id for a local title (hub IDs differ per store — matched,
    /// never assumed). Nil when absent or unreachable.
    private func hubTwinId(title: String, target: Target) async -> String? {
        guard breaker.shouldAttempt() else { return nil }
        do {
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "filter", value: "all")]
            let path = "/api/\(target.version)/tasks" + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
            let request = try authorized(path: path, method: "GET", body: nil, target: target)
            let list: HubTaskList = try await api.send(request, as: HubTaskList.self)
            breaker.recordSuccess()
            return list.tasks.first(where: { $0.title == title })?.id
        } catch {
            breaker.recordFailure(error)
            return nil
        }
    }

    public func create(title: String, notes: String?, dueDate: Date?, priority: ZyraxisTask.Priority) async throws -> ZyraxisTask {
        let task = try await local.create(title: title, notes: notes, dueDate: dueDate, priority: priority)
        guard let hub = target() else { return task }
        do {
            var dueString: String?
            if let dueDate {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                dueString = formatter.string(from: dueDate)
            }
            let body = try JSONEncoder().encode(HubCreateTaskBody(
                title: task.title, notes: task.notes, dueDate: dueString, priority: task.priority.rawValue
            ))
            let request = try authorized(path: "/api/\(hub.version)/tasks", method: "POST", body: body, target: hub)
            _ = try await api.sendData(request)
        } catch {
            ZyraxisLogger.log(.tasks, "hub mirror failed (local kept): \(error.localizedDescription)")
        }
        return task
    }

    public func list(filter: TaskFilter) async throws -> [ZyraxisTask] {
        var out = try await local.list(filter: filter)
        guard let hub = target() else { return out }
        let name: String
        switch filter {
        case .all: name = "all"
        case .active: name = "active"
        case .completed: name = "completed"
        case .cancelled: name = "cancelled"
        case .dueToday: name = "active"
        }
        do {
            let request = try authorized(path: "/api/\(hub.version)/tasks?filter=\(name)", method: "GET", body: nil, target: hub)
            let list: HubTaskList = try await api.send(request, as: HubTaskList.self)
            var seen = Set(out.map { $0.title })
            for dto in list.tasks where !seen.contains(dto.title) {
                seen.insert(dto.title)
                out.append(ZyraxisTask(
                    title: dto.title,
                    notes: dto.notes,
                    dueDate: hubDate(from: dto.dueDate),
                    isCompleted: dto.isCompleted,
                    isCancelled: dto.isCancelled,
                    priority: ZyraxisTask.Priority(rawValue: dto.priority) ?? .medium
                ))
            }
            if filter == .dueToday {
                let day = Calendar.current.startOfDay(for: Date())
                out = out.filter {
                    guard let due = $0.effectiveDueDate else { return false }
                    return Calendar.current.startOfDay(for: due) <= day
                }
            }
        } catch {
            ZyraxisLogger.log(.tasks, "hub list failed (local only): \(error.localizedDescription)")
        }
        return out
    }

    public func update(id: UUID, title: String?, notes: String?, dueDate: Date?, priority: ZyraxisTask.Priority?) async throws -> ZyraxisTask {
        // Local-only in v1 (see policy above).
        return try await local.update(id: id, title: title, notes: notes, dueDate: dueDate, priority: priority)
    }

    public func cancel(id: UUID) async throws -> ZyraxisTask {
        // Resolve title BEFORE cancelling (needed for the hub-twin lookup).
        let condemned = try? await local.list(filter: .all).first(where: { $0.id == id })
        let task = try await local.cancel(id: id)
        if let hub = target(), let title = condemned?.title,
           let twin = await hubTwinId(title: title, target: hub) {
            do {
                let request = try authorized(path: "/api/\(hub.version)/tasks/\(twin)/cancel", method: "POST", body: nil, target: hub)
                _ = try? await api.sendData(request)
            } catch {
                ZyraxisLogger.log(.tasks, "hub cancel failed (local done): \(error.localizedDescription)")
            }
        }
        return task
    }

    public func complete(id: UUID) async throws -> ZyraxisTask {
        let condemned = try? await local.list(filter: .all).first(where: { $0.id == id })
        let task = try await local.complete(id: id)
        if let hub = target(), let title = condemned?.title,
           let twin = await hubTwinId(title: title, target: hub) {
            do {
                let request = try authorized(path: "/api/\(hub.version)/tasks/\(twin)/complete", method: "POST", body: nil, target: hub)
                _ = try? await api.sendData(request)
            } catch {
                ZyraxisLogger.log(.tasks, "hub complete failed (local done): \(error.localizedDescription)")
            }
        }
        return task
    }

    public func snooze(id: UUID, until: Date) async throws -> ZyraxisTask {
        // Local-only in v1 (see policy above).
        return try await local.snooze(id: id, until: until)
    }
}
