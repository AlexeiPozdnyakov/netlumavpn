import Foundation
import Security

protocol SecureValueStorage {
    func save<T: Encodable>(_ value: T, account: String) throws
    func load<T: Decodable>(_ type: T.Type, account: String) throws -> T?
    func delete(account: String) throws
}

enum KeychainStorageError: LocalizedError {
    case encodeFailed
    case decodeFailed
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodeFailed:
            "Could not encode secure profile data."
        case .decodeFailed:
            "Could not decode secure profile data."
        case .unexpectedStatus(let status):
            "Keychain operation failed with status \(status)."
        }
    }
}

struct KeychainStorage {
    private let service: String
    private let accessGroup: String?

    init(
        service: String = AppConstants.Keychain.service,
        accessGroup: String? = AppConstants.keychainAccessGroup
    ) {
        self.service = service
        self.accessGroup = accessGroup?.nilIfBlank
    }

    func save<T: Encodable>(_ value: T, account: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw KeychainStorageError.encodeFailed
        }
        try save(data: data, account: account)
    }

    func load<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        guard let data = try loadData(account: account) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw KeychainStorageError.decodeFailed
        }
    }

    func delete(account: String) throws {
        var firstError: Error?
        for accessGroup in accessGroupCandidates {
            var query = baseQuery(account: account, accessGroup: accessGroup)
            query[kSecClass as String] = kSecClassGenericPassword

            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                continue
            }
            if firstError == nil {
                firstError = KeychainStorageError.unexpectedStatus(status)
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private func save(data: Data, account: String) throws {
        var firstError: Error?

        for accessGroup in accessGroupCandidates {
            do {
                try delete(account: account, accessGroup: accessGroup)

                var item = baseQuery(account: account, accessGroup: accessGroup)
                item[kSecClass as String] = kSecClassGenericPassword
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

                let status = SecItemAdd(item as CFDictionary, nil)
                guard status == errSecSuccess else {
                    throw KeychainStorageError.unexpectedStatus(status)
                }

                if accessGroup == nil {
                    AppLogger.warning("Keychain saved without shared access group; check Keychain Sharing entitlements before testing the tunnel extension", category: .storage)
                }
                return
            } catch {
                if firstError == nil {
                    firstError = error
                }
                AppLogger.warning("Keychain save retry needed: \(error.localizedDescription)", category: .storage)
            }
        }

        throw firstError ?? KeychainStorageError.unexpectedStatus(errSecInternalError)
    }

    private func delete(account: String, accessGroup: String?) throws {
        var query = baseQuery(account: account, accessGroup: accessGroup)
        query[kSecClass as String] = kSecClassGenericPassword

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStorageError.unexpectedStatus(status)
        }
    }

    private func loadData(account: String) throws -> Data? {
        var firstError: Error?

        for accessGroup in accessGroupCandidates {
            var query = baseQuery(account: account, accessGroup: accessGroup)
            query[kSecClass as String] = kSecClassGenericPassword
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                continue
            }
            guard status == errSecSuccess else {
                if firstError == nil {
                    firstError = KeychainStorageError.unexpectedStatus(status)
                }
                continue
            }
            return result as? Data
        }

        if let firstError {
            throw firstError
        }
        return nil
    }

    private var accessGroupCandidates: [String?] {
        if let accessGroup {
            [accessGroup, nil]
        } else {
            [nil]
        }
    }

    private func baseQuery(account: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        return query
    }
}

extension KeychainStorage: SecureValueStorage {}
