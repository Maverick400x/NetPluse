import SwiftUI
import Charts
import WidgetKit

/// The widget's look, shared by the real widget and the live preview on the
/// app's Customize page, so what you see while customising is exactly what
/// appears on the desktop.
struct WidgetContentView: View {
    let snapshot: NetSnapshot
    let family: WidgetFamily
    let settings: DisplaySettings

    private var s: NetSnapshot { snapshot }
    private var status: NetSnapshot.Status { s.isStale ? .offline : s.status }
    private var accent: DisplaySettings.Accent { settings.widgetAccent }
    private var onDark: Bool { settings.widgetBackground == .dark }

    var body: some View {
        Group {
            switch family {
            case .systemMedium: medium
            case .systemLarge: large
            default: small
            }
        }
        .environment(\.colorScheme, onDark ? .dark : colorSchemeFallback)
    }

    @Environment(\.colorScheme) private var colorSchemeFallback

    /// Background to put behind the content (used as the widget container background).
    static func background(_ settings: DisplaySettings) -> some ShapeStyle {
        switch settings.widgetBackground {
        case .standard:
            return AnyShapeStyle(.fill.tertiary)
        case .tinted:
            return AnyShapeStyle(LinearGradient(
                colors: [settings.widgetAccent.download.opacity(0.35), settings.widgetAccent.upload.opacity(0.15)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        case .dark:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.06, green: 0.08, blue: 0.16), Color(red: 0.03, green: 0.22, blue: 0.28)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    // MARK: Layouts

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            rateLine("arrow.down", s.downloadMbps, accent.download)
            if settings.widgetShowUpload {
                rateLine("arrow.up", s.uploadMbps, accent.upload)
            }
            Spacer(minLength: 0)
            if let first = settings.widgetMetrics.first {
                HStack(spacing: 4) {
                    Text(first.shortLabel).foregroundStyle(.secondary)
                    Text(value(for: first)).fontWeight(.semibold)
                }
                .font(.caption)
                .lineLimit(1)
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                header
                Spacer(minLength: 0)
                rateLine("arrow.down", s.downloadMbps, accent.download)
                if settings.widgetShowUpload {
                    rateLine("arrow.up", s.uploadMbps, accent.upload)
                }
                Spacer(minLength: 0)
                footer
            }
            .frame(maxWidth: settings.widgetShowChart ? 140 : .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                if settings.widgetShowChart {
                    sparkline.frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
                HStack {
                    ForEach(Array(settings.widgetMetrics.prefix(3))) { metric in
                        metricView(metric)
                    }
                }
                if !settings.widgetShowChart { Spacer(minLength: 0) }
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 18) {
                rateLine("arrow.down", s.downloadMbps, accent.download)
                if settings.widgetShowUpload {
                    rateLine("arrow.up", s.uploadMbps, accent.upload)
                }
            }
            if settings.widgetShowChart {
                sparkline.frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            let metrics = Array(settings.widgetMetrics.prefix(6))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                      alignment: .leading, spacing: 8) {
                ForEach(metrics) { metric in
                    metricView(metric)
                }
            }
            footer
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            if !s.isStale, let kind = s.connectionKind {
                Image(systemName: kind.symbol).font(.caption2.weight(.semibold))
            }
            Text(headerText)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
    }

    private var headerText: String {
        if s.isStale { return "App not running" }
        let kind = s.connectionKind ?? .wifi
        if kind.usesWiFiRadio, let ssid = s.ssid { return ssid }
        return kind.label + (s.vpnActive == true ? " + VPN" : "")
    }

    private var footer: some View {
        Text("Updated \(s.timestamp, style: .relative) ago")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var sparkline: some View {
        Chart {
            ForEach(Array(s.downloadHistory.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("t", index), y: .value("Mbps", value))
                    .foregroundStyle(.linearGradient(colors: [accent.download.opacity(0.35), accent.download.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", index), y: .value("Mbps", value), series: .value("s", "down"))
                    .foregroundStyle(accent.download)
                    .interpolationMethod(.monotone)
            }
            if settings.widgetShowUpload {
                ForEach(Array(s.uploadHistory.enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value("t", index), y: .value("Mbps", value), series: .value("s", "up"))
                        .foregroundStyle(accent.upload)
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    private func rateLine(_ symbol: String, _ mbps: Double, _ tint: Color) -> some View {
        let parts = Format.rate(mbps, unit: settings.widgetUnit).split(separator: " ", maxSplits: 1)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(tint)
            Text(parts.first.map(String.init) ?? "0")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
            Text(parts.count > 1 ? String(parts[1]) : "").font(.caption2).foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private func metricView(_ metric: DisplaySettings.WidgetMetric) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(metric.shortLabel).font(.caption2).foregroundStyle(.secondary)
            Text(value(for: metric)).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func value(for metric: DisplaySettings.WidgetMetric) -> String {
        switch metric {
        case .ping: return Format.latency(s.latencyMs)
        case .jitter: return Format.latency(s.jitterMs)
        case .loss: return Format.percent(s.packetLoss)
        case .devices: return "\(s.deviceCount)"
        case .signal:
            guard (s.connectionKind ?? .wifi).usesWiFiRadio else { return "Wired" }
            return s.rssi.map { "\($0) dBm" } ?? "—"
        case .connection: return (s.connectionKind ?? .other).label
        case .localIP: return s.localIP ?? "—"
        }
    }

    private var statusColor: Color {
        switch status {
        case .good: return .green
        case .degraded: return .orange
        case .offline: return .red
        }
    }
}
