import Foundation
import Network
import Observation

/// Knows whether your server can be reached. When it can't (no internet, away from home
/// without remote access, server down), Dial switches to the music downloaded on this iPhone,
/// and checks again every so often to switch back by itself.
@MainActor
@Observable
final class Connectivity {
    private(set) var isOffline = false {
        didSet {
            ImagePipeline.shared.isOffline = isOffline
            if isOffline { scheduleRetry() } else { retryTask?.cancel() }
            if oldValue && !isOffline { onReconnect?() }
        }
    }

    /// Called when the server can be reached again after being away.
    @ObservationIgnored var onReconnect: (() -> Void)?

    @ObservationIgnored var client: JellyfinClient? {
        didSet { Task { await check() } }
    }

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var hasNetwork = true
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var checking = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.hasNetwork = available
                await self.check()
            }
        }
        monitor.start(queue: DispatchQueue(label: "dial.connectivity"))
    }

    /// Asks the server directly, with a short timeout so being away doesn't mean a long wait.
    func check() async {
        guard let client else {
            isOffline = false
            return
        }
        guard hasNetwork else {
            isOffline = true
            return
        }
        guard !checking else { return }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: client.server.appending(path: "System/Ping"))
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let reachable: Bool
        if let (_, response) = try? await URLSession.shared.data(for: request),
           let status = (response as? HTTPURLResponse)?.statusCode {
            reachable = status < 500
        } else {
            reachable = false
        }
        if isOffline != !reachable { isOffline = !reachable }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.isOffline else { return }
                await self.check()
            }
        }
    }
}
