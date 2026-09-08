import Foundation
import Security

public enum GLMCredentials {
    private static let service = "com.llmusage.glm"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "apiKey"]
    }

    public static func savedKey() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw CredentialError(status: status) }
        return key
    }

    public static func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError(status: status) }
            return
        }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError(status: status) }
    }

    /// Share the existing GLM credential source with quota monitoring.
    public static func load() throws -> String? {
        if let key = try savedKey() { return key }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/openusage/zai.json")
        if let data = try? Data(contentsOf: path),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = nonempty(root["apiKey"] as? String) { return key }
        for name in ["ZAI_API_KEY", "GLM_API_KEY"] {
            if let key = nonempty(ProcessInfo.processInfo.environment[name]) { return key }
        }
        return nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private struct CredentialError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain error (\(status))" }
    }
}
