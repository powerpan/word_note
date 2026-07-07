import Foundation
import Security

public enum KeychainStoreError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed with status \(status)."
        case .invalidData:
            return "Keychain item data is invalid."
        }
    }
}

public struct KeychainStore {
    public static let deepSeekAPIKey = KeychainStore(
        service: "com.powerpan.WordNote.deepseek",
        account: "api-key"
    )

    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func save(_ secret: String) throws {
        let data = Data(secret.utf8)
        try deleteIfExists()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    public func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainStoreError.invalidData
        }

        return value
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func deleteIfExists() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public enum DeepSeekAPIKeyResolver {
    public static let environmentVariableName = "DEEPSEEK_API_KEY"

    public static func resolve() -> String? {
        if let keychainValue = try? KeychainStore.deepSeekAPIKey.load(),
           !TextNormalizer.isBlank(keychainValue) {
            return keychainValue
        }

        let environmentValue = ProcessInfo.processInfo.environment[environmentVariableName]
        guard let environmentValue, !TextNormalizer.isBlank(environmentValue) else {
            return nil
        }
        return environmentValue
    }
}
