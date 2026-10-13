import Foundation

/// Backend endpoint configuration. No API keys live here — see KeychainService.
///
/// Source of truth is `SettingsStore` (persisted via UserDefaults).
/// This struct is a validated snapshot used by APIClient / WebSocketManager.
///
/// Phase 2: supports dev + production HTTP URLs, the WebSocket URL, API
/// versioning, connection/request timeouts and the reconnect policy.
/// `baseURL` remains the ACTIVE HTTP URL (resolved from the environment).
public struct BackendConfig: Equatable, Sendable {
    /// Active HTTP API base (nil = unconfigured).
    public var baseURL: URL?
    public var websocketURL: URL?
    public var requestTimeout: TimeInterval
    /// Development HTTP base (used when environment == .development).
    public var developmentBaseURL: URL?
    /// Production HTTP base (normally mirrors `baseURL`).
    public var productionBaseURL: URL?
    /// API version segment, e.g. "v1" → `/api/v1/chat`.
    public var apiVersion: String
    public var connectionTimeout: TimeInterval
    public var reconnectPolicy: ReconnectPolicy

    /// Placeholder shown in Settings before the user configures a backend.
    public static let placeholderBaseURL = "https://your-zyraxis-backend.example.com"
    public static let placeholderWebSocketURL = "wss://your-zyraxis-backend.example.com/live"

    public static let `default` = BackendConfig(
        baseURL: nil,
        websocketURL: nil,
        requestTimeout: 30
    )

    /// Phase 1-compatible init. New fields take safe defaults.
    public init(baseURL: URL?, websocketURL: URL?, requestTimeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.websocketURL = websocketURL
        self.requestTimeout = requestTimeout
        self.developmentBaseURL = nil
        self.productionBaseURL = baseURL
        self.apiVersion = "v1"
        self.connectionTimeout = 10
        self.reconnectPolicy = .default
    }

    public init(
        baseURL: URL?,
        websocketURL: URL?,
        requestTimeout: TimeInterval = 30,
        developmentBaseURL: URL? = nil,
        productionBaseURL: URL? = nil,
        apiVersion: String = "v1",
        connectionTimeout: TimeInterval = 10,
        reconnectPolicy: ReconnectPolicy = .default
    ) {
        self.baseURL = baseURL
        self.websocketURL = websocketURL
        self.requestTimeout = requestTimeout
        self.developmentBaseURL = developmentBaseURL
        self.productionBaseURL = productionBaseURL ?? baseURL
        self.apiVersion = apiVersion
        self.connectionTimeout = connectionTimeout
        self.reconnectPolicy = reconnectPolicy
    }

    /// Lenient parser: empty string -> nil (unconfigured), otherwise must be http(s).
    public static func parseBaseURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    /// Lenient parser: empty string -> nil, otherwise must be ws(s).
    public static func parseWebSocketURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws" else { return nil }
        return url
    }

    public var isConfigured: Bool { baseURL != nil }
}
