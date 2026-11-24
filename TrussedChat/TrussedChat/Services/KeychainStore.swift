import Foundation
import Security

enum KeychainStore {
    private static let service = "edu.fau.TrussedChat"
    private static let legacyAccount = "TRUSSED_API_KEY"
    private static let legacyFallbackKey = "trussed.simulatorFallbackAPIKey"

    static func loadAPIKey(for provider: LLMProvider) -> String? {
        if let value = load(account: provider.envKeyName, fallbackKey: fallbackKey(for: provider)) {
            return value
        }
        if provider == .faullm {
            return load(account: legacyAccount, fallbackKey: legacyFallbackKey)
        }
        return nil
    }

    @discardableResult
    static func saveAPIKey(_ key: String, for provider: LLMProvider) -> Bool {
        deleteAPIKey(for: provider)

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.envKeyName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        }

        // Unsigned iOS Simulator builds can return errSecMissingEntitlement (-34018).
        UserDefaults.standard.set(trimmed, forKey: fallbackKey(for: provider))
        return true
    }

    @discardableResult
    static func deleteAPIKey(for provider: LLMProvider) -> Bool {
        UserDefaults.standard.removeObject(forKey: fallbackKey(for: provider))
        let ok = delete(account: provider.envKeyName)
        if provider == .faullm {
            UserDefaults.standard.removeObject(forKey: legacyFallbackKey)
            _ = delete(account: legacyAccount)
        }
        return ok
    }

    private static func fallbackKey(for provider: LLMProvider) -> String {
        "trussed.simulatorFallbackAPIKey.\(provider.rawValue)"
    }

    private static func load(account: String, fallbackKey: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }

        if let fallback = UserDefaults.standard.string(forKey: fallbackKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty {
            return fallback
        }
        return nil
    }

    private static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
