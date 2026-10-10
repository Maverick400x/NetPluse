import SwiftUI
import Charts

struct LatencyView: View {
    @EnvironmentObject private var store: NetworkStore
    @State private var hostDraft = ""

    private let presets = ["1.1.1.1", "8.8.8.8", "google.com", "apple.com"]

    var body: some View {
        let stats = store.latencyStats
        VStack(alignment: .leading, spacing: 18) {
            Panel("Target") {
                HStack {
                    TextField("Host or IP address", text: $hostDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit(apply)
                    Button("Ping", action: apply)
                        .keyboardShortcut(.defaultAction)
                    Divider().frame(height: 18)
                    ForEach(presets, id: \.self) { preset in
                        Button(preset) { hostDraft = preset; apply() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    if let gateway = store.connection.gateway {
                        Button("Router (\(gateway))") { hostDraft = gateway; apply() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            HStack(spacing: 14) {
                StatCard(title: "Average", value: Format.latency(stats.average), symbol: "timer", tint: .blue)
                StatCard(title: "Min / Max", value: "\(Format.latency(stats.minimum)) / \(Format.latency(stats.maximum))",
                         symbol: "arrow.up.and.down", tint: .purple)
                StatCard(title: "Jitter", value: Format.latency(stats.jitter), symbol: "waveform", tint: .orange)
                StatCard(title: "Packet loss", value: Format.percent(stats.packetLoss),
                         footnote: "last \(stats.samples) pings", symbol: "xmark.circle",
                         tint: stats.packetLoss > 0.02 ? .red : .green)
            }

            Panel("Latency to \(store.pingHost)") {
                Chart {
                    ForEach(store.latencyHistory.suffix(150)) { point in
                        if let ms = point.ms {
                            LineMark(x: .value("Time", point.time), y: .value("ms", ms))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(.blue)
                        } else {
                            RuleMark(x: .value("Time", point.time))
                                .foregroundStyle(.red.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                    if let average = stats.average {
                        RuleMark(y: .value("Average", average))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("avg \(Format.latency(average))").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                }
                .chartYAxisLabel("ms")
                .frame(height: 280)
                .overlay {
                    if store.latencyHistory.isEmpty { Text("Waiting for first reply…").foregroundStyle(.secondary) }
                }

                Label("Red lines mark lost packets. A ping every 2 seconds.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { hostDraft = store.pingHost }
    }

    private func apply() {
        let host = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host != store.pingHost else { return }
        store.pingHost = host
    }
}
