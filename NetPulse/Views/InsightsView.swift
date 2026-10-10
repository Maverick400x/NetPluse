import SwiftUI

struct InsightsView: View {
    @EnvironmentObject private var store: NetworkStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Panel("Anomaly detection",
                  trailing: store.insights.isEmpty ? nil
                    : AnyView(Button("Clear") { store.clearInsights() }.buttonStyle(.link))) {
                Text("NetPulse learns the normal latency of your connection (rolling 4-minute baseline) and flags pings more than 3 standard deviations above it, plus rule-based checks for packet loss, jitter, weak signal, network changes and new devices.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if store.insights.isEmpty {
                    Label("No issues detected yet. The baseline needs about a minute of data.", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                        .padding(.vertical, 8)
                } else {
                    ForEach(store.insights.prefix(50)) { insight in
                        InsightRow(insight: insight)
                        Divider()
                    }
                }
            }

            Panel("Data export (for ML & DevOps)") {
                HStack(alignment: .top) {
                    Image(systemName: "tablecells").foregroundStyle(.blue).frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Log metrics to CSV every 5 seconds", isOn: $store.loggingEnabled)
                        Text(store.logger.fileURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack {
                            Button("Show in Finder") { store.revealLog() }
                            Button("Clear log") { store.logger.clear() }
                        }
                    }
                }
                Divider()
                HStack(alignment: .top) {
                    Image(systemName: "server.rack").foregroundStyle(.orange).frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Prometheus metrics endpoint", isOn: $store.metricsServerEnabled)
                        Text(store.metricsServerRunning
                             ? "Serving at http://localhost:\(store.metricsServer.port)/metrics"
                             : "Stopped")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Point Prometheus at this endpoint (see devops/ in the project) and graph it in Grafana.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: insight.severity.symbol)
                .foregroundStyle(insight.severity.color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(insight.title).font(.headline)
                    Spacer()
                    Text(insight.date.shortTime).font(.caption).foregroundStyle(.secondary)
                }
                Text(insight.detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
