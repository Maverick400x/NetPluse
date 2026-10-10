import Foundation
import AppKit

/// Runs internet speed tests, keeps their history, and can run them on a schedule.
@MainActor
final class SpeedTestController: ObservableObject {

    struct LiveSample: Identifiable {
        let id = UUID()
        let time: Double            // seconds since the test started
        let mbps: Double
        let phase: String
    }

    // Live state
    @Published private(set) var phase: SpeedTestPhase = .idle
    @Published private(set) var liveMbps: Double = 0
    @Published private(set) var liveSamples: [LiveSample] = []
    @Published private(set) var partialDownload: Double?
    @Published private(set) var partialUpload: Double?
    @Published private(set) var partialIdleLatency: Double?

    // History (newest first)
    @Published private(set) var history: [SpeedTestResult] = []
    var latest: SpeedTestResult? { history.first }

    // Settings
    @Published var engine: SpeedTestEngine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "speedTest.engine") }
    }
    @Published var appleSequential: Bool {
        didSet { UserDefaults.standard.set(appleSequential, forKey: "speedTest.sequential") }
    }
    /// 0 = off.
    @Published var autoIntervalHours: Int {
        didSet { UserDefaults.standard.set(autoIntervalHours, forKey: "speedTest.autoHours") }
    }
    @Published var autoSkipMetered: Bool {
        didSet { UserDefaults.standard.set(autoSkipMetered, forKey: "speedTest.autoSkipMetered") }
    }

    let historyURL: URL
    let csvURL: URL

    private weak var network: NetworkStore?
    private var runTask: Task<Void, Never>?
    private var liveTimer: Timer?
    private var scheduleTimer: Timer?
    private var startUptime: TimeInterval = 0
    private let appleRunner = NetworkQualityRunner()

    init(network: NetworkStore) {
        self.network = network
        let defaults = UserDefaults.standard
        engine = SpeedTestEngine(rawValue: defaults.string(forKey: "speedTest.engine") ?? "") ?? .apple
        appleSequential = defaults.object(forKey: "speedTest.sequential") as? Bool ?? true
        autoIntervalHours = defaults.object(forKey: "speedTest.autoHours") as? Int ?? 0
        autoSkipMetered = defaults.object(forKey: "speedTest.autoSkipMetered") as? Bool ?? true

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("NetPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        historyURL = folder.appendingPathComponent("speedtests.json")
        csvURL = folder.appendingPathComponent("speedtests.csv")

        loadHistory()
        Task { @MainActor [weak self] in
            self?.network?.lastSpeedTest = self?.latest
        }

        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runScheduledTestIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    // MARK: - Running

    var isRunning: Bool { phase.isRunning }

    func start(automatic: Bool = false) {
        guard !isRunning, let network else { return }
        let connection = network.connection
        guard connection.kind != .none else {
            phase = .failed("You're offline — connect to a network first.")
            return
        }

        let engine = self.engine
        let sequential = appleSequential
        let interface = connection.interfaceName
        let before = Self.interfaceBytes(interface)

        liveSamples = []
        liveMbps = 0
        partialDownload = nil
        partialUpload = nil
        partialIdleLatency = nil
        startUptime = ProcessInfo.processInfo.systemUptime
        phase = .connecting
        network.isSpeedTestRunning = true

        runTask = Task { @MainActor in
            defer {
                stopLiveTimer()
                network.isSpeedTestRunning = false
            }
            do {
                var result = SpeedTestResult(
                    date: Date(), engine: engine, downloadMbps: 0, uploadMbps: 0,
                    interfaceName: interface, connectionKind: connection.kind,
                    networkName: connection.ssid ?? connection.hardwarePort,
                    vpn: connection.vpnActive, automatic: automatic)

                switch engine {
                case .apple:
                    startLiveTimer(sequential: sequential)
                    let report = try await appleRunner.run(sequential: sequential)
                    result.downloadMbps = report.downloadMbps
                    result.uploadMbps = report.uploadMbps
                    result.idleLatencyMs = report.idleLatencyMs
                    result.loadedLatencyMs = report.loadedLatencyMs
                    result.server = report.endpoint ?? "Apple CDN"
                    if let name = report.interfaceName { result.interfaceName = name }

                case .cloudflare:
                    let test = CloudflareSpeedTest()
                    let measurement = try await test.run(
                        progress: { [weak self] phase, mbps in self?.update(phase: phase, mbps: mbps) },
                        partial: { [weak self] partial in
                            self?.partialIdleLatency = partial.idleLatencyMs
                            if partial.downloadMbps > 0 { self?.partialDownload = partial.downloadMbps }
                        })
                    result.downloadMbps = measurement.downloadMbps
                    result.uploadMbps = measurement.uploadMbps
                    result.idleLatencyMs = measurement.idleLatencyMs
                    result.loadedLatencyMs = measurement.loadedLatencyMs
                    result.jitterMs = measurement.jitterMs
                    result.server = measurement.server
                    result.isp = measurement.isp
                }

                let after = Self.interfaceBytes(interface)
                if let before, let after, after >= before { result.dataUsedBytes = after - before }
                result.durationSeconds = ProcessInfo.processInfo.systemUptime - startUptime

                partialDownload = result.downloadMbps
                partialUpload = result.uploadMbps
                partialIdleLatency = result.idleLatencyMs
                record(result)
                phase = .done
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        appleRunner.cancel()
    }

    private func update(phase newPhase: SpeedTestPhase, mbps: Double) {
        if phase != newPhase, newPhase == .upload, let last = liveSamples.last(where: { $0.phase == "Download" }) {
            partialDownload = partialDownload ?? last.mbps
        }
        phase = newPhase
        liveMbps = mbps
        guard newPhase == .download || newPhase == .upload || newPhase == .combined else { return }
        let t = ProcessInfo.processInfo.systemUptime - startUptime
        liveSamples.append(LiveSample(time: t, mbps: mbps, phase: newPhase == .upload ? "Upload" : "Download"))
    }

    /// networkQuality doesn't stream progress, so show the real traffic on
    /// the interface (from NetworkStore's kernel counters) while it runs.
    private func startLiveTimer(sequential: Bool) {
        stopLiveTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let network = self.network, self.isRunning else { return }
                let down = network.downloadMbps
                let up = network.uploadMbps
                let busy = max(down, up)
                let newPhase: SpeedTestPhase
                if busy < 0.5 {
                    newPhase = .connecting
                } else if !sequential {
                    newPhase = .combined
                } else {
                    newPhase = down >= up ? .download : .upload
                }
                self.update(phase: newPhase, mbps: newPhase == .upload ? up : (newPhase == .combined ? down : busy))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func stopLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    /// Total bytes (in + out) on the interface, straight from the kernel.
    private static func interfaceBytes(_ interface: String?) -> UInt64? {
        let counters = InterfaceStats.counters()
        if let interface, let c = counters[interface] { return c.received &+ c.sent }
        let physical = counters.filter { $0.key.hasPrefix("en") }.values
        guard !physical.isEmpty else { return nil }
        return physical.reduce(0) { $0 &+ $1.received &+ $1.sent }
    }

    // MARK: - Schedule

    private func runScheduledTestIfDue() {
        guard autoIntervalHours > 0, !isRunning, let network else { return }
        if autoSkipMetered && network.connection.isMetered { return }
        guard network.status != .offline else { return }
        let lastAutomatic = history.first(where: { $0.automatic })?.date ?? .distantPast
        let lastAny = latest?.date ?? .distantPast
        let interval = TimeInterval(autoIntervalHours) * 3600
        guard Date().timeIntervalSince(max(lastAutomatic, lastAny)) >= interval else { return }
        start(automatic: true)
    }

    // MARK: - History

    private func record(_ result: SpeedTestResult) {
        history.insert(result, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        saveHistory()
        network?.lastSpeedTest = result
        network?.publishNow()
    }

    func delete(_ ids: Set<UUID>) {
        history.removeAll { ids.contains($0.id) }
        saveHistory()
        network?.lastSpeedTest = latest
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
        network?.lastSpeedTest = nil
    }

    func revealCSV() {
        saveHistory()
        NSWorkspace.shared.activateFileViewerSelecting([csvURL])
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        history = (try? decoder.decode([SpeedTestResult].self, from: data)) ?? []
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(history) {
            try? data.write(to: historyURL, options: .atomic)
        }
        try? Self.csv(history).write(to: csvURL, atomically: true, encoding: .utf8)
    }

    /// One row per test, oldest first — ready for spreadsheets or the ML scripts.
    static func csv(_ results: [SpeedTestResult]) -> String {
        let formatter = ISO8601DateFormatter()
        func value(_ number: Double?) -> String { number.map { String(format: "%.2f", $0) } ?? "" }
        var lines = ["timestamp,engine,network,connection_type,vpn,interface,download_mbps,upload_mbps,idle_latency_ms,loaded_latency_ms,jitter_ms,data_used_mb,duration_s,server,isp,automatic"]
        for r in results.reversed() {
            lines.append([
                formatter.string(from: r.date),
                r.engine.rawValue,
                MetricsLogger.csvField(r.networkName ?? ""),
                r.connectionKind?.rawValue ?? "",
                r.vpn ? "1" : "0",
                r.interfaceName ?? "",
                value(r.downloadMbps),
                value(r.uploadMbps),
                value(r.idleLatencyMs),
                value(r.loadedLatencyMs),
                value(r.jitterMs),
                value(r.dataUsedBytes.map { Double($0) / 1_000_000 }),
                String(format: "%.0f", r.durationSeconds),
                MetricsLogger.csvField(r.server ?? ""),
                MetricsLogger.csvField(r.isp ?? ""),
                r.automatic ? "1" : "0",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
