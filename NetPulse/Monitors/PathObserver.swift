import Foundation
import Network

/// Watches the system network path (Network.framework). It fires the moment
/// the Mac switches networks, and tells us whether the path is "expensive"
/// (macOS marks phone hotspots this way) or "constrained" (Low Data Mode).
final class PathObserver {
    struct State: Equatable {
        var isSatisfied = false
        var isExpensive = false
        var isConstrained = false
        /// All interfaces the path can use, in priority order (a VPN's utun comes first).
        var interfaces: [String] = []
        /// First Wi-Fi or wired interface — the physical link under any VPN.
        var physicalInterface: String?
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "netpulse.path")
    private(set) var state = State()
    var onChange: ((State) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            var next = State()
            next.isSatisfied = path.status == .satisfied
            next.isExpensive = path.isExpensive
            next.isConstrained = path.isConstrained
            next.interfaces = path.availableInterfaces.map(\.name)
            next.physicalInterface = path.availableInterfaces.first {
                $0.type == .wifi || $0.type == .wiredEthernet
            }?.name
            DispatchQueue.main.async {
                guard let self, next != self.state else { return }
                self.state = next
                self.onChange?(next)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}
