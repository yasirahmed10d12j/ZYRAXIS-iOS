//
//  RemoteDesktopService.swift
//  ZYRAXIS-iOS
//
//  Remote Desktop client for iOS.
//  Connects to the ZYRAXIS hub via WebSocket, receives screen frames from
//  the paired desktop, and forwards touch/mouse/keyboard input back.
//

import Foundation
import Combine
import UIKit

public struct RemoteInputEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case key      = "key"
        case mouse    = "mouse"
    }

    /// Hub protocol version — the relay rejects frames without it.
    public let version: Int
    public let type: String
    public let requestId: String
    public let payload: Payload

    public struct Payload: Codable, Sendable {
        public let sessionKey: String
        public let kind: Kind
        public let key: String?
        public let x: Int?
        public let y: Int?
        public let button: String?
        public let doubleClick: Bool?
        public let scrollX: Int?
        public let scrollY: Int?
        /// Drag state: true = button held (drag), false = release.
        /// nil = plain tap / move.
        public let down: Bool?
    }

    public init(sessionKey: String, kind: Kind, key: String? = nil,
                x: Int? = nil, y: Int? = nil, button: String? = nil,
                doubleClick: Bool? = nil, scrollX: Int? = nil, scrollY: Int? = nil,
                down: Bool? = nil) {
        self.version = 1
        self.type = "remote-desktop-input"
        self.requestId = UUID().uuidString
        self.payload = Payload(sessionKey: sessionKey, kind: kind, key: key,
                               x: x, y: y, button: button,
                               doubleClick: doubleClick,
                               scrollX: scrollX, scrollY: scrollY, down: down)
    }
}

@MainActor
public final class RemoteDesktopService: ObservableObject {

    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(sessionKey: String)
        case error(String)
    }

    @Published public var state: ConnectionState = .disconnected
    @Published public var currentFrame: UIImage? = nil

    private let api: any APIClient
    private let auth: any BackendAuthProvider
    private let configProvider: () -> BackendConfig
    private let webSocket: URLSessionWebSocketManager
    private var cancellables = Set<AnyCancellable>()
    private var keepaliveTask: Task<Void, Never>?

    public init(
        api: any APIClient,
        auth: any BackendAuthProvider,
        configProvider: @escaping () -> BackendConfig,
        webSocket: URLSessionWebSocketManager
    ) {
        self.api = api
        self.auth = auth
        self.configProvider = configProvider
        self.webSocket = webSocket

        webSocket.incomingText
            .sink { [weak self] raw in
                Task { [weak self] in
                    await self?.handleIncoming(raw)
                }
            }
            .store(in: &cancellables)
    }

    public func connect(sessionKey: String) async throws {
        let config = configProvider()
        guard config.isConfigured else {
            state = .error("Backend not configured. Set backend URL in Settings.")
            throw NetworkError.transport("Backend not configured")
        }
        guard let key = try? auth.bearerToken(), !key.isEmpty else {
            state = .error("Unauthorized")
            throw NetworkError.unauthorized
        }
        guard let wsURL = config.websocketURL else {
            state = .error("WebSocket URL not configured")
            throw NetworkError.transport("WebSocket URL not configured")
        }

        state = .connecting

        webSocket.connect(url: wsURL)

        let announce: [String: Any] = [
            "version": 1,
            "type": "remote-desktop-announce",
            "requestId": UUID().uuidString,
            "payload": [
                "deviceId": UIDevice.current.identifierForVendor?.uuidString ?? "",
                "sessionKey": sessionKey
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: announce),
              let text = String(data: data, encoding: .utf8) else {
            state = .error("Failed to encode announce frame")
            throw NetworkError.transport("Failed to encode announce frame")
        }
        // The shared socket may still be opening (or reconnecting); this
        // announce is what registers the phone on the hub, so retry briefly
        // instead of failing the first frame.
        var lastError: Error?
        for _ in 0..<20 {
            do {
                try await webSocket.send(text: text)
                lastError = nil
                break
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        if let lastError {
            state = .error("Failed to send announce: \(lastError.localizedDescription)")
            throw lastError
        }

        state = .connected(sessionKey: sessionKey)
        startKeepalive(sessionKey: sessionKey)
    }

    // The laptop only streams while a phone is actually watching: it stops
    // capturing when no input arrives for ~25s, and this ping keeps it alive
    // while the viewer is open (and stops by itself when iOS suspends us).
    private func startKeepalive(sessionKey: String) {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            // Ping first (marks the phone as "watching" immediately so the
            // desktop starts streaming without a 10s wait), then every 10s.
            while !Task.isCancelled {
                guard let self, case .connected(let key) = self.state, key == sessionKey else { return }
                // No position/scroll => the desktop treats it as a no-op ping.
                try? await self.sendInput(RemoteInputEvent(sessionKey: sessionKey, kind: .mouse))
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    public func disconnect() {
        stopKeepalive()
        webSocket.disconnect()
        state = .disconnected
        currentFrame = nil
    }

    /// Leave the remote desktop session WITHOUT tearing down the socket —
    /// the app shares that socket with chat/voice, so closing the viewer
    /// must not kill everything else. Stale frames are dropped by the
    /// `.connected` guard in handleIncoming.
    public func endSession() {
        stopKeepalive()
        state = .disconnected
        currentFrame = nil
    }

    public func sendInput(_ event: RemoteInputEvent) async throws {
        guard case .connected = state else {
            throw NetworkError.transport("Not connected to hub")
        }
        do {
            let data = try JSONEncoder().encode(event)
            let text = String(data: data, encoding: .utf8)!
            try await webSocket.send(text: text)
        } catch {
            throw NetworkError.transport("Failed to send input: \(error.localizedDescription)")
        }
    }

    private func handleIncoming(_ raw: String) async {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "remote-desktop-screen",
              let payload = json["payload"] as? [String: Any],
              let sessionKey = payload["sessionKey"] as? String,
              let frameB64 = payload["frameB64"] as? String
        else {
            return
        }

        guard case .connected(let currentKey) = state, sessionKey == currentKey else {
            return
        }

        guard let imageData = Data(base64Encoded: frameB64),
              let image = UIImage(data: imageData) else {
            return
        }

        await MainActor.run {
            self.currentFrame = image
        }
    }
}