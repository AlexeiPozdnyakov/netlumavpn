import Foundation

enum ProfileStorageError: LocalizedError {
    case profileNotFound
    case missingSecret
    case missingCredential(VPNProtocolType)
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            L10n.string("The selected VPN profile was not found.")
        case .missingSecret:
            L10n.string("Secure credentials for this profile are missing.")
        case .missingCredential(let protocolType):
            L10n.format("Required credential is missing for %@.", protocolType.title)
        case .persistenceFailed:
            L10n.string("Could not save VPN profiles.")
        }
    }
}

struct ProfileStorage {
    private let appGroupStorage: AppGroupStorage
    private let secureValueStorage: any SecureValueStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        appGroupStorage: AppGroupStorage = AppGroupStorage(),
        keychainStorage: any SecureValueStorage = KeychainStorage()
    ) {
        self.appGroupStorage = appGroupStorage
        self.secureValueStorage = keychainStorage
    }

    func loadProfiles() -> [VPNProfile] {
        guard let data = appGroupStorage.data(forKey: AppConstants.AppGroupKeys.profiles) else {
            return []
        }
        return (try? decoder.decode([VPNProfile].self, from: data)) ?? []
    }

    func saveProfile(_ profile: VPNProfile, secret: VPNProfileSecret) throws {
        try validate(secret: secret, for: profile.protocolType)
        AppLogger.info("Saving profile \(AppLogger.safeProfileLabel(profile))", category: .storage)

        var profiles = loadProfiles()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }

        try secureValueStorage.save(secret, account: profile.keychainAccount)
        do {
            try persist(profiles)
        } catch {
            try? secureValueStorage.delete(account: profile.keychainAccount)
            AppLogger.error(error, message: "Profile metadata save failed", category: .storage)
            throw error
        }
        AppLogger.info("Profile saved \(AppLogger.safeProfileLabel(profile))", category: .storage)
    }

    func deleteProfile(_ profile: VPNProfile) throws {
        AppLogger.info("Deleting profile \(AppLogger.safeProfileLabel(profile))", category: .storage)
        var profiles = loadProfiles()
        profiles.removeAll { $0.id == profile.id }
        try persist(profiles)
        try secureValueStorage.delete(account: profile.keychainAccount)

        if selectedProfileID() == profile.id {
            setSelectedProfileID(profiles.first?.id)
        }
        AppLogger.info("Profile deleted \(AppLogger.safeProfileLabel(profile))", category: .storage)
    }

    func secret(for profile: VPNProfile) throws -> VPNProfileSecret? {
        try secureValueStorage.load(VPNProfileSecret.self, account: profile.keychainAccount)
    }

    func selectedProfileID() -> UUID? {
        guard let value = appGroupStorage.string(forKey: AppConstants.AppGroupKeys.selectedProfileID) else {
            return nil
        }
        return UUID(uuidString: value)
    }

    func setSelectedProfileID(_ id: UUID?) {
        appGroupStorage.set(id?.uuidString, forKey: AppConstants.AppGroupKeys.selectedProfileID)
    }

    func resolvedProfile(id: UUID) throws -> ResolvedVPNProfile {
        guard let profile = loadProfiles().first(where: { $0.id == id }) else {
            throw ProfileStorageError.profileNotFound
        }
        guard let secret = try secret(for: profile) else {
            throw ProfileStorageError.missingSecret
        }
        try validate(secret: secret, for: profile.protocolType)
        return ResolvedVPNProfile(profile: profile, secret: secret)
    }

    private func persist(_ profiles: [VPNProfile]) throws {
        do {
            let data = try encoder.encode(profiles.sorted { $0.updatedAt > $1.updatedAt })
            appGroupStorage.set(data, forKey: AppConstants.AppGroupKeys.profiles)
        } catch {
            throw ProfileStorageError.persistenceFailed
        }
    }

    private func validate(secret: VPNProfileSecret, for protocolType: VPNProtocolType) throws {
        switch protocolType {
        case .vless, .vmess:
            if secret.userId?.nilIfBlank == nil {
                throw ProfileStorageError.missingCredential(protocolType)
            }
        case .trojan:
            if secret.password?.nilIfBlank == nil {
                throw ProfileStorageError.missingCredential(protocolType)
            }
        case .wireguard:
            if secret.wireGuardPrivateKey?.nilIfBlank == nil {
                throw ProfileStorageError.missingCredential(protocolType)
            }
        }
    }
}
