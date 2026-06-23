import Foundation

struct GlobalServerDeviceIdentityStore {
    private let secureValueStorage: any SecureValueStorage
    private let account: String
    private let idGenerator: () -> String

    init(
        keychainStorage: any SecureValueStorage = KeychainStorage(),
        account: String = AppConstants.Keychain.globalServerDeviceIDAccount,
        idGenerator: @escaping () -> String = { UUID().uuidString }
    ) {
        self.secureValueStorage = keychainStorage
        self.account = account
        self.idGenerator = idGenerator
    }

    func deviceID() throws -> String {
        if let existing = try secureValueStorage.load(String.self, account: account),
           existing.nilIfBlank != nil {
            return existing
        }

        let generated = idGenerator()
        try secureValueStorage.save(generated, account: account)
        return generated
    }
}
