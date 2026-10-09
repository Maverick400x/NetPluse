import Foundation
import SwiftUI
import AppKit
import WidgetKit

/// Central state for the whole app. Runs the monitors on timers and
/// publishes results to the UI, the widget, the CSV log and /metrics.
@MainActor
final class NetworkStore: ObservableObject {

    struct RatePoint: Identifiable {
        let id = UUID()
        let time: Date
        let download: Double   // Mbps
        let upload: Double
    }

    struct LatencyPoint: Identifiable {
        let id = UUID()
        let time: Date
        let ms: Double?        // nil = lost packet
    }

    // MARK: Bandwidth
    @Published private(set) var downloadMbps: Double = 0
    @Published private(set) var uploadMbps: Double = 0
    @Published private(set) var peakDownloadMbps: Double = 0
    @Published private(set) var peakUploadMbps: Double = 0
    @Published private(set) var rateHistory: [RatePoint] = []
    @Published private(set) var sessionReceived: UInt64 = 0
    @Published private(set) var sessionSent: UInt64 = 0

    // MARK: Latency
    @Published var pingHost: String {
        didSet { UserDefaults.standard.set(pingHost, forKey: "pingHost"); latencyHistory.removeAll() }
    }
    @Published private(set) var latencyMs: Double?
    @Published private(set) var latencyHistory: [LatencyPoint] = []

    var latencyStats: LatencyStats {
        LatencyStats(results: latencyHistory.suffix(60).map(\.ms))
    }

    // MARK: Connection
    @Published private(set) var connection = ConnectionDetails()
    /// Interfaces whose byte counters feed the speed readings (normally just
    /// the one carrying the default route, e.g. en0).
    @Published private(set) var measuredInterfaces: [String] = []
    @Published private(set) var locationAuthorized = false

