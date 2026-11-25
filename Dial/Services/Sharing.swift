import Foundation

/// When several screens ask for the same thing at the same moment, only one request goes out and they all
/// get its answer.
actor RequestSharing {
    static let shared = RequestSharing()
    private var running: [String: Task<Data?, Never>] = [:]

    func data(for key: String, load: @escaping @Sendable () async -> Data?) async -> Data? {
        if let task = running[key] { return await task.value }
        let task = Task { await load() }
        running[key] = task
        let result = await task.value
        running[key] = nil
        return result
    }
}

/// One URLSession for everything Dial downloads: no second cache on top of Dial's own (which would store
/// everything twice), more parallel downloads per server, and sensible timeouts.
enum Network {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}
