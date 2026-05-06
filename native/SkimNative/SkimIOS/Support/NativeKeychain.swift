import Foundation
import Security

// MARK: - Keychain helper

/// Minimal Keychain wrapper for storing, reading, and deleting string values
/// keyed by service + account.  Uses kSecClassGenericPassword with
/// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly so tokens survive device
/// reboots (background token refresh) but are never backed up off-device.
enum NativeKeychain {

    // MARK: Write

    @discardableResult
    static func set(_ value: String, service: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing entry first so SecItemAdd always succeeds.
        delete(service: service, account: account)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: Read

    static func get(service: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    // MARK: Delete

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
