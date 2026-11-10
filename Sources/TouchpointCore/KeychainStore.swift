import Foundation
import Security

/// Keychain accessibility classes the SDK is allowed to use.
public enum KeychainAccessibility: Sendable, Equatable {
    /// Readable only while the device is unlocked; never migrates to another device or backup.
    case whenUnlockedThisDeviceOnly

    var secAttr: CFString {
        switch self {
        case .whenUnlockedThisDeviceOnly: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}

/// Every platform dependency sits behind a protocol so Core is testable with no device.
public protocol KeychainStore: Sendable {
    func get(_ key: String) async throws -> Data?
    func set(_ value: Data, for key: String, accessibility: KeychainAccessibility) async throws
    func delete(_ key: String) async throws
}

/// The real thing: generic-password items under one service name, namespaced so a host app's own
/// keychain items are never touched.
public struct SecurityFrameworkKeychainStore: KeychainStore {
    public let service: String

    public init(service: String = "com.amazon.connect.touchpoint") {
        self.service = service
    }

    private func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
    }

    public func get(_ key: String) async throws -> Data? {
        var q = query(key)
        q[kSecReturnData] = kCFBooleanTrue
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        default: throw TouchpointError.persistenceFailure("keychain read failed: \(status)")
        }
    }

    public func set(_ value: Data, for key: String, accessibility: KeychainAccessibility) async throws {
        try await delete(key)
        var q = query(key)
        q[kSecValueData] = value
        q[kSecAttrAccessible] = accessibility.secAttr
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TouchpointError.persistenceFailure("keychain write failed: \(status)")
        }
    }

    public func delete(_ key: String) async throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TouchpointError.persistenceFailure("keychain delete failed: \(status)")
        }
    }
}

/// Test double. Records the accessibility class each write asked for so tests can assert it.
public actor InMemoryKeychainStore: KeychainStore {
    private var items: [String: (Data, KeychainAccessibility)] = [:]

    public init() {}

    public func get(_ key: String) async throws -> Data? { items[key]?.0 }

    public func set(_ value: Data, for key: String, accessibility: KeychainAccessibility) async throws {
        items[key] = (value, accessibility)
    }

    public func delete(_ key: String) async throws { items[key] = nil }

    public func allAccessibility() -> [KeychainAccessibility] { items.values.map(\.1) }
}
