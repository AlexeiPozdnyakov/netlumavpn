import Foundation
import Network

struct ConnectionDiagnostics {
    func checkTCPReachability(
        host: String,
        port: Int,
        timeout: TimeInterval = 8
    ) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )
        let queue = DispatchQueue(label: "com.alekseipozdiakov.NetlumaVPN.connection-diagnostics")
        let result = OneShotResult<Bool>()

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                result.complete(true)
                connection.cancel()
            case .failed, .waiting:
                result.complete(false)
                connection.cancel()
            case .cancelled:
                result.complete(false)
            default:
                break
            }
        }

        connection.start(queue: queue)

        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            result.complete(false)
            connection.cancel()
        }

        return await result.value()
    }

    func checkInternetReachability(timeout: TimeInterval = 8) async -> Bool {
        do {
            var request = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!)
            request.timeoutInterval = timeout

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            let session = URLSession(configuration: configuration)

            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200..<400).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    func fetchPublicIPAddress(timeout: TimeInterval = 8) async -> String? {
        do {
            var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
            request.timeoutInterval = timeout

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            let session = URLSession(configuration: configuration)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<400).contains(httpResponse.statusCode),
                  let ipAddress = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  ipAddress.isEmpty == false else {
                return nil
            }

            return ipAddress
        } catch {
            return nil
        }
    }

    func measureTCPConnectLatency(
        host: String,
        port: Int,
        timeout: TimeInterval = 8
    ) async -> Int? {
        let startedAt = Date()
        guard await checkTCPReachability(host: host, port: port, timeout: timeout) else {
            return nil
        }

        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        return max(milliseconds, 1)
    }
}

private final class OneShotResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var storedValue: Value?

    func complete(_ value: Value) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
            return
        }

        if storedValue == nil {
            storedValue = value
        }
        lock.unlock()
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let storedValue {
                lock.unlock()
                continuation.resume(returning: storedValue)
                return
            }

            self.continuation = continuation
            lock.unlock()
        }
    }
}
