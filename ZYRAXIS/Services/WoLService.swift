import Foundation

/// A named Wake-on-LAN target — e.g. "Home PC", "Office PC", "School PC".
///
/// Each profile keeps its own MAC and optional subnet broadcast address, so a
/// single ZYRAXIS hub can power on several machines.
public struct WoLProfile: Codable, Identifiable, Equatable, Sendable {
    public let name: String
    public let mac: String
    public let broadcast: String

    public var id: String { name }

    public init(name: String, mac: String, broadcast: String = "255.255.255.255") {
        self.name = name
        self.mac = mac
        self.broadcast = broadcast
    }
}

/// Wake-on-LAN service for the iOS client.
///
/// Sends magic packets to power on machines through the user's own ZYRAXIS
/// hub. Targets are named, so several PCs can be configured side by side:
///   1. `configure(_:)`      → POST /api/wol/config  (upsert by name)
///   2. `removeProfile(...)` → DELETE /api/wol/config/{name}
///   3. `wake(name:)`        → POST /api/wol/wake    (wake one named target)
///
/// Honest limits (see backend README):
/// - WoL works best over Ethernet; Wi-Fi WoL varies by laptop.
/// - The target PC must be plugged into AC power and have WoL enabled in
///   BIOS + Windows network adapter settings.
/// - The hub that fires the packet must sit on the same LAN as the target.
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

    // MARK: - Configure (upsert a named target on the hub)

    /// Upserts a named profile on the hub.
    public func configure(_ profile: WoLProfile) async throws {
        try await configure(name: profile.name, mac: profile.mac, broadcast: profile.broadcast)
    }

    /// Upserts a named target on the hub so `wake(name:)` can fire a packet
    /// without re-typing the MAC.
    public func configure(
        name: String,
        mac: String,
        broadcast: String = "255.255.255.255"
    ) async throws {
        let config = try requireConfig()
        let key = try requireToken()

        let body = try JSONEncoder().encode([
            "name": name,
            "mac": mac,
            "broadcastAddress": broadcast,
            "port": "9"
        ])
        let path = "/api/\(config.apiVersion)/wol/config"
        var request = try api.makeRequest(
            path: path,
            method: "POST",
            body: body,
            headers: [:]
        )
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        ZyraxisLogger.log(.ai, "POST wol/config name=\(name) mac=\(mac)")
        let (_, http) = try await api.sendData(request)
        lastStatus = "Configured (HTTP \(http.statusCode))"
        lastError = nil
    }

    /// Legacy single-target convenience: stores the MAC under the name
    /// "Default" on the hub. Prefer `configure(_:)` for multiple PCs.
    public func configure(mac: String, broadcast: String = "255.255.255.255") async throws {
        try await configure(name: "Default", mac: mac, broadcast: broadcast)
    }

    // MARK: - Remove

    /// Removes a named target from the hub.
    public func removeProfile(named name: String) async throws {
        let config = try requireConfig()
        let key = try requireToken()

        let path = "/api/\(config.apiVersion)/wol/config/\(Self.encodePathSegment(name))"
        var request = try api.makeRequest(
            path: path,
            method: "DELETE",
            body: nil,
            headers: [:]
        )
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        ZyraxisLogger.log(.ai, "DELETE wol/config name=\(name)")
        let (_, http) = try await api.sendData(request)
        lastStatus = "Removed \"\(name)\" (HTTP \(http.statusCode))"
        lastError = nil
    }

    // MARK: - Wake

    /// Sends a magic packet for the named target.
    public func wake(name: String) async throws {
        let config = try requireConfig()
        let key = try requireToken()

        let body = try JSONEncoder().encode(["name": name])
        let path = "/api/\(config.apiVersion)/wol/wake"
        var request = try api.makeRequest(
            path: path,
            method: "POST",
            body: body,
            headers: [:]
        )
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        ZyraxisLogger.log(.ai, "POST wol/wake name=\(name)")
        let (_, http) = try await api.sendData(request)
        lastStatus = "Magic packet sent (HTTP \(http.statusCode))"
        lastError = nil
    }

    /// Re-upserts the profile on the hub, then wakes it. Keeps working after a
    /// hub restart (the hub's profile list is in-memory).
    public func wake(_ profile: WoLProfile) async throws {
        try await configure(profile)
        try await wake(name: profile.name)
    }

    /// Legacy wake without a name — wakes the hub's first/default target.
    public func wake() async throws {
        let config = try requireConfig()
        let key = try requireToken()

        let path = "/api/\(config.apiVersion)/wol/wake"
        var request = try api.makeRequest(
            path: path,
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

    // MARK: - Helpers

    private func requireConfig() throws -> BackendConfig {
        let config = configProvider()
        guard config.isConfigured else {
            throw NetworkError.transport("Backend not configured. Set the backend URL in Settings.")
        }
        return config
    }

    private func requireToken() throws -> String {
        guard let key = try? auth.bearerToken(), !key.isEmpty else {
            throw NetworkError.unauthorized
        }
        return key
    }

    /// Percent-encodes a value for safe use as a single URL path segment
    /// (profile names may contain spaces, e.g. "Office PC").
    nonisolated static func encodePathSegment(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
