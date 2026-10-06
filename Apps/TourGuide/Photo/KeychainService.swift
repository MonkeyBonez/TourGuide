import Foundation
import Security

/// The user's OpenAI key lives here and nowhere else (CLAUDE.md: no keys in the repo).
/// From PocketTourGuide's KeychainService, with delete and a Tour Guide account name.
enum KeychainService {
    private static let account = "com.monkeybonez.tourguide.openai"
    private static var base: [CFString: Any] { [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account] }

    static func saveAPIKey(_ value: String) {
        deleteAPIKey()
        guard !value.isEmpty else { return }
        var q = base
        q[kSecValueData] = Data(value.utf8)
        q[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func apiKey() -> String? {
        var q = base
        q[kSecReturnData] = true; q[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAPIKey() { SecItemDelete(base as CFDictionary) }
}
