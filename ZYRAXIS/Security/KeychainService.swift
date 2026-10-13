import Foundation
import Security

/// Keychain abstraction. All secrets (API keys, tokens) go through here.
/// Nothing sensitive is ever stored in UserDefaults or source code.
public protocol KeychainService: Sendable {
    func save(_ value: String, forKey key: String) throws
    func load(forKey key: String) throws -> String?
    func delete(forKey key: String) throws
}

public enum KeychainError: LocalizedError, Equatable {
    case encodingFailed
    case decodingFailed
    case unexpectedStatus(OSStatus)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Could not encode keychain value."
        case .decodingFailed: return "Could not decode keychain value."
        case .unexpectedStatus(let s): return "Keychain error (status \(s))."
        case .notFound: return "Keychain item not found."
        }
    }
}

/// Standard `Security.framework` implementation.
public struct SystemKeychainService: KeychainService, Sendable {

    private let service: String

    public init(service: String = "com.zyraxis.ios") {
        self.service = service
    }

    public func save(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func load(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return string
    }

    public func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// Well-known secret keys (key names only — never values).
public enum KeychainKeys {
    public static let backendAPIKey = "zyraxis.backend.apiKey"
    public static let realtimeToken = "zyraxis.realtime.token"
}
