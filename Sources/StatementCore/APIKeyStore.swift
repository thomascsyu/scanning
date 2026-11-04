import Foundation
import Security
import LocalAuthentication

public struct APIKeyStore {
    private let service: String
    public init(service: String = "hk.local.StatementManager.DeepSeek") { self.service = service }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key", kSecAttrSynchronizable as String: false] }
    public func read() throws -> String {
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(lookup as CFDictionary, &item)
        if result == errSecItemNotFound { throw DeepSeekError.missingKey }
        guard result == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else { throw keychainError(result) }
        return key
    }
    public func containsKey() -> Bool {
        var lookup = query; lookup[kSecReturnAttributes as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne; let context = LAContext(); context.interactionNotAllowed = true; lookup[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(lookup as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
    public func save(_ value: String) throws {
        let key = try DeepSeekClient.validatedKey(value)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; attributes.forEach { insert[$0.key] = $0.value }; insert[kSecAttrLabel as String] = "Statement Manager — DeepSeek API key"
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw keychainError(result) }
        } else if status != errSecSuccess { throw keychainError(status) }
    }
    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }
    private func keychainError(_ status: OSStatus) -> LedgerError { .invalid("macOS Keychain could not access the API key (status \(status)). Unlock your login keychain and try again.") }
}
