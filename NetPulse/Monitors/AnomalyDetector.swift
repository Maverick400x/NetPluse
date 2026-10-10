import Foundation

struct Insight: Identifiable, Hashable {
    enum Severity: String { case info, warning, critical }

    let id = UUID()
    let date: Date
    let severity: Severity
    let title: String
    let detail: String
}

/// Lightweight, explainable on-device anomaly detection.
///
/// Each metric keeps a rolling window of recent values. A new value is
/// flagged when its z-score (how many standard deviations it sits above the
/// rolling mean) exceeds the threshold. This is the baseline model; the
/// `ml/` folder trains an Isolation Forest on the exported CSV for comparison.
final class AnomalyDetector {
    let windowSize: Int
    let minimumSamples: Int
    let threshold: Double
    private var windows: [String: [Double]] = [:]

    init(windowSize: Int = 120, minimumSamples: Int = 30, threshold: Double = 3.0) {
        self.windowSize = windowSize
        self.minimumSamples = minimumSamples
        self.threshold = threshold
    }

    /// Adds a value and returns its z-score if it is anomalously high.
    /// `floor` is the smallest standard deviation used, so a very stable
    /// connection does not flag tiny wobbles (e.g. 2 ms for latency).
    func observe(_ metric: String, value: Double, floor: Double = 1) -> Double? {
        var window = windows[metric, default: []]
        var score: Double?

        if window.count >= minimumSamples {
            let mean = window.reduce(0, +) / Double(window.count)
            let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window.count)
            let deviation = max(variance.squareRoot(), floor)
            let z = (value - mean) / deviation
            if z > threshold { score = z }
        }

        window.append(value)
        if window.count > windowSize { window.removeFirst(window.count - windowSize) }
        windows[metric] = window
        return score
    }

    func baseline(_ metric: String) -> Double? {
        guard let window = windows[metric], !window.isEmpty else { return nil }
        return window.reduce(0, +) / Double(window.count)
    }

    func reset() { windows.removeAll() }
}
