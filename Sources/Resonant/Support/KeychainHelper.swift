import Foundation
import Security

struct KeychainAuthSession: Codable, Equatable {
    var authToken: String?
    var cloudAuthToken: String?
    var refreshToken: String?

    var isEmpty: Bool {
        authToken == nil && cloudAuthToken == nil && refreshToken == nil
    }
}

enum KeychainHelper {

    private static let authSessionKey = "authSession"

    private static var service: String {
        AppRuntime.keychainServiceName
    }

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return save(key: key, data: data)
    }

    @discardableResult
    static func saveAuthSession(_ session: KeychainAuthSession?) -> Bool {
        guard let session else {
            return delete(key: authSessionKey)
        }

        guard !session.isEmpty,
              let data = try? JSONEncoder().encode(session) else {
            return false
        }

        return save(key: authSessionKey, data: data)
    }

    private static func save(key: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func read(key: String) -> String? {
        guard let data = readData(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func readAuthSession() -> KeychainAuthSession? {
        guard let data = readData(key: authSessionKey) else { return nil }
        return try? JSONDecoder().decode(KeychainAuthSession.self, from: data)
    }

    private static func readData(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return data
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
