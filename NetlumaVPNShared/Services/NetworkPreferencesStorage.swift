import Foundation

struct NetworkPreferencesStorage {
    private let appGroupStorage: AppGroupStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(appGroupStorage: AppGroupStorage = AppGroupStorage()) {
        self.appGroupStorage = appGroupStorage
    }

    func load() -> NetworkPreferences {
        guard let data = appGroupStorage.data(forKey: AppConstants.AppGroupKeys.networkPreferences) else {
            return NetworkPreferences()
        }

        return (try? decoder.decode(NetworkPreferences.self, from: data)) ?? NetworkPreferences()
    }

    func save(_ preferences: NetworkPreferences) {
        guard let data = try? encoder.encode(preferences) else {
            return
        }

        appGroupStorage.set(data, forKey: AppConstants.AppGroupKeys.networkPreferences)
    }
}
