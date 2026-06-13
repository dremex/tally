import Foundation
import Network

/// Wraps NWPathMonitor to publish the current connection type (Wi-Fi / Ethernet / etc).
/// Runs on a background queue and calls `onChange` on the main queue.
/// `@unchecked Sendable`: `onChange` is set once before `start()` and thereafter only read from
/// the monitor's serial queue, so there is no concurrent mutation.
final class PathMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.kerry.netmon.path")

    enum ConnectionType: String {
        case wifi = "Wi-Fi"
        case ethernet = "Ethernet"
        case cellular = "Cellular"
        case other = "Other"
        case none = "Offline"
    }

    var onChange: (@Sendable (ConnectionType) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let type: ConnectionType = if path.status != .satisfied {
                .none
            } else if path.usesInterfaceType(.wifi) {
                .wifi
            } else if path.usesInterfaceType(.wiredEthernet) {
                .ethernet
            } else if path.usesInterfaceType(.cellular) {
                .cellular
            } else {
                .other
            }
            let cb = self?.onChange
            DispatchQueue.main.async { cb?(type) }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
