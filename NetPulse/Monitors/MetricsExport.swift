import Foundation
import Network

/// Appends one row of metrics every few seconds to a CSV file.
/// This becomes the training dataset for the ML part of the project.
final class MetricsLogger {
    static let header = "timestamp,download_mbps,upload_mbps,latency_ms,jitter_ms,packet_loss,rssi_dbm,device_count,anomaly,connection_type,network,vpn\n"

    let fileURL: URL
    private let queue = DispatchQueue(label: "netpulse.logger")
    private let isoFormatter = ISO8601DateFormatter()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("NetPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("metrics.csv")
        // If an older version wrote a different set of columns, keep that file
        // aside instead of mixing two layouts in one CSV.
        if let handle = try? FileHandle(forReadingFrom: fileURL),
           let head = try? handle.read(upToCount: 512),
           (try? handle.close()) != nil,
           let firstLine = String(decoding: head, as: UTF8.self).split(separator: "\n", maxSplits: 1).first,
           String(firstLine) + "\n" != Self.header {
            let stamp = Int(Date().timeIntervalSince1970)
            let archived = folder.appendingPathComponent("metrics-old-\(stamp).csv")
            try? FileManager.default.moveItem(at: fileURL, to: archived)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? Self.header.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    func append(_ snapshot: NetSnapshot, anomaly: Bool) {
        func value(_ number: Double?) -> String { number.map { String(format: "%.3f", $0) } ?? "" }
        let row = [
            isoFormatter.string(from: snapshot.timestamp),
            value(snapshot.downloadMbps),
            value(snapshot.uploadMbps),
            value(snapshot.latencyMs),
            value(snapshot.jitterMs),
            value(snapshot.packetLoss),
            snapshot.rssi.map(String.init) ?? "",
            String(snapshot.deviceCount),
            anomaly ? "1" : "0",
            snapshot.connectionKind?.rawValue ?? "",
            Self.csvField(snapshot.ssid ?? ""),
            snapshot.vpnActive == true ? "1" : "0"
        ].joined(separator: ",") + "\n"

        queue.async { [fileURL] in
            guard let data = row.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Quotes a value if it contains a comma, quote or newline (RFC 4180).
    static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func clear() {
        queue.async { [fileURL] in
            try? Self.header.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}

/// Serves live metrics in Prometheus text format at http://<mac>:9464/metrics
/// so Prometheus + Grafana (see devops/) can scrape and graph them.
final class MetricsServer {
    let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "netpulse.metrics-server")
    private let lock = NSLock()
    private var body = "# NetPulse starting\n"
    private(set) var isRunning = false

    init(port: UInt16 = 9464) { self.port = port }

    func update(_ text: String) {
        lock.lock(); body = text; lock.unlock()
    }

    private func currentBody() -> String {
        lock.lock(); defer { lock.unlock() }
        return body
    }

    @discardableResult
    func start() -> Bool {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: .tcp, on: nwPort) else { return false }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let body = self.currentBody()
                let response = "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n"
                    + "Content-Length: \(body.utf8.count)\r\n"
                    + "Connection: close\r\n\r\n"
                    + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        isRunning = true
        return true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    /// Builds the Prometheus exposition text.
    static func render(snapshot: NetSnapshot, bytesIn: UInt64, bytesOut: UInt64, anomalies: Int,
                       speedTest: SpeedTestResult? = nil) -> String {
        var lines: [String] = []
        func metric(_ name: String, _ type: String, _ help: String, _ value: Double?) {
            lines.append("# HELP \(name) \(help)")
            lines.append("# TYPE \(name) \(type)")
            lines.append("\(name) \(value.map { String($0) } ?? "NaN")")
        }
        metric("netpulse_download_mbps", "gauge", "Current download rate in megabits per second.", snapshot.downloadMbps)
        metric("netpulse_upload_mbps", "gauge", "Current upload rate in megabits per second.", snapshot.uploadMbps)
        metric("netpulse_latency_ms", "gauge", "Last ping round-trip time in milliseconds.", snapshot.latencyMs)
        metric("netpulse_jitter_ms", "gauge", "Mean variation between consecutive pings.", snapshot.jitterMs)
        metric("netpulse_packet_loss_ratio", "gauge", "Share of recent pings that were lost (0-1).", snapshot.packetLoss)
        metric("netpulse_wifi_rssi_dbm", "gauge", "Wi-Fi signal strength in dBm.", snapshot.rssi.map(Double.init))
        metric("netpulse_devices", "gauge", "Devices found on the local network in the last scan.", Double(snapshot.deviceCount))
        metric("netpulse_received_bytes_total", "counter", "Bytes received since NetPulse started.", Double(bytesIn))
        metric("netpulse_sent_bytes_total", "counter", "Bytes sent since NetPulse started.", Double(bytesOut))
        metric("netpulse_anomalies_total", "counter", "Anomalies detected since NetPulse started.", Double(anomalies))
        metric("netpulse_up", "gauge", "1 when the network is reachable.", snapshot.status == .offline ? 0 : 1)
        if let test = speedTest {
            metric("netpulse_speedtest_download_mbps", "gauge", "Download capacity from the last internet speed test.", test.downloadMbps)
            metric("netpulse_speedtest_upload_mbps", "gauge", "Upload capacity from the last internet speed test.", test.uploadMbps)
            metric("netpulse_speedtest_idle_latency_ms", "gauge", "Idle latency measured by the last speed test.", test.idleLatencyMs)
            metric("netpulse_speedtest_loaded_latency_ms", "gauge", "Latency under load (bufferbloat) from the last speed test.", test.loadedLatencyMs)
            metric("netpulse_speedtest_timestamp_seconds", "gauge", "Unix time of the last speed test.", test.date.timeIntervalSince1970)
        }
        lines.append("# HELP netpulse_connection_info Current connection type (value is always 1).")
        lines.append("# TYPE netpulse_connection_info gauge")
        let kind = snapshot.connectionKind?.rawValue ?? "unknown"
        let vpn = snapshot.vpnActive == true ? "true" : "false"
        lines.append("netpulse_connection_info{type=\"\(kind)\",vpn=\"\(vpn)\"} 1")
        return lines.joined(separator: "\n") + "\n"
    }
}
