import Foundation
import Security

enum KeychainStore {
    private static let service = "com.skim.app.auth"

    enum Key: String {
        case claudeAccessToken = "claude_access_token"
        case claudeRefreshToken = "claude_refresh_token"
        case claudeExpiresAt = "claude_expires_at"
        case anthropicApiKey = "anthropic_api_key"
        case openaiApiKey = "openai_api_key"
    }

    static func set(_ value: String?, for key: Key) {
        let account = key.rawValue
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(baseQuery as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    static func clearClaudeAuth() {
        set(nil, for: .claudeAccessToken)
        set(nil, for: .claudeRefreshToken)
        set(nil, for: .claudeExpiresAt)
    }
}
