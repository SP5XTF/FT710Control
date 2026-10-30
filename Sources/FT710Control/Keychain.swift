import Foundation
import Security

/// Hasła w pęku kluczy macOS (zamiast w zwykłych ustawieniach aplikacji).
enum Keychain {
    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    @discardableResult
    static func set(_ password: String, service: String, account: String) -> Bool {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
        var item = query(service: service, account: account)
        item[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func get(service: String, account: String) -> String? {
        var search = query(service: service, account: account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Czy wpis istnieje - bez odczytu samego hasła, więc macOS nie pyta o zgodę.
    static func exists(service: String, account: String) -> Bool {
        var search = query(service: service, account: account)
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess
    }

    static func delete(service: String, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }
}
