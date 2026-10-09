import SwiftUI

struct SpeedView: View {
    @EnvironmentObject private var store: NetworkStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                StatCard(title: "Download now", value: Format.rate(store.downloadMbps),
                         footnote: "Average \(Format.rate(average(\.download)))",
                         symbol: "arrow.down.circle.fill", tint: .blue)
                StatCard(title: "Upload now", value: Format.rate(store.uploadMbps),
                         footnote: "Average \(Format.rate(average(\.upload)))",
                         symbol: "arrow.up.circle.fill", tint: .green)
                StatCard(title: "Peak", value: Format.rate(store.peakDownloadMbps),
                         footnote: "Upload peak \(Format.rate(store.peakUploadMbps))",
                         symbol: "chart.line.uptrend.xyaxis", tint: .orange)
            }

            Panel("Live throughput",
                  trailing: AnyView(Button("Reset peaks") { store.resetPeaks() }.buttonStyle(.link))) {
                RateChart(points: store.rateHistory)
                    .frame(height: 320)
            }

            Text("NetPulse measures the bytes moving through your Wi-Fi and Ethernet interfaces every second — this is the traffic your Mac is actually using, not a speed test. To see your connection's maximum, run a large download or a speed test while watching this chart.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func average(_ key: KeyPath<NetworkStore.RatePoint, Double>) -> Double {
        let values = store.rateHistory.map { $0[keyPath: key] }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
