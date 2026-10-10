import Foundation

// MARK: - Model

enum SpeedTestEngine: String, Codable, CaseIterable, Identifiable {
    case apple, cloudflare
    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: return "Apple (networkQuality)"
        case .cloudflare: return "Cloudflare"
        }
    }

    var shortLabel: String { self == .apple ? "Apple" : "Cloudflare" }
}

struct SpeedTestResult: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var engine: SpeedTestEngine
    var downloadMbps: Double
    var uploadMbps: Double
    var idleLatencyMs: Double?
    /// Latency while the link is saturated — the "bufferbloat" figure.
    var loadedLatencyMs: Double?
    var jitterMs: Double?
    var server: String?
    var isp: String?
    var interfaceName: String?
    var connectionKind: ConnectionKind?
    var networkName: String?
    var vpn: Bool = false
    /// Real bytes moved on the interface during the test (from kernel counters).
    var dataUsedBytes: UInt64?
    var durationSeconds: Double = 0
    var automatic: Bool = false

    /// Extra delay caused by a busy connection.
    var bufferbloatMs: Double? {
        guard let loaded = loadedLatencyMs, let idle = idleLatencyMs else { return nil }
        return max(0, loaded - idle)
    }

    var bufferbloatRating: String? {
        guard let extra = bufferbloatMs else { return nil }
        switch extra {
        case ..<30: return "Low"
        case ..<100: return "Moderate"
        default: return "High"
        }
    }
}

enum SpeedTestPhase: Equatable {
    case idle, connecting, latency, download, upload, combined, done
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .connecting: return "Connecting…"
        case .latency: return "Measuring latency…"
        case .download: return "Testing download…"
        case .upload: return "Testing upload…"
        case .combined: return "Testing download + upload…"
        case .done: return "Complete"
        case .failed: return "Failed"
        }
    }

    var isRunning: Bool {
        switch self {
        case .connecting, .latency, .download, .upload, .combined: return true
        default: return false
        }
    }
}

enum SpeedTestError: LocalizedError {
    case toolMissing
    case failed(String)
    case noData(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing: return "Apple's networkQuality tool was not found (needs macOS 12 or later)."
        case .failed(let message): return message
        case .noData(let message): return message
        }
    }
}

// MARK: - Apple engine (networkQuality)

/// Runs Apple's built-in `/usr/bin/networkQuality`, which tests against
/// Apple's CDN with many parallel flows and reports capacity and
/// responsiveness. This is the same tool macOS uses internally.
final class NetworkQualityRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func run(sequential: Bool) async throws -> Parsers.NetworkQualityReport {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Parsers.NetworkQualityReport, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let path = "/usr/bin/networkQuality"
                    guard FileManager.default.isExecutableFile(atPath: path) else {
                        continuation.resume(throwing: SpeedTestError.toolMissing)
                        return
                    }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = sequential ? ["-c", "-s"] : ["-c"]
                    let output = Pipe()
                    let errors = Pipe()
                    process.standardOutput = output
                    process.standardError = errors

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: SpeedTestError.toolMissing)
                        return
                    }
                    self.setProcess(process)

                    // Read stderr on another thread so neither pipe can fill up and block.
                    let errorBox = DataBox()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        errorBox.set(errors.fileHandleForReading.readDataToEndOfFile())
                        group.leave()
                    }
                    let outData = output.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    self.setProcess(nil)

                    if process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let text = String(decoding: outData, as: UTF8.self)
                    if let report = Parsers.networkQuality(text), report.downloadMbps > 0 || report.uploadMbps > 0 {
                        continuation.resume(returning: report)
                    } else {
                        let message = String(decoding: errorBox.get(), as: UTF8.self)
                            .split(separator: "\n").first.map(String.init)
                            ?? "networkQuality could not complete the test. Check your internet connection."
                        continuation.resume(throwing: SpeedTestError.failed(message))
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        if let process, process.isRunning { process.terminate() }
    }

    private func setProcess(_ process: Process?) {
        lock.lock(); self.process = process; lock.unlock()
    }
}

/// Lock-protected Data shared between two threads.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

// MARK: - Cloudflare engine

/// Thread-safe running total of bytes moved by a group of transfers.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: UInt64 = 0
    private var errors = 0
    private var lastErrorMessage: String?

    func add(_ count: Int64) {
        guard count > 0 else { return }
        lock.lock(); total &+= UInt64(count); lock.unlock()
    }

    func recordError(_ message: String) {
        lock.lock(); errors += 1; lastErrorMessage = message; lock.unlock()
    }

    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return total }
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return lastErrorMessage }
}

