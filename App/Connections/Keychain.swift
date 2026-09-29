import Foundation
import Security

/// Passwords are stored in the Keychain, keyed by the connection's UUID. Never in SwiftData.
nonisolated enum Keychain {
    enum Kind: String, Sendable {
        case database = "db"
        case ssh = "ssh"
        case supabaseToken = "supabase"
    }

    private static let service = "dev.dbexplorer.DBExplorer"

    private static func account(_ id: UUID, _ kind: Kind) -> String { "\(id.uuidString).\(kind.rawValue)" }

    private static func baseQuery(_ id: UUID, _ kind: Kind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(id, kind)]
    }

    static func password(for id: UUID, kind: Kind = .database) -> String? {
        var query = baseQuery(id, kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setPassword(_ password: String?, for id: UUID, kind: Kind = .database) -> Bool {
        guard let password, !password.isEmpty else {
            delete(id, kind: kind)
            return true
        }
        let data = Data(password.utf8)
        let status = SecItemUpdate(baseQuery(id, kind) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(id, kind)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "DB Explorer connection password"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete(_ id: UUID, kind: Kind) {
        SecItemDelete(baseQuery(id, kind) as CFDictionary)
    }

    static func deleteAll(for id: UUID) {
        delete(id, kind: .database)
        delete(id, kind: .ssh)
        delete(id, kind: .supabaseToken)
    }
}

/// Trust-on-first-use store for SSH host keys.
nonisolated enum KnownHosts {
    private static let defaultsKey = "sshKnownHosts"

    static func validate(host: String, key: String) -> Bool {
        let defaults = UserDefaults.standard
        var known = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        if let existing = known[host] { return existing == key }
        known[host] = key
        defaults.set(known, forKey: defaultsKey)
        return true
    }

    static func forget(host: String) {
        let defaults = UserDefaults.standard
        var known = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        known[host] = nil
        defaults.set(known, forKey: defaultsKey)
    }
}
