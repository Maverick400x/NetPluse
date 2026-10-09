import Foundation
import SwiftUI

/// User choices for how the menu bar item and the desktop widget look.
/// Stored in the App Group so the widget sees changes immediately.
struct DisplaySettings: Codable, Equatable {

    // MARK: Menu bar

    enum MenuBarStyle: String, Codable, CaseIterable, Identifiable {
        case speed, stacked, downloadOnly, uploadOnly, speedAndPing, ping, iconOnly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .speed: return "Download + upload"
            case .stacked: return "Stacked (two lines)"
            case .downloadOnly: return "Download only"
            case .uploadOnly: return "Upload only"
            case .speedAndPing: return "Speed + ping"
            case .ping: return "Ping only"
            case .iconOnly: return "Icon only"
            }
        }
    }

    enum RateUnit: String, Codable, CaseIterable, Identifiable {
        case bits, bytes
        var id: String { rawValue }
        var label: String { self == .bits ? "Bits (Mbps)" : "Bytes (MB/s)" }
    }

    var menuBarStyle: MenuBarStyle = .speed
    var menuBarUnit: RateUnit = .bits
    var menuBarCompact = false          // "1.2M" instead of "1.2 Mbps"
    var menuBarShowIcon = false         // connection-type icon before the numbers
    var menuBarShowArrows = true
    var menuBarFixedWidth = true        // stops neighbouring icons jumping around
    var menuBarAverageSeconds = 1       // 1 = live, 3 or 5 = smoothed

    // MARK: Widget

    enum Accent: String, Codable, CaseIterable, Identifiable {
        case blue, teal, purple, pink, orange, green
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var download: Color {
            switch self {
            case .blue: return .blue
            case .teal: return .teal
            case .purple: return .purple
            case .pink: return .pink
            case .orange: return .orange
            case .green: return .green
            }
        }
        var upload: Color {
            switch self {
            case .blue: return .green
            case .teal: return .mint
            case .purple: return .pink
            case .pink: return .purple
            case .orange: return .yellow
            case .green: return .blue
            }
        }
    }

    enum WidgetBackground: String, Codable, CaseIterable, Identifiable {
        case standard, tinted, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .standard: return "System"
            case .tinted: return "Tinted"
            case .dark: return "Dark"
            }
        }
    }

    enum WidgetMetric: String, Codable, CaseIterable, Identifiable {
        case ping, jitter, loss, devices, signal, connection, localIP
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ping: return "Ping"
            case .jitter: return "Jitter"
            case .loss: return "Packet loss"
            case .devices: return "Devices"
            case .signal: return "Wi-Fi signal"
            case .connection: return "Connection type"
            case .localIP: return "Local IP"
            }
        }
        var shortLabel: String {
            switch self {
            case .ping: return "Ping"
            case .jitter: return "Jitter"
            case .loss: return "Loss"
            case .devices: return "Devices"
            case .signal: return "Signal"
            case .connection: return "Link"
            case .localIP: return "IP"
            }
        }
    }

    var widgetAccent: Accent = .blue
    var widgetBackground: WidgetBackground = .standard
    var widgetUnit: RateUnit = .bits
    var widgetShowChart = true
    var widgetShowUpload = true
    /// Shown in order; medium widget uses the first 3, large the first 6.
    var widgetMetrics: [WidgetMetric] = [.ping, .loss, .devices, .signal, .jitter, .localIP]

    static let standard = DisplaySettings()

    // Tolerant decoding: a setting added in a later version falls back to its
    // default instead of discarding everything the user chose.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplaySettings()
        menuBarStyle = (try? c.decode(MenuBarStyle.self, forKey: .menuBarStyle)) ?? d.menuBarStyle
        menuBarUnit = (try? c.decode(RateUnit.self, forKey: .menuBarUnit)) ?? d.menuBarUnit
        menuBarCompact = (try? c.decode(Bool.self, forKey: .menuBarCompact)) ?? d.menuBarCompact
        menuBarShowIcon = (try? c.decode(Bool.self, forKey: .menuBarShowIcon)) ?? d.menuBarShowIcon
        menuBarShowArrows = (try? c.decode(Bool.self, forKey: .menuBarShowArrows)) ?? d.menuBarShowArrows
        menuBarFixedWidth = (try? c.decode(Bool.self, forKey: .menuBarFixedWidth)) ?? d.menuBarFixedWidth
        menuBarAverageSeconds = (try? c.decode(Int.self, forKey: .menuBarAverageSeconds)) ?? d.menuBarAverageSeconds
        widgetAccent = (try? c.decode(Accent.self, forKey: .widgetAccent)) ?? d.widgetAccent
        widgetBackground = (try? c.decode(WidgetBackground.self, forKey: .widgetBackground)) ?? d.widgetBackground
        widgetUnit = (try? c.decode(RateUnit.self, forKey: .widgetUnit)) ?? d.widgetUnit
        widgetShowChart = (try? c.decode(Bool.self, forKey: .widgetShowChart)) ?? d.widgetShowChart
        widgetShowUpload = (try? c.decode(Bool.self, forKey: .widgetShowUpload)) ?? d.widgetShowUpload
        widgetMetrics = (try? c.decode([WidgetMetric].self, forKey: .widgetMetrics)) ?? d.widgetMetrics
    }
}

extension SharedStore {
    private static let settingsKey = "netpulse.displaySettings"

    static func saveSettings(_ settings: DisplaySettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
    }

    static func loadSettings() -> DisplaySettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(DisplaySettings.self, from: data) else {
            return .standard
        }
        return settings
    }
}

extension Format {
    /// Rate in the chosen unit. 1 Mbps = 1,000,000 bit/s; 1 MB/s = 1,000,000 byte/s.
    static func rate(_ mbps: Double, unit: DisplaySettings.RateUnit, compact: Bool = false) -> String {
        let value = unit == .bits ? mbps * 1_000_000 : mbps * 1_000_000 / 8   // bits/s or bytes/s
        let steps: [(Double, String, String)] = unit == .bits
            ? [(1e9, "Gbps", "G"), (1e6, "Mbps", "M"), (1e3, "Kbps", "K")]
            : [(1e9, "GB/s", "GB"), (1e6, "MB/s", "MB"), (1e3, "KB/s", "KB")]
        let step = steps.first { value >= $0.0 } ?? steps[steps.count - 1]   // below 1 K stays in K
        let scaled = value / step.0
        let number = scaled >= 10 || scaled == 0 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
        return compact ? number + step.2 : number + " " + step.1
    }
}
