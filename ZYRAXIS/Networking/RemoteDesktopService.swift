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
    }

    public init(sessionKey: String, kind: Kind, key: String? = nil,
                x: Int? = nil, y: Int? = nil, button: String? = nil,
                doubleClick: Bool? = nil, scrollX: Int? = nil, scrollY: Int? = nil) {
        self.type = "remote-desktop-input"
        self.requestId = UUID().uuidString
        self.payload = Payload(sessionKey: sessionKey, kind: kind, key: key,
                               x: x, y: y, button: button,
                               doubleClick: doubleClick,
                               scrollX: scrollX, scrollY: scrollY)
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

        do {
            try await webSocket.connect(url: wsURL!)
        } catch {
            state = .error("WebSocket connect failed: \(error.localizedDescription)")
            throw error
        }

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
        do {
            try await webSocket.send(text: text)
        } catch {
            state = .error("Failed to send announce: \(error.localizedDescription)")
            throw error
        }

        state = .connected(sessionKey: sessionKey)
    }

    public func disconnect() {
        webSocket.disconnect()
        state = .disconnected
        currentFrame = nil
    }

    public func sendInput(_ event: RemoteInputEvent) async throws {
        guard case .connected(let sessionKey) = state else {
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
              let frameB64 = payload["frameB64"] as? String,
              let width = payload["width"] as? Int,
              let height = payload["height"] as? Int
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
