import Foundation
import Security

public protocol SecretStore: Sendable {
    func save(_ value: String, service: String, account: String) async throws
    func load(service: String, account: String) async throws -> String?
    func delete(service: String, account: String) async throws
}

public enum KeychainError: Error, LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): "Keychain error \(status)."
        case .invalidData: "The saved secret could not be decoded."
        }
    }
}

public final class KeychainStore: SecretStore {
    /// Keychain service under which provider API keys are stored.
    public static let providerAPIKeyService = "Zhiyin.ProviderAPIKey"

    private let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    /// S6: update-in-place instead of delete-then-add. The old
    /// sequence had a window where the key did not exist at all
    /// (killed app or interleaved concurrent save = lost key).
    /// `SecItemUpdate` on a missing item returns
    /// `errSecItemNotFound`, which is when we fall back to Add.
    public func save(_ value: String, service: String, account: String) async throws {
        let data = Data(value.utf8)
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unexpectedStatus(updateStatus) }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func load(service: String, account: String) async throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    public func delete(service: String, account: String) async throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if let accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

/// Provider API keys (DeepSeek etc.) in the keychain, service
/// `Zhiyin.ProviderAPIKey`, account = provider profile id.
/// M1: before this there was no UI anywhere that saved a key under
/// this service — only loads — so the app could never call DeepSeek
/// after install. Keys are trimmed before saving: a pasted key with
/// a trailing newline would otherwise break the Authorization header.
public enum ProviderKeyStore {
    public static func normalized(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    public static func loadKey(profileID: String) async -> String? {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        guard let key = try? await keychain.load(service: KeychainStore.providerAPIKeyService, account: profileID),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return key
    }

    /// S6: throwing variant — `load` already returns nil only for
    /// `errSecItemNotFound` and throws on a real keychain failure,
    /// but the `try?` in `loadKey` collapses that into "not
    /// configured". Callers that show a configured/not-configured
    /// state use this so a keychain fault reads "钥匙串读取失败"
    /// instead of "未配置".
    public static func loadKeyThrowing(profileID: String) async throws -> String? {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        guard let key = try await keychain.load(service: KeychainStore.providerAPIKeyService, account: profileID),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return key
    }

    public static func saveKey(_ raw: String, profileID: String) async throws {
        guard let key = normalized(raw) else { return }
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        try await keychain.save(key, service: KeychainStore.providerAPIKeyService, account: profileID)
    }

    public static func hasKey(profileID: String) async -> Bool {
        await loadKey(profileID: profileID) != nil
    }

    public static func deleteKey(profileID: String) async throws {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        try await keychain.delete(service: KeychainStore.providerAPIKeyService, account: profileID)
    }
}

public enum KeychainAccessGroup {
    public static func make(appIdentifierPrefix: String) -> String? {
        let prefix = appIdentifierPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return nil }
        return prefix + RunseConstants.keychainAccessGroup
    }

    public static func current(bundle: Bundle = .main) -> String? {
        guard let prefix = bundle.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty else {
            return nil
        }
        return make(appIdentifierPrefix: prefix)
    }
}

public actor InMemorySecretStore: SecretStore {
    private var storage: [String: String] = [:]

    public init() {}

    public func save(_ value: String, service: String, account: String) {
        storage[key(service: service, account: account)] = value
    }

    public func load(service: String, account: String) -> String? {
        storage[key(service: service, account: account)]
    }

    public func delete(service: String, account: String) {
        storage.removeValue(forKey: key(service: service, account: account))
    }

    private func key(service: String, account: String) -> String {
        "\(service)::\(account)"
    }
}