    // MARK: Devices
    @Published private(set) var devices: [NetworkDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?

    // MARK: Insights / DevOps
    @Published private(set) var insights: [Insight] = []
    @Published private(set) var anomalyCount = 0
    @Published private(set) var metricsServerRunning = false
    @Published var metricsServerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(metricsServerEnabled, forKey: "metricsServerEnabled")
            applyMetricsServerSetting()
        }
    }
    @Published var loggingEnabled: Bool {
        didSet { UserDefaults.standard.set(loggingEnabled, forKey: "loggingEnabled") }
    }

    var status: NetSnapshot.Status {
        let recent = latencyHistory.suffix(3)
        if connection.kind == .none || connection.localIP == nil || (recent.count == 3 && recent.allSatisfy { $0.ms == nil }) {
            return .offline
        }
        let stats = latencyStats
        let weakSignal = connection.isWiFi && (connection.rssi ?? 0) < -78
        if stats.packetLoss > 0.1 || (stats.average ?? 0) > 150 || weakSignal {
            return .degraded
        }
        return .good
    }

    let logger = MetricsLogger()
    let metricsServer = MetricsServer()

    private let detector = AnomalyDetector()
    private let location = LocationPermission()
    private let path = PathObserver()
    private var lastCounters: [String: InterfaceCounters] = [:]
    /// Monotonic clock (seconds since boot) — unaffected by clock/NTP changes,
    /// so each rate is bytes ÷ the true elapsed time.
    private var lastSampleUptime: TimeInterval?
    private var appNapActivity: NSObjectProtocol?
    private var connectionRefreshInFlight = false
    private var connectionRefreshPending = false
    private var hasLoadedConnection = false
    private var timers: [Timer] = []
    private var pingInFlight = false
    private var anomalySinceLastLog = false
    private var lastWidgetReload = Date.distantPast
    private var lastPublicIPCheck = Date.distantPast
    private var lastInsightTimes: [String: Date] = [:]

    init() {
        let defaults = UserDefaults.standard
        pingHost = defaults.string(forKey: "pingHost") ?? "1.1.1.1"
        metricsServerEnabled = defaults.object(forKey: "metricsServerEnabled") as? Bool ?? true
        loggingEnabled = defaults.object(forKey: "loggingEnabled") as? Bool ?? true
        start()
    }

    // MARK: - Lifecycle

    private func start() {
        location.onChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.locationAuthorized = self.location.isAuthorized
                self.refreshConnection()
            }
        }
        location.requestIfNeeded()
        locationAuthorized = location.isAuthorized

        // Keep 1-second sampling precise even when the window is hidden
        // (App Nap would otherwise stretch timers to many seconds).
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Live network measurement")

        path.onChange = { [weak self] _ in
            self?.refreshConnection()
        }
        path.start()

        lastCounters = InterfaceStats.counters()
        lastSampleUptime = ProcessInfo.processInfo.systemUptime

        schedule(every: 1) { $0.sampleBandwidth() }
        schedule(every: 2) { $0.samplePing() }
        schedule(every: 10) { $0.refreshConnection() }
        schedule(every: 5) { $0.publishSnapshot() }
        schedule(every: 300) { $0.scanDevices() }

        applyMetricsServerSetting()
        refreshConnection()

        // First device scan once the connection details are known.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.scanDevices()
        }
    }

    private func schedule(every interval: TimeInterval, _ action: @escaping @MainActor (NetworkStore) -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                action(self)
            }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking while menus are open
        timers.append(timer)
    }

    // MARK: - Bandwidth

    private func sampleBandwidth() {
        let now = ProcessInfo.processInfo.systemUptime
        let counters = InterfaceStats.counters()
        defer { lastCounters = counters; lastSampleUptime = now }

        guard let previousTime = lastSampleUptime else { return }
        let elapsed = now - previousTime
        guard elapsed > 0.2 else { return }

        // Measure only the interface that carries internet traffic. Summing
        // every interface would double-count (e.g. VPN tunnel + Wi-Fi) or add
        // unrelated links (Thunderbolt bridge, idle Ethernet).
        let measured: [String]
        if let primary = connection.interfaceName, counters[primary] != nil {
            measured = [primary]
        } else {
            measured = counters.keys.filter { $0.hasPrefix("en") }.sorted()
        }
        if measured != measuredInterfaces { measuredInterfaces = measured }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        for name in measured {
            guard let current = counters[name], let previous = lastCounters[name] else { continue }
            // Counters reset when an interface is re-created; skip that sample.
            if current.received >= previous.received { received += current.received - previous.received }
            if current.sent >= previous.sent { sent += current.sent - previous.sent }
        }

        downloadMbps = Double(received) * 8 / elapsed / 1_000_000
        uploadMbps = Double(sent) * 8 / elapsed / 1_000_000
        peakDownloadMbps = max(peakDownloadMbps, downloadMbps)
        peakUploadMbps = max(peakUploadMbps, uploadMbps)
        sessionReceived += received
        sessionSent += sent

        rateHistory.append(RatePoint(time: Date(), download: downloadMbps, upload: uploadMbps))
        if rateHistory.count > 120 { rateHistory.removeFirst(rateHistory.count - 120) }
    }

    func resetPeaks() {
        peakDownloadMbps = 0
        peakUploadMbps = 0
        sessionReceived = 0
        sessionSent = 0
    }

    // MARK: - Latency

    private func samplePing() {
        guard !pingInFlight else { return }
        pingInFlight = true
        let host = pingHost
        Task { @MainActor in
            let ms = await Pinger.ping(host: host)
            pingInFlight = false
            guard host == pingHost else { return }     // host changed mid-flight

            latencyMs = ms
            latencyHistory.append(LatencyPoint(time: Date(), ms: ms))
            if latencyHistory.count > 300 { latencyHistory.removeFirst(latencyHistory.count - 300) }
            analyzeLatency(ms)
        }
    }

    private func analyzeLatency(_ ms: Double?) {
        if let ms, let z = detector.observe("latency", value: ms, floor: 2) {
            let baseline = detector.baseline("latency") ?? 0
            addInsight(.warning, key: "latency-spike",
                       title: "Latency spike",
                       detail: String(format: "Ping to %@ jumped to %.0f ms (usual ≈ %.0f ms, z = %.1f).",
                                      pingHost, ms, baseline, z))
        }
        let stats = latencyStats
        if stats.samples >= 20, stats.packetLoss >= 0.05 {
            addInsight(stats.packetLoss >= 0.2 ? .critical : .warning, key: "packet-loss",
                       title: "Packet loss",
                       detail: "\(Format.percent(stats.packetLoss)) of the last \(stats.samples) pings to \(pingHost) were lost.")
        }
        if let jitter = stats.jitter, stats.samples >= 20, jitter > 30 {
            addInsight(.warning, key: "jitter",
                       title: "High jitter",
                       detail: String(format: "Latency is varying by %.0f ms on average — calls and games may stutter.", jitter))
        }
        if latencyHistory.suffix(5).count == 5, latencyHistory.suffix(5).allSatisfy({ $0.ms == nil }) {
            addInsight(.critical, key: "offline", title: "Connection lost",
                       detail: "The last 5 pings to \(pingHost) got no reply.")
        }
    }

    // MARK: - Connection

    func refreshConnection() {
        // Coalesce: path changes and the 10 s timer can overlap.
        guard !connectionRefreshInFlight else { connectionRefreshPending = true; return }
        connectionRefreshInFlight = true
        Task { @MainActor in
            defer {
                connectionRefreshInFlight = false
                if connectionRefreshPending {
                    connectionRefreshPending = false
                    refreshConnection()
                }
            }
            let pathState = path.state
            let details = await Task.detached(priority: .utility) { ConnectionInfo.fetch(path: pathState) }.value
            var updated = details
            let previous = connection
            let ssidChanged = previous.ssid != nil && details.ssid != nil && previous.ssid != details.ssid
            let networkChanged = previous.networkKey != details.networkKey || ssidChanged
            updated.publicIP = networkChanged ? nil : previous.publicIP

            if details.isWiFi, let rssi = details.rssi, rssi < -75 {
                addInsight(.info, key: "weak-signal", title: "Weak Wi-Fi signal",
                           detail: "Signal is \(rssi) dBm. Moving closer to the router or switching to 5 GHz may help.")
            }
            if networkChanged && hasLoadedConnection {
                let name = details.ssid.map { " “\($0)”" } ?? ""
                addInsight(.info, key: "network-change-\(details.networkKey)", title: "Network changed",
                           detail: "Now on \(details.kind.label)\(name)\(details.vpnActive ? " via VPN" : "").")
            }
            if networkChanged && hasLoadedConnection && details.kind.isHotspot {
                addInsight(.info, key: "hotspot-\(details.networkKey)", title: "Using a phone hotspot",
                           detail: "This connection is metered — watch “This session” to track data use.")
            }
            connection = updated
            let firstLoad = !hasLoadedConnection
            hasLoadedConnection = true

            if networkChanged && !firstLoad {
                // A new network has its own normal latency and devices; start fresh
                // so stats and anomaly baselines describe only this network.
                lastPublicIPCheck = .distantPast
                latencyHistory.removeAll()
                latencyMs = nil
                detector.reset()
                peakDownloadMbps = 0
                peakUploadMbps = 0
                devices.removeAll()
                lastScan = nil
                if previous.kind != .none || details.kind != .none {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        self.scanDevices()
                    }
                }
            }

            // Refresh every 5 minutes; if the last lookup failed, retry after 30 s.
            let interval: TimeInterval = connection.publicIP == nil ? 30 : 300
            if connection.kind != .none, Date().timeIntervalSince(lastPublicIPCheck) > interval {
                lastPublicIPCheck = Date()
                if let ip = await ConnectionInfo.fetchPublicIP() {
                    connection.publicIP = ip
                }
            }
        }
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Devices

    func scanDevices() {
        guard !isScanning, let ip = connection.localIP else { return }
        isScanning = true
        let mask = connection.netmask ?? "255.255.255.0"
        let gateway = connection.gateway
        let interface = connection.interfaceName
        Task { @MainActor in
            let found = await DeviceScanner.scan(localIP: ip, netmask: mask, gateway: gateway, interface: interface)

            let previous = Set(devices.map(\.mac))
            let newcomers = found.filter { !$0.isThisMac && !previous.contains($0.mac) }
            if lastScan != nil, !newcomers.isEmpty {
                let list = newcomers.prefix(3).map { $0.hostname ?? $0.ip }.joined(separator: ", ")
                addInsight(.info, key: "new-device-\(newcomers.count)-\(list)", title: "New device on network",
                           detail: "\(newcomers.count) new device(s) joined: \(list).")
            }

            devices = found
            lastScan = Date()
            isScanning = false
        }
    }

    // MARK: - Insights

    private func addInsight(_ severity: Insight.Severity, key: String, title: String, detail: String) {
        // Don't repeat the same kind of alert more than once a minute.
        if let last = lastInsightTimes[key], Date().timeIntervalSince(last) < 60 { return }
        lastInsightTimes[key] = Date()
        insights.insert(Insight(date: Date(), severity: severity, title: title, detail: detail), at: 0)
        if insights.count > 200 { insights.removeLast(insights.count - 200) }
        if severity != .info {
            anomalyCount += 1
            anomalySinceLastLog = true
        }
    }

    func clearInsights() {
        insights.removeAll()
        lastInsightTimes.removeAll()
    }

    // MARK: - Publishing (widget, CSV, Prometheus)

    func makeSnapshot() -> NetSnapshot {
        let stats = latencyStats
        let recent = rateHistory.suffix(30)
        return NetSnapshot(
            timestamp: Date(),
            downloadMbps: downloadMbps,
            uploadMbps: uploadMbps,
            latencyMs: latencyMs,
            jitterMs: stats.jitter,
            packetLoss: stats.packetLoss,
            ssid: connection.ssid,
            rssi: connection.rssi,
            localIP: connection.localIP,
            deviceCount: devices.count,
            downloadHistory: recent.map(\.download),
            uploadHistory: recent.map(\.upload),
            status: status,
            connectionKind: connection.kind,
            vpnActive: connection.vpnActive
        )
    }

    private func publishSnapshot() {
        let snapshot = makeSnapshot()
        SharedStore.save(snapshot)

        if loggingEnabled {
            logger.append(snapshot, anomaly: anomalySinceLastLog)
        }
        anomalySinceLastLog = false

        metricsServer.update(MetricsServer.render(
            snapshot: snapshot, bytesIn: sessionReceived, bytesOut: sessionSent, anomalies: anomalyCount))

        // macOS rations widget refreshes, so ask at most once a minute.
        if Date().timeIntervalSince(lastWidgetReload) > 60 {
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func applyMetricsServerSetting() {
        if metricsServerEnabled {
            metricsServer.start()
        } else {
            metricsServer.stop()
        }
        metricsServerRunning = metricsServer.isRunning
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([logger.fileURL])
    }
}
