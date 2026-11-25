import CoreGraphics
import IOKit.ps
import Network
import OSLog

/// Reports Wi-Fi, power and idle to the engine. The engine treats a queue's conditions as unmet until the first report.
@MainActor
final class ConditionsMonitor {
    private static let log = Logger(subsystem: "app.rays", category: "conditions")
    private let report: (_ wifi: Bool, _ onPower: Bool, _ idle: Bool, _ network: NetworkKind) -> Void
    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?
    private var wifi = false
    private var network = NetworkKind.unknown

    init(report: @escaping (_ wifi: Bool, _ onPower: Bool, _ idle: Bool, _ network: NetworkKind) -> Void) {
        self.report = report
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi) && !path.isExpensive
            let network = Self.kind(of: path)
            Task { @MainActor in self?.update(wifi: wifi, network: network) }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportNow() }
        }
        reportNow()
    }

    func stop() {
        pathMonitor.cancel()
        timer?.invalidate()
        timer = nil
    }

    nonisolated private static func kind(of path: NWPath) -> NetworkKind {
        if path.isExpensive || path.isConstrained { return .expensive }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return path.status == .satisfied ? .other : .unknown
    }

    private func update(wifi: Bool, network: NetworkKind) {
        self.wifi = wifi
        self.network = network
        reportNow()
    }

    private func reportNow() {
        let onPower = Self.onPower
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null) >= 300
        Self.log.debug("setConditions wifi=\(self.wifi) onPower=\(onPower) idle=\(idle)")
        report(wifi, onPower, idle, network)
    }

    /// A desktop Mac has no battery and reports AC power, so it counts as on power.
    private static var onPower: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        return IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String == kIOPMACPowerKey
    }
}
