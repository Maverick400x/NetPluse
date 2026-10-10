import SwiftUI
import Charts

struct SpeedTestView: View {
    @EnvironmentObject private var store: NetworkStore
    @EnvironmentObject private var speedTest: SpeedTestController
    @State private var confirmMetered = false
    @State private var selection = Set<UUID>()

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            runPanel
            resultCards
            if !speedTest.liveSamples.isEmpty { liveChart }
            historyPanel
            automaticPanel
            Text("Live Speed shows the traffic your Mac is using right now. A speed test pushes as much data as the connection can carry to find its maximum capacity. Results depend on the test server, Wi-Fi signal and other devices using the network, so run a few tests and compare.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("This connection is metered", isPresented: $confirmMetered) {
            Button("Run speed test") { speedTest.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A speed test can use several hundred MB on a fast connection. You're on \(store.connection.kind.label), which may count against a data plan.")
        }
    }

    // MARK: - Run

    private var runPanel: some View {
        Panel("Internet speed test") {
            HStack(alignment: .center, spacing: 32) {
                SpeedGauge(mbps: gaugeValue, caption: speedTest.phase.label,
                           tint: speedTest.phase == .upload ? .green : .blue,
                           active: speedTest.isRunning)
                    .frame(width: 230, height: 230)

                VStack(alignment: .leading, spacing: 14) {
                    Label(connectionLine, systemImage: store.connection.kind.symbol)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Picker("Test server", selection: $speedTest.engine) {
                        ForEach(SpeedTestEngine.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 340)
                    .disabled(speedTest.isRunning)

                    if speedTest.engine == .apple {
                        Toggle("Test download and upload separately (more accurate, ~40 s)",
                               isOn: $speedTest.appleSequential)
                            .disabled(speedTest.isRunning)
                    } else {
                        Text("6 download and 4 upload streams, 10 s each, plus latency probes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        if speedTest.isRunning {
                            Button(role: .cancel) { speedTest.cancel() } label: {
                                Label("Stop", systemImage: "stop.fill").frame(minWidth: 120)
                            }
                            .controlSize(.large)
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                if store.connection.isMetered { confirmMetered = true } else { speedTest.start() }
                            } label: {
                                Label(speedTest.latest == nil ? "Start test" : "Run again", systemImage: "play.fill")
                                    .frame(minWidth: 120)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut("t", modifiers: [.command])
                            .disabled(store.connection.kind == .none)
                        }
                    }

                    if store.connection.isMetered && !speedTest.isRunning {
                        Label("Metered connection — a test can use several hundred MB.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if case .failed(let message) = speedTest.phase {
                        Label(message, systemImage: "xmark.octagon")
                            .font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var gaugeValue: Double {
        if speedTest.isRunning { return speedTest.liveMbps }
        return speedTest.latest?.downloadMbps ?? 0
    }

    private var connectionLine: String {
        let c = store.connection
        var parts = [c.kind.label]
        if let ssid = c.ssid, c.isWiFi { parts.append("“\(ssid)”") }
        if let interface = c.interfaceName { parts.append(interface) }
        if c.vpnActive { parts.append("via VPN") }
        return "Testing over " + parts.joined(separator: " · ")
    }

    // MARK: - Results

    /// While running, show what's measured so far; otherwise the latest result.
    private var resultCards: some View {
        let latest = speedTest.latest
        let running = speedTest.isRunning
        let down = running ? speedTest.partialDownload : latest?.downloadMbps
        let up = running ? speedTest.partialUpload : latest?.uploadMbps
        let idle = running ? speedTest.partialIdleLatency : latest?.idleLatencyMs
        return LazyVGrid(columns: columns, spacing: 14) {
            StatCard(title: "Download", value: down.map { Format.rate($0) } ?? "—",
                     footnote: latest.map { running ? "Previous \(Format.rate($0.downloadMbps))" : $0.date.formatted(date: .abbreviated, time: .shortened) },
                     symbol: "arrow.down.circle.fill", tint: .blue)
            StatCard(title: "Upload", value: up.map { Format.rate($0) } ?? "—",
                     footnote: latest.map { running ? "Previous \(Format.rate($0.uploadMbps))" : $0.engine.label },
                     symbol: "arrow.up.circle.fill", tint: .green)
            StatCard(title: "Idle latency", value: Format.latency(idle),
                     footnote: (running ? nil : latest?.jitterMs).map { "Jitter \(Format.latency($0))" } ?? "Unloaded round trip",
                     symbol: "timer", tint: .purple)
            StatCard(title: "Loaded latency", value: Format.latency(running ? nil : latest?.loadedLatencyMs),
                     footnote: (running ? nil : latest).flatMap { r in
                         r.bufferbloatMs.map { "+\(Format.latency($0)) · \(r.bufferbloatRating ?? "") bufferbloat" }
                     } ?? "Latency while busy",
                     symbol: "hourglass", tint: .orange)
            StatCard(title: "Data used", value: (running ? nil : latest?.dataUsedBytes).map(Format.bytes) ?? "—",
                     footnote: (running ? nil : latest).map { String(format: "%.0f s test", $0.durationSeconds) },
                     symbol: "externaldrive.connected.to.line.below", tint: .indigo)
            StatCard(title: "Server", value: (running ? nil : latest?.server) ?? "—",
                     footnote: (running ? nil : latest?.isp).map { "ISP: \($0)" },
                     symbol: "server.rack", tint: .teal)
        }
    }

    private var liveChart: some View {
        Panel("This test") {
            Chart(speedTest.liveSamples) { sample in
                LineMark(x: .value("Seconds", sample.time), y: .value("Mbps", sample.mbps),
                         series: .value("Phase", sample.phase))
                    .foregroundStyle(by: .value("Phase", sample.phase))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.green])
            .chartXAxisLabel("seconds")
            .chartYAxisLabel("Mbps")
            .frame(height: 160)
        }
    }

    // MARK: - History

    private var historyPanel: some View {
        Panel("History", trailing: AnyView(HStack(spacing: 12) {
            Button("Show CSV in Finder") { speedTest.revealCSV() }
            Button("Delete selected", role: .destructive) {
                speedTest.delete(selection)
                selection.removeAll()
            }
            .disabled(selection.isEmpty)
        }.buttonStyle(.link))) {
            if speedTest.history.isEmpty {
                Text("No tests yet. Results are saved with the network and connection type, so you can compare Wi-Fi, hotspot and Ethernet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                if speedTest.history.count > 1 {
                    Chart {
                        ForEach(speedTest.history) { r in
                            LineMark(x: .value("Date", r.date), y: .value("Mbps", r.downloadMbps),
                                     series: .value("Direction", "Download"))
                                .foregroundStyle(by: .value("Direction", "Download"))
                            PointMark(x: .value("Date", r.date), y: .value("Mbps", r.downloadMbps))
                                .foregroundStyle(by: .value("Direction", "Download"))
                            LineMark(x: .value("Date", r.date), y: .value("Mbps", r.uploadMbps),
                                     series: .value("Direction", "Upload"))
                                .foregroundStyle(by: .value("Direction", "Upload"))
                            PointMark(x: .value("Date", r.date), y: .value("Mbps", r.uploadMbps))
                                .foregroundStyle(by: .value("Direction", "Upload"))
                        }
                    }
                    .chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.green])
                    .chartYAxisLabel("Mbps")
                    .frame(height: 170)
                }

                Table(speedTest.history, selection: $selection) {
                    TableColumn("Date") { r in
                        Text(r.date.formatted(date: .abbreviated, time: .shortened))
                    }
                    .width(min: 130, ideal: 150)
                    TableColumn("Network") { r in
                        Label(r.networkName ?? (r.connectionKind?.label ?? "—"),
                              systemImage: (r.connectionKind ?? .other).symbol)
                    }
                    .width(min: 130, ideal: 170)
                    TableColumn("Download") { r in Text(Format.rate(r.downloadMbps)).monospacedDigit() }
                        .width(min: 80, ideal: 90)
                    TableColumn("Upload") { r in Text(Format.rate(r.uploadMbps)).monospacedDigit() }
                        .width(min: 80, ideal: 90)
                    TableColumn("Ping") { r in Text(Format.latency(r.idleLatencyMs)).monospacedDigit() }
                        .width(min: 60, ideal: 70)
                    TableColumn("Loaded") { r in Text(Format.latency(r.loadedLatencyMs)).monospacedDigit() }
                        .width(min: 60, ideal: 70)
                    TableColumn("Data") { r in Text(r.dataUsedBytes.map(Format.bytes) ?? "—").monospacedDigit() }
                        .width(min: 60, ideal: 80)
                    TableColumn("Server") { r in
                        Text(r.engine.shortLabel + (r.automatic ? " · auto" : "")).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 220)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    Button("Delete", role: .destructive) { speedTest.delete(ids) }
                }

                averages
            }
        }
    }

    /// Average per connection type — handy for comparing Wi-Fi vs hotspot vs Ethernet.
    private var averages: some View {
        let groups = Dictionary(grouping: speedTest.history) { $0.connectionKind ?? .other }
            .sorted { $0.value.count > $1.value.count }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Averages by connection").font(.subheadline.weight(.semibold))
            ForEach(groups, id: \.key) { group in
                let kind = group.key
                let results = group.value
                let down = results.map(\.downloadMbps).reduce(0, +) / Double(results.count)
                let up = results.map(\.uploadMbps).reduce(0, +) / Double(results.count)
                let pings = results.compactMap(\.idleLatencyMs)
                HStack {
                    Label(kind.label, systemImage: kind.symbol).frame(width: 190, alignment: .leading)
                    Text("↓ \(Format.rate(down))").frame(width: 110, alignment: .leading)
                    Text("↑ \(Format.rate(up))").frame(width: 110, alignment: .leading)
                    Text("ping \(Format.latency(pings.isEmpty ? nil : pings.reduce(0, +) / Double(pings.count)))")
                    Spacer()
                    Text("\(results.count) test\(results.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
                .font(.callout)
                .monospacedDigit()
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Automatic

    private var automaticPanel: some View {
        Panel("Automatic tests") {
            Picker("Run a test", selection: $speedTest.autoIntervalHours) {
                Text("Off").tag(0)
                Text("Every hour").tag(1)
                Text("Every 3 hours").tag(3)
                Text("Every 6 hours").tag(6)
                Text("Every 12 hours").tag(12)
                Text("Daily").tag(24)
            }
            .frame(maxWidth: 320)
            Toggle("Skip on metered connections (phone hotspots)", isOn: $speedTest.autoSkipMetered)
                .disabled(speedTest.autoIntervalHours == 0)
            Text("Runs while NetPulse is open, using the selected test server. Scheduled results are marked “auto” and build up a dataset for the project report.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A 270° speedometer with a logarithmic scale (0 → 1 Gbps), so both slow
/// hotspots and fast fibre move the needle visibly.
struct SpeedGauge: View {
    let mbps: Double
    let caption: String
    let tint: Color
    let active: Bool

    private static let maxMbps = 1000.0
    private var fraction: Double {
        min(1, log10(max(mbps, 0) + 1) / log10(Self.maxMbps + 1))
    }

    var body: some View {
        let parts = Format.rate(mbps).split(separator: " ", maxSplits: 1).map(String.init)
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * fraction)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeOut(duration: 0.45), value: fraction)

            ForEach([1.0, 10, 100, 1000], id: \.self) { mark in
                tickLabel(mark)
            }

            VStack(spacing: 2) {
                Text(parts.first ?? "0")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(parts.count > 1 ? parts[1] : "Mbps")
                    .font(.headline).foregroundStyle(.secondary)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(active ? tint : Color.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(8)
    }

    private func tickLabel(_ value: Double) -> some View {
        let f = log10(value + 1) / log10(Self.maxMbps + 1)
        let angle = Angle.degrees(135 + 270 * f)
        let label = value >= 1000 ? "1G" : String(format: "%.0f", value)
        return GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2 - 30
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .position(x: geo.size.width / 2 + r * cos(angle.radians),
                          y: geo.size.height / 2 + r * sin(angle.radians))
        }
    }
}
