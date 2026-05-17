import Foundation

struct AppGroupStorage {
    private let suiteName: String
    private let baseURL: URL?

    init(suiteName: String = AppConstants.appGroupIdentifier) {
        self.suiteName = suiteName
        baseURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent("QuickVPNShared", isDirectory: true)
    }

    func data(forKey key: String) -> Data? {
        try? Data(contentsOf: fileURL(forKey: key))
    }

    func set(_ data: Data?, forKey key: String) {
        guard let data else {
            removeObject(forKey: key)
            return
        }

        do {
            try prepareDirectory()
            try data.write(to: fileURL(forKey: key), options: [.atomic])
        } catch {
        }
    }

    func string(forKey key: String) -> String? {
        guard let data = data(forKey: key) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, forKey key: String) {
        set(value?.data(using: .utf8), forKey: key)
    }

    func removeObject(forKey key: String) {
        try? FileManager.default.removeItem(at: fileURL(forKey: key))
    }

    private func prepareDirectory() throws {
        let baseURL = fileURL(forKey: "probe").deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true
        )
    }

    private func fileURL(forKey key: String) -> URL {
        let sanitizedKey = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let directory = baseURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickVPNShared-\(suiteName)", isDirectory: true)
        return directory.appendingPathComponent("\(sanitizedKey).json")
    }
}

struct SessionStateStorage {
    private struct State: Codable {
        var connectionStartedAt: Date?
    }

    private let appGroupStorage: AppGroupStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(appGroupStorage: AppGroupStorage = AppGroupStorage()) {
        self.appGroupStorage = appGroupStorage
    }

    func connectionStartedAt() -> Date? {
        guard let data = appGroupStorage.data(forKey: AppConstants.AppGroupKeys.connectionSessionState),
              let state = try? decoder.decode(State.self, from: data) else {
            return nil
        }
        return state.connectionStartedAt
    }

    func markConnectionStarted(at date: Date = Date()) {
        guard let data = try? encoder.encode(State(connectionStartedAt: date)) else {
            return
        }
        appGroupStorage.set(data, forKey: AppConstants.AppGroupKeys.connectionSessionState)
    }

    func clearConnectionStartedAt() {
        appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.connectionSessionState)
    }
}

struct ConnectionDisplayStateStorage {
    struct DisplayState: Equatable {
        var status: VPNConnectionStatus
        var updatedAt: Date
        var connectionStartedAt: Date?
    }

    private struct State: Codable {
        var status: VPNConnectionStatus
        var updatedAt: Date
        var connectionStartedAt: Date?
    }

    private let appGroupStorage: AppGroupStorage
    private let maxStateAge: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        appGroupStorage: AppGroupStorage = AppGroupStorage(),
        maxStateAge: TimeInterval = 20
    ) {
        self.appGroupStorage = appGroupStorage
        self.maxStateAge = maxStateAge
    }

    func save(
        status: VPNConnectionStatus,
        connectionStartedAt: Date? = nil,
        now: Date = Date()
    ) {
        let state = State(
            status: status,
            updatedAt: now,
            connectionStartedAt: connectionStartedAt
        )
        guard let data = try? encoder.encode(state) else {
            return
        }
        appGroupStorage.set(data, forKey: AppConstants.AppGroupKeys.connectionDisplayState)
    }

    func save(connectionState: VPNConnectionState, now: Date = Date()) {
        save(
            status: connectionState.status,
            connectionStartedAt: connectionState.connectedDate,
            now: now
        )
    }

    func state(now: Date = Date()) -> DisplayState? {
        guard let data = appGroupStorage.data(forKey: AppConstants.AppGroupKeys.connectionDisplayState),
              let state = try? decoder.decode(State.self, from: data) else {
            return nil
        }

        guard now.timeIntervalSince(state.updatedAt) <= maxStateAge else {
            clear()
            return nil
        }

        return DisplayState(
            status: state.status,
            updatedAt: state.updatedAt,
            connectionStartedAt: state.connectionStartedAt
        )
    }

    func clear() {
        appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.connectionDisplayState)
    }
}

struct WidgetActionStorage {
    private enum ActionKind: String, Codable, Equatable {
        case toggleConnection
    }

    private struct PendingAction: Codable {
        var id: UUID
        var kind: ActionKind
        var createdAt: Date
    }

    private let appGroupStorage: AppGroupStorage
    private let maxActionAge: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        appGroupStorage: AppGroupStorage = AppGroupStorage(),
        maxActionAge: TimeInterval = 120
    ) {
        self.appGroupStorage = appGroupStorage
        self.maxActionAge = maxActionAge
    }

    func requestToggleConnection(now: Date = Date()) {
        let action = PendingAction(
            id: UUID(),
            kind: .toggleConnection,
            createdAt: now
        )
        guard let data = try? encoder.encode(action) else {
            return
        }
        appGroupStorage.set(data, forKey: AppConstants.AppGroupKeys.pendingWidgetAction)
    }

    func consumePendingToggle(now: Date = Date()) -> Bool {
        defer {
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.pendingWidgetAction)
        }

        guard let data = appGroupStorage.data(forKey: AppConstants.AppGroupKeys.pendingWidgetAction),
              let action = try? decoder.decode(PendingAction.self, from: data),
              action.kind == .toggleConnection else {
            return false
        }

        return now.timeIntervalSince(action.createdAt) <= maxActionAge
    }
}
