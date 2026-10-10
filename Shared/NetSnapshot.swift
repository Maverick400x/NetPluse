import Foundation

/// How this Mac is connected to the internet.
enum ConnectionKind: String, Codable, CaseIterable {
    case wifi
    case hotspotWiFi
    case hotspotUSB
    case hotspotBluetooth
    case ethernet
    case other
    case none

    var label: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .hotspotWiFi: return "Hotspot (Wi-Fi)"
        case .hotspotUSB: return "Hotspot (USB)"
        case .hotspotBluetooth: return "Hotspot (Bluetooth)"
        case .ethernet: return "Ethernet"
        case .other: return "Other"
        case .none: return "Not connected"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: return "wifi"
        case .hotspotWiFi, .hotspotUSB, .hotspotBluetooth: return "personalhotspot"
        case .ethernet: return "cable.connector"
        case .other: return "network"
        case .none: return "wifi.slash"
        }
    }

    var isHotspot: Bool {
        self == .hotspotWiFi || self == .hotspotUSB || self == .hotspotBluetooth
    }

    /// Wi-Fi radio metrics (signal, noise, channel) only exist on these.
    var usesWiFiRadio: Bool { self == .wifi || self == .hotspotWiFi }
}

/// A compact summary of the network state that the main app writes and the
/// desktop widget reads. Shared through an App Group container.
struct NetSnapshot: Codable, Equatable {
    enum Status: String, Codable {
        case good, degraded, offline

        var label: String {
            switch self {
            case .good: return "Healthy"
            case .degraded: return "Degraded"
            case .offline: return "Offline"
            }
        }
    }

    var timestamp: Date
    var downloadMbps: Double
    var uploadMbps: Double
    var latencyMs: Double?
    var jitterMs: Double?
    var packetLoss: Double          // 0...1
    var ssid: String?
    var rssi: Int?
    var localIP: String?
    var deviceCount: Int
    var downloadHistory: [Double]   // Mbps, oldest first
    var uploadHistory: [Double]
    var status: Status
    var connectionKind: ConnectionKind? = nil
    var vpnActive: Bool? = nil
    var speedTestDownMbps: Double? = nil
    var speedTestUpMbps: Double? = nil
    var speedTestDate: Date? = nil

    static let placeholder = NetSnapshot(
        timestamp: Date(),
        downloadMbps: 42.5,
        uploadMbps: 8.1,
        latencyMs: 18,
        jitterMs: 2.4,
        packetLoss: 0,
        ssid: "Home Wi-Fi",
        rssi: -52,
        localIP: "192.168.1.24",
        deviceCount: 9,
        downloadHistory: [12, 18, 30, 25, 40, 42, 38, 45, 50, 42],
        uploadHistory: [2, 3, 5, 4, 6, 8, 7, 9, 8, 8],
        status: .good,
        connectionKind: .wifi,
        vpnActive: false,
        speedTestDownMbps: 94.2,
        speedTestUpMbps: 38.5,
        speedTestDate: Date()
    )

    /// True when the app has not refreshed the snapshot for a while
    /// (usually because NetPulse is not running).
    var isStale: Bool { Date().timeIntervalSince(timestamp) > 10 * 60 }
}

/// Reads and writes the latest snapshot in the shared App Group defaults.
enum SharedStore {
    private static let key = "netpulse.latestSnapshot"

    /// The App Group ID is injected into each target's Info.plist at build
    /// time (see project.yml), so it always carries your Team ID prefix.
    static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
    }

    static var defaults: UserDefaults {
        if let id = groupID, let shared = UserDefaults(suiteName: id) {
            return shared
        }
        return .standard
    }

    static func save(_ snapshot: NetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> NetSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(NetSnapshot.self, from: data)
    }
}

/// Formatting helpers used by both the app and the widget.
enum Format {
    /// Formats a rate given in megabits per second.
    static func rate(_ mbps: Double) -> String {
        if mbps >= 1000 { return String(format: "%.2f Gbps", mbps / 1000) }
        if mbps >= 10 { return String(format: "%.0f Mbps", mbps) }
        if mbps >= 1 { return String(format: "%.1f Mbps", mbps) }
        return String(format: "%.0f Kbps", mbps * 1000)
    }

    /// Short number without the unit, for tight spaces (menu bar, small widget).
    static func compactRate(_ mbps: Double) -> String {
        if mbps >= 100 { return String(format: "%.0f", mbps) }
        if mbps >= 10 { return String(format: "%.1f", mbps) }
        return String(format: "%.2f", mbps)
    }

    static func latency(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        return ms >= 100 ? String(format: "%.0f ms", ms) : String(format: "%.1f ms", ms)
    }

    static func percent(_ ratio: Double) -> String {
        String(format: "%.0f%%", ratio * 100)
    }

    /// Decimal units (1 KB = 1000 bytes), consistent with the decimal
    /// bit rates (1 Mbps = 1,000,000 bits/s) used everywhere else.
    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .decimal)
    }

    /// Rough human description of a Wi-Fi RSSI value in dBm.
    static func signalQuality(_ rssi: Int?) -> String {
        guard let rssi else { return "—" }
        switch rssi {
        case (-55)...: return "Excellent"
        case (-67)...: return "Good"
        case (-75)...: return "Fair"
        default: return "Weak"
        }
    }
}
