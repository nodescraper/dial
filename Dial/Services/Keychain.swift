import Foundation
import Security

/// Stores short secrets (the Jellyfin access token) in the iOS Keychain.
enum Keychain {
    private static let service = "dial"

    /// On the Mac, a Keychain item belongs to the app's exact signature, so a rebuilt or updated copy cannot read what the
    /// last one saved and you are signed out at every start. The Mac keeps its own copy in the app's sandbox, which stays.
    private static func mirrorKey(_ key: String) -> String { "dial.mac.secret." + key }

    static func set(_ value: String, for key: String) {
        #if targetEnvironment(macCatalyst)
        UserDefaults.standard.set(value, forKey: mirrorKey(key))
        #endif
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            // Readable after the first unlock, so playback can continue in the background after a restart.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        #if targetEnvironment(macCatalyst)
        return UserDefaults.standard.string(forKey: mirrorKey(key))
        #else
        return nil
        #endif
    }

    static func delete(_ key: String) {
        #if targetEnvironment(macCatalyst)
        UserDefaults.standard.removeObject(forKey: mirrorKey(key))
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