/// One HTTP stream on its own connection that keeps transferring until stopped.
/// Each stream has its own URLSession so streams use separate TCP connections
/// (HTTP/2 would otherwise multiplex them onto one).
final class TransferStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Direction { case download, upload }

    private let direction: Direction
    private let counter: ByteCounter
    private let makeRequest: () -> URLRequest
    private let payload: Data?
    private var session: URLSession?
    private let lock = NSLock()
    private var stopped = false

    init(direction: Direction, counter: ByteCounter, payload: Data? = nil, makeRequest: @escaping () -> URLRequest) {
        self.direction = direction
        self.counter = counter
        self.payload = payload
        self.makeRequest = makeRequest
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 1
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func start() { startTask() }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        session?.invalidateAndCancel()       // also breaks the session → delegate retain cycle
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func startTask() {
        guard !isStopped, let session else { return }
        let request = makeRequest()
        let task: URLSessionTask
        if direction == .upload, let payload {
            task = session.uploadTask(with: request, from: payload)
        } else {
            task = session.dataTask(with: request)
        }
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            counter.recordError("Test server replied with HTTP \(http.statusCode).")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if direction == .download { counter.add(Int64(data.count)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if direction == .upload { counter.add(bytesSent) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isStopped else { return }
        if let error {
            if (error as NSError).code != NSURLErrorCancelled {
                counter.recordError(error.localizedDescription)
            }
            // Back off briefly so an offline network doesn't spin.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.startTask() }
        } else {
            startTask()      // keep the pipe full until the measurement window ends
        }
    }
}

/// Speed test against Cloudflare's edge (speed.cloudflare.com), measured by
/// NetPulse itself: parallel streams for a fixed time, throughput taken after
/// a warm-up, and latency probes both idle and under load.
@MainActor
final class CloudflareSpeedTest {
    struct Measurement {
        var downloadMbps: Double = 0
        var uploadMbps: Double = 0
        var idleLatencyMs: Double?
        var loadedLatencyMs: Double?
        var jitterMs: Double?
        var server: String?
        var isp: String?
    }

    var downloadStreams = 6
    var uploadStreams = 4
    var phaseDuration: TimeInterval = 10
    var warmup: TimeInterval = 2

    private let base = "https://speed.cloudflare.com"
    private lazy var probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    func run(progress: @escaping (SpeedTestPhase, Double) -> Void,
             partial: @escaping (Measurement) -> Void) async throws -> Measurement {
        var result = Measurement()

        progress(.connecting, 0)
        let info = await serverInfo()
        result.server = info.server
        result.isp = info.isp

        // Idle latency: warm the connection, then take the median of 15 probes.
        progress(.latency, 0)
        _ = await probe()
        _ = await probe()
        var idle: [Double] = []
        for _ in 0..<15 {
            try Task.checkCancellation()
            if let ms = await probe() { idle.append(ms) }
        }
        guard !idle.isEmpty else {
            throw SpeedTestError.noData("Couldn't reach speed.cloudflare.com. It may be blocked on this network — try the Apple engine.")
        }
        result.idleLatencyMs = Parsers.median(idle)
        result.jitterMs = Parsers.jitter(idle)
        partial(result)

        var loaded: [Double] = []

        progress(.download, 0)
        result.downloadMbps = try await measure(.download, streams: downloadStreams, loadedLatency: &loaded) {
            progress(.download, $0)
        }
        partial(result)

        progress(.upload, 0)
        result.uploadMbps = try await measure(.upload, streams: uploadStreams, loadedLatency: &loaded) {
            progress(.upload, $0)
        }
        result.loadedLatencyMs = Parsers.median(loaded)
        return result
    }

    private func measure(_ direction: TransferStream.Direction, streams count: Int,
                         loadedLatency: inout [Double],
                         onRate: (Double) -> Void) async throws -> Double {
        let counter = ByteCounter()
        let payload = direction == .upload ? Data(count: 10_000_000) : nil
        let base = self.base
        let streams = (0..<count).map { _ in
            TransferStream(direction: direction, counter: counter, payload: payload) {
                let token = UUID().uuidString.prefix(8)
                var request: URLRequest
                if direction == .download {
                    request = URLRequest(url: URL(string: "\(base)/__down?bytes=25000000&r=\(token)")!)
                } else {
                    request = URLRequest(url: URL(string: "\(base)/__up?r=\(token)")!)
                    request.httpMethod = "POST"
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                }
                return request
            }
        }
        streams.forEach { $0.start() }
        defer { streams.forEach { $0.stop() } }

        let start = ProcessInfo.processInfo.systemUptime
        var samples: [(time: Double, bytes: UInt64)] = [(0, 0)]
        var nextProbe = 1.0

        while true {
            try await Task.sleep(nanoseconds: 200_000_000)
            try Task.checkCancellation()
            let t = ProcessInfo.processInfo.systemUptime - start
            let bytes = counter.value
            samples.append((t, bytes))

            // Live rate over the last second.
            let reference = samples.last { $0.time <= t - 1 } ?? samples[0]
            if t > reference.time {
                onRate(Double(bytes - reference.bytes) * 8 / (t - reference.time) / 1_000_000)
            }

            // Latency under load (a probe on its own connection).
            if t >= nextProbe {
                nextProbe = t + 0.5
                if let ms = await probe() { loadedLatency.append(ms) }
            }

            if t >= 4, bytes == 0 {
                throw SpeedTestError.noData(counter.lastError
                    ?? "No data received from Cloudflare. It may be blocked on this network — try the Apple engine.")
            }
            if t >= phaseDuration { break }
        }
        return Parsers.steadyStateMbps(samples, warmup: warmup)
    }

    /// Time for one tiny HTTP request on a warm connection ≈ one round trip.
    private func probe() async -> Double? {
        guard let url = URL(string: "\(base)/__down?bytes=0&r=\(UUID().uuidString.prefix(8))") else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        guard let (_, response) = try? await probeSession.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    /// Which Cloudflare data centre is serving us, and the ISP if available.
    private func serverInfo() async -> (server: String?, isp: String?) {
        var server: String?
        var isp: String?
        if let url = URL(string: "\(base)/cdn-cgi/trace"),
           let (data, _) = try? await probeSession.data(from: url) {
            let fields = Parsers.keyValueLines(String(decoding: data, as: UTF8.self))
            if let colo = fields["colo"] {
                server = "Cloudflare \(colo)" + (fields["loc"].map { " (\($0))" } ?? "")
            }
        }
        if let url = URL(string: "\(base)/meta"),
           let (data, _) = try? await probeSession.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            isp = json["asOrganization"] as? String
            if let city = json["city"] as? String, let colo = json["colo"] as? String {
                server = "Cloudflare \(colo) · \(city)"
            }
        }
        return (server, isp)
    }
}
