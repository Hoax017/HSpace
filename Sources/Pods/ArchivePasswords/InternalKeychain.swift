import Foundation
import HSpaceContracts
import Security

// Private concern: one generic password item, through the Security framework.
// The data protection Keychain needs an entitlement the app does not have, so this uses the login Keychain.
// Its access list names the signing identity of the app that wrote the item: after a rebuild with an ad-hoc signature,
// macOS asks once more before it hands the item over. Errors carry the system's message, never the data.

extension KeychainSecretStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func readItem() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.failure(status) }
        guard let data = result as? Data else {
            throw PasswordListError(.external, "The Keychain returned no data")
        }
        return data
    }

    func writeItem(_ data: Data) throws {
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            item[kSecAttrLabel as String] = "HSpace archive passwords"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.failure(status) }
    }

    func deleteItem() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
    }

    private static func failure(_ status: OSStatus) -> PasswordListError {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return PasswordListError(.external, "Keychain: \(reason)")
    }
}
