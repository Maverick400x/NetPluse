import SwiftUI
import Charts

struct OverviewView: View {
    @EnvironmentObject private var store: NetworkStore

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: columns, spacing: 14) {
                StatCard(title: "Download", value: Format.rate(store.downloadMbps),
                         footnote: "Peak \(Format.rate(store.peakDownloadMbps))",
                         symbol: "arrow.down.circle.fill", tint: .blue)
                StatCard(title: "Upload", value: Format.rate(store.uploadMbps),
                         footnote: "Peak \(Format.rate(store.peakUploadMbps))",
                         symbol: "arrow.up.circle.fill", tint: .green)
                StatCard(title: "Ping", value: Format.latency(store.latencyMs),
                         footnote: "to \(store.pingHost) · loss \(Format.percent(store.latencyStats.packetLoss))",
                         symbol: "timer", tint: latencyTint)
                StatCard(title: store.connection.kind.label + (store.connection.vpnActive ? " + VPN" : ""),
                         value: connectionValue,
                         footnote: connectionFootnote,
                         symbol: store.connection.kind.symbol, tint: .purple)
                StatCard(title: "Devices", value: "\(store.devices.count)",
                         footnote: store.lastScan.map { "Scanned \($0.shortTime)" } ?? "Scanning…",
                         symbol: "laptopcomputer.and.iphone", tint: .teal)
                StatCard(title: "This session", value: Format.bytes(store.sessionReceived + store.sessionSent),
                         footnote: "↓ \(Format.bytes(store.sessionReceived))  ↑ \(Format.bytes(store.sessionSent))",
                         symbol: "chart.bar.fill", tint: .indigo)
            }

            Panel("Throughput — last 2 minutes") {
                RateChart(points: store.rateHistory)
                    .frame(height: 200)
            }

            if let latest = store.insights.first {
                Panel("Latest insight") {
                    InsightRow(insight: latest)
                }
            }
        }
    }

    private var latencyTint: Color {
        guard let ms = store.latencyMs else { return .red }
        return ms < 50 ? .green : (ms < 120 ? .orange : .red)
    }

    /// Headline number for the connection card: signal for Wi-Fi, link speed for cables.
    private var connectionValue: String {
        let c = store.connection
        if c.isWiFi { return c.rssi.map { "\($0) dBm" } ?? "—" }
        if let link = c.linkSpeedMbps { return Format.rate(link) }
        return c.kind == .none ? "Offline" : (c.interfaceName ?? "—")
    }

    private var connectionFootnote: String {
        let c = store.connection
        switch c.kind {
        case .wifi, .hotspotWiFi:
            let name = c.ssid ?? (store.locationAuthorized ? c.kind.label : "Name hidden")
            return "\(name) · \(Format.signalQuality(c.rssi))"
        case .ethernet, .hotspotUSB:
            let port = c.hardwarePort ?? c.interfaceName ?? ""
            return c.linkSpeedMbps == nil ? port : "\(port) · link speed"
        case .hotspotBluetooth:
            return c.hardwarePort ?? "Bluetooth PAN"
        case .other:
            return c.hardwarePort ?? c.interfaceName ?? ""
        case .none:
            return "No active network"
        }
    }
}

/// Download/upload line chart shared by Overview and Live Speed.
struct RateChart: View {
    let points: [NetworkStore.RatePoint]

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.time),
                         y: .value("Mbps", point.download),
                         series: .value("Direction", "Download"))
                    .foregroundStyle(.blue.opacity(0.15))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.time),
                         y: .value("Mbps", point.download),
                         series: .value("Direction", "Download"))
                    .foregroundStyle(by: .value("Direction", "Download"))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.time),
                         y: .value("Mbps", point.upload),
                         series: .value("Direction", "Upload"))
                    .foregroundStyle(by: .value("Direction", "Upload"))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.green])
        .chartYAxisLabel("Mbps")
        .chartXAxis {
            AxisMarks(values: .stride(by: .second, count: 30)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.minute().second())
            }
        }
        .overlay {
            if points.isEmpty {
                Text("Collecting data…").foregroundStyle(.secondary)
            }
        }
    }
}
