import Foundation

struct AppLogStore {
    private let appGroupStorage: AppGroupStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxEvents = 300

    init(appGroupStorage: AppGroupStorage = AppGroupStorage()) {
        self.appGroupStorage = appGroupStorage
    }

    func loadEvents() -> [AppLogEvent] {
        guard let data = appGroupStorage.data(forKey: AppConstants.AppGroupKeys.logs) else {
            return []
        }
        return (try? decoder.decode([AppLogEvent].self, from: data)) ?? []
    }

    func append(_ event: AppLogEvent) {
        var events = loadEvents()
        events.append(event)
        events = Array(events.suffix(maxEvents))

        guard let data = try? encoder.encode(events) else {
            return
        }
        appGroupStorage.set(data, forKey: AppConstants.AppGroupKeys.logs)
    }

    func clear() {
        appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.logs)
    }
}
