import Foundation
@testable import QuickVPN

final class InMemorySecureValueStorage: SecureValueStorage {
    private var values: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func save<T: Encodable>(_ value: T, account: String) throws {
        values[account] = try encoder.encode(value)
    }

    func load<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        guard let data = values[account] else {
            return nil
        }
        return try decoder.decode(type, from: data)
    }

    func delete(account: String) throws {
        values[account] = nil
    }
}
