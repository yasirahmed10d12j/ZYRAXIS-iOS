import Foundation

/// Wake-on-LAN service for the iOS client.
///
/// Sends magic packets to power on office desktops through the user's own
/// ZYRAXIS hub. Two-step flow:
///   1. `configure(mac:broadcast:)` → POST /api/wol/config (stores MAC on hub)
///   2. `wake()`                    → POST /api/wol/wake   (sends magic packet)
///
/// The MAC is also kept locally in SettingsStore so the hub can be
/// re-configured on subsequent launches without re-typing.
///
/// Honest limits (see backend README):
/// - WoL works best over Ethernet; Wi-Fi WoL varies by laptop.
/// - The target PC must be plugged into AC power and have WoL enabled in
///   BIOS + Windows network adapter settings.
/// - From outside the office LAN, a VPN or port-forwarded relay is required.
@MainActor
public final class WoLService {

    /// Last observed result for UI diagnostics.
    public internal(set) var lastStatus: String?
    public internal(set) var lastError: String?

    private let api: any APIClient
    private let auth: any BackendAuthProvider
    private let configProvider: () -> BackendConfig

    public init(
        api: any APIClient,
        auth: any BackendAuthProvider,
        configProvider: @escaping () -> BackendConfig
    ) {
        self.api = api
        self.auth = auth
        self.configProvider = configProvider
    }

    // MARK: - Configure (store MAC on hub)

    /// Persists the office desktop MAC on the ZYRAXIS hub so `/api/wol/wake`
    /// can fire the magic packet without re-typing it.
    public func configure(mac: String, broadcast: String = "255.255.255.255") async throws {
        let config = configProvider()
        guard config.isConfigured else {
            throw NetworkError.transport("Backend not configured. Set the backend URL in Settings.")
        }
        guard let key = try? auth.bearerToken(), !key.isEmpty else {
            throw NetworkError.unauthorized
        }

        let body = try JSONEncoder().encode([
            "mac": mac,
            "broadcastAddress": broadcast,
            "port": "9"
        ])
        var request = try api.makeRequest(
            path: "/api/wol/config",
            method: "POST",
            body: body,
            headers: [:]
        )
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        ZyraxisLogger.log(.ai, "POST wol/config mac=\(mac)")
        let (_, http) = try await api.sendData(request)
        lastStatus = "Configured (HTTP \(http.statusCode))"
        lastError = nil
    }

    // MARK: - Wake

    /// Sends the magic packet to power on the configured desktop.
    public func wake() async throws {
        let config = configProvider()
        guard config.isConfigured else {
            throw NetworkError.transport("Backend not configured. Set the backend URL in Settings.")
        }
        guard let key = try? auth.bearerToken(), !key.isEmpty else {
            throw NetworkError.unauthorized
        }

        var request = try api.makeRequest(
            path: "/api/wol/wake",
            method: "POST",
            body: nil,
            headers: [:]
        )
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        ZyraxisLogger.log(.ai, "POST wol/wake")
        let (_, http) = try await api.sendData(request)
        lastStatus = "Magic packet sent (HTTP \(http.statusCode))"
        lastError = nil
    }

    public func resetDiagnostics() {
        lastStatus = nil
        lastError = nil
    }
}
