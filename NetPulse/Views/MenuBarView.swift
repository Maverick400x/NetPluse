import SwiftUI
import Charts
import AppKit

/// The popover that opens from the menu bar item.
struct MenuBarView: View {
    @EnvironmentObject private var store: NetworkStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("NetPulse").font(.headline)
                Spacer()
                StatusBadge(status: store.status)
            }

            HStack(spacing: 10) {
                rate("Download", store.downloadMbps, "arrow.down", .blue)
                rate("Upload", store.uploadMbps, "arrow.up", .green)
            }

            Chart(store.rateHistory.suffix(60)) { point in
                LineMark(x: .value("t", point.time), y: .value("Mbps", point.download), series: .value("d", "Down"))
                    .foregroundStyle(.blue)
                LineMark(x: .value("t", point.time), y: .value("Mbps", point.upload), series: .value("d", "Up"))
                    .foregroundStyle(.green)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 60)

            Divider()

            row("timer", "Ping", "\(Format.latency(store.latencyMs)) · loss \(Format.percent(store.latencyStats.packetLoss))")
            row(store.connection.kind.symbol, connectionTitle, connectionValue)
            row("laptopcomputer.and.iphone", "Devices", "\(store.devices.count)")
            if let insight = store.insights.first, Date().timeIntervalSince(insight.date) < 600 {
                row(insight.severity.symbol, insight.title, insight.date.shortTime)
                    .foregroundStyle(insight.severity.color)
            }

            Divider()

            HStack {
                Button("Open NetPulse") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var connectionTitle: String {
        let c = store.connection
        var title = c.kind.label
        if let ssid = c.ssid, c.isWiFi { title += " · \(ssid)" }
        if c.vpnActive { title += " + VPN" }
        return title
    }

    private var connectionValue: String {
        let c = store.connection
        if c.isWiFi, let rssi = c.rssi { return "\(rssi) dBm" }
        if let link = c.linkSpeedMbps { return Format.rate(link) }
        return c.localIP ?? "—"
    }

    private func rate(_ title: String, _ mbps: Double, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(Format.rate(mbps))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: NetworkStore

    var body: some View {
        Form {
            Text("Menu bar and widget appearance are in the Customize section of the main window.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Log metrics to CSV", isOn: $store.loggingEnabled)
            Toggle("Prometheus endpoint on port \(String(store.metricsServer.port))", isOn: $store.metricsServerEnabled)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
