import Foundation
import Combine

/// WebSocket lifecycle manager with reconnect + connection-state publishing.
///
/// Built on `URLSessionWebSocketTask`. Text frames carry versioned JSON
/// envelopes (see `BackendProtocol`); binary frames are reserved for future
/// audio chunks. Audio streaming is NOT implemented.
///
/// Phase 2 hardening:
/// - single socket + single receive loop (generation-guarded, no duplicates)
/// - ping/keepalive with failure-driven reconnect
/// - bounded exponential backoff via `ReconnectPolicy` (no infinite loop)
/// - duplicate `connect` to an already-live URL is a no-op
/// - safe shutdown invalidates loops before cancelling the task
///
/// Concurrency: the whole manager is `@MainActor`-isolated — no locks needed,
/// race conditions prevented by actor serialization. All callers (services,
/// views) already run on `MainActor`.
public protocol WebSocketManager: AnyObject {
    var connectionState: ConnectionState { get }
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { get }
    var incomingText: AnyPublisher<String, Never> { get }

    func connect(url: URL)
    func disconnect()
    func send(text: String) async throws
    func send(data: Data) async throws
    func ping() async throws
}

public extension WebSocketManager {
    func send(data: Data) async throws {
        throw NetworkError.webSocket("Binary frames are reserved for future audio.")
    }

    func ping() async throws {
        throw NetworkError.webSocket("Not connected.")
    }
}

@MainActor
public final class URLSessionWebSocketManager: ObservableObject, WebSocketManager {

    @Published public private(set) var state: ConnectionState = .disconnected

    public var connectionState: ConnectionState { state }
    public var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        $state.eraseToAnyPublisher()
    }
    public var incomingText: AnyPublisher<String, Never> {
        incomingSubject.eraseToAnyPublisher()
    }

    /// Bounded backoff policy (injected from `BackendConfig` by the app).
    public var reconnectPolicy: ReconnectPolicy = .default
    /// Keepalive interval while connected.
    public var pingInterval: TimeInterval = 30

    /// Diagnostics (all MainActor-isolated, real values only):
    public private(set) var reconnectCount: Int = 0
    public private(set) var lastConnectedAt: Date?
    /// Last successful ping round-trip, seconds. Nil until the first pong.
    public private(set) var lastPingLatency: TimeInterval?

    private let incomingSubject = PassthroughSubject<String, Never>()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession = .shared
    private var receiveLoop: Task<Void, Never>?
    private var reconnectWork: Task<Void, Never>?
    private var pingWork: Task<Void, Never>?
    private var attempt: Int = 0
    private var lastURL: URL?
    private var manualDisconnect = false
    /// Invalidates stale loops/tasks on every connect/disconnect.
    private var generation = 0

    public init() {}

    public func connect(url: URL) {
        // No duplicate sockets: already live on this URL → no-op.
        if lastURL == url, task != nil,
           state == .connected || state == .connecting {
            ZyraxisLogger.log(.websocket, "connect: already live, ignoring duplicate")
            return
        }
        manualDisconnect = false
        lastURL = url
        attempt = 0
        generation += 1
        openSocket(url: url, generation: generation)
    }

    public func disconnect() {
        manualDisconnect = true
        generation += 1 // stale loops exit on their next check
        reconnectWork?.cancel()
        reconnectWork = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        pingWork?.cancel()
        pingWork = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
        ZyraxisLogger.log(.websocket, "disconnected (manual)")
    }

    public func send(text: String) async throws {
        guard let task else { throw NetworkError.webSocket("Not connected.") }
        do {
            try await task.send(.string(text))
        } catch {
            await handleFailure(error)
            throw NetworkError.webSocket(error.localizedDescription)
        }
    }

    public func send(data: Data) async throws {
        guard let task else { throw NetworkError.webSocket("Not connected.") }
        do {
            try await task.send(.data(data))
        } catch {
            await handleFailure(error)
            throw NetworkError.webSocket(error.localizedDescription)
        }
    }

    /// Active liveness probe. Failure drives the reconnect path.
    /// Records the round-trip time for DEBUG diagnostics.
    public func ping() async throws {
        guard let task, state == .connected else {
            throw NetworkError.webSocket("Not connected.")
        }
        let start = ContinuousClock().now
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
            }
            let elapsed = start.duration(to: ContinuousClock().now)
            let comps = elapsed.components
            lastPingLatency = Double(comps.seconds) + Double(comps.attoseconds) / 1e18
        } catch {
            await handleFailure(error)
            throw NetworkError.webSocket(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func openSocket(url: URL, generation gen: Int) {
        // Tear down previous generation first: never two sockets/loops.
        receiveLoop?.cancel()
        receiveLoop = nil
        pingWork?.cancel()
        pingWork = nil
        task?.cancel()
        task = nil

        state = attempt == 0 ? .connecting : .reconnecting(attempt: attempt)
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        // Optimistic: URLSessionWebSocketTask has no connected callback.
        // The receive loop + ping keepalive correct this on any failure.
        state = .connected
        lastConnectedAt = Date()
        ZyraxisLogger.log(.websocket, "socket opened (attempt \(attempt))")
        startReceiveLoop(generation: gen)
        startPingLoop(generation: gen)
    }

    private func startReceiveLoop(generation gen: Int) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, gen == self.generation, let task = self.task else { return }
                do {
                    let msg = try await task.receive()
                    guard gen == self.generation, !Task.isCancelled else { return }
                    switch msg {
                    case .string(let s):
                        self.incomingSubject.send(s)
                    case .data:
                        // Reserved for future audio frames. Ignored in Phase 2.
                        continue
                    @unknown default:
                        continue
                    }
                } catch {
                    // task.receive() throws on cancellation too — only reconnect
                    // when this loop is still the live generation.
                    if Task.isCancelled || gen != self.generation { return }
                    await self.handleFailure(error)
                    return
                }
            }
        }
    }

    private func startPingLoop(generation gen: Int) {
        pingWork?.cancel()
        pingWork = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.pingInterval ?? 30) * 1_000_000_000))
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                guard self.state == .connected, !self.manualDisconnect else { return }
                do {
                    try await self.ping()
                } catch {
                    // ping() already routed to handleFailure.
                    return
                }
            }
        }
    }

    private func handleFailure(_ error: Error) async {
        let gen = generation
        guard !manualDisconnect else {
            state = .disconnected
            return
        }
        attempt += 1
        reconnectCount += 1
        if attempt > reconnectPolicy.maxAttempts {
            state = .failed(NetworkError.webSocket(error.localizedDescription).localizedDescription)
            ZyraxisLogger.error(.websocket, "reconnect budget exhausted after \(attempt - 1) attempts")
            return
        }
        state = .reconnecting(attempt: attempt)
        let delay = reconnectPolicy.delay(forAttempt: attempt)
        ZyraxisLogger.log(.websocket, "reconnect attempt \(attempt) in \(String(format: "%.1f", delay))s")
        reconnectWork?.cancel()
        reconnectWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled,
                  !self.manualDisconnect, gen == self.generation,
                  let url = self.lastURL else { return }
            self.openSocket(url: url, generation: gen)
        }
        await reconnectWork?.value
    }
}
