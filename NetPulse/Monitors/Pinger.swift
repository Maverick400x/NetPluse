import Foundation

/// Measures latency with the system `ping` tool.
/// (Raw ICMP sockets would need root; /sbin/ping is setuid and works for any user.)
enum Pinger {
    /// Returns the round-trip time in milliseconds, or nil if the packet was lost.
    static func ping(host: String, timeoutMs: Int = 1500) async -> Double? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
        let output = await Shell.runAsync(
            "/sbin/ping",
            ["-c", "1", "-W", "\(timeoutMs)", "-t", "3", trimmed],
            timeout: 5
        )
        return Parsers.pingTime(output)
    }
}

/// Rolling latency statistics over the most recent probes.
struct LatencyStats {
    var average: Double?
    var minimum: Double?
    var maximum: Double?
    var jitter: Double?
    var packetLoss: Double = 0
    var samples: Int = 0

    init(results: [Double?]) {
        samples = results.count
        guard samples > 0 else { return }
        let ok = results.compactMap { $0 }
        packetLoss = Double(samples - ok.count) / Double(samples)
        guard !ok.isEmpty else { return }
        average = ok.reduce(0, +) / Double(ok.count)
        minimum = ok.min()
        maximum = ok.max()
        if ok.count > 1 {
            let diffs = zip(ok.dropFirst(), ok).map { abs($0 - $1) }
            jitter = diffs.reduce(0, +) / Double(diffs.count)
        }
    }
}
