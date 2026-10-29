import Network

/// Wi-Fi или мобильная сеть — от этого зависит качество потока.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private(set) var isExpensive = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.isExpensive = path.isExpensive || path.isConstrained }
        monitor.start(queue: DispatchQueue(label: "yokayo.network"))
    }
}
