import SwiftUI
import AppKit

struct ConnectionView: View {
    @EnvironmentObject private var store: NetworkStore

    var body: some View {
        let c = store.connection
        VStack(alignment: .leading, spacing: 18) {
            ConnectionTypeHeader(connection: c, measured: store.measuredInterfaces)

            if c.isWiFi && c.ssid == nil && !store.locationAuthorized {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "location.slash").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Wi-Fi name is hidden").font(.headline)
                        Text("macOS only shares the network name (SSID) with apps that have Location access. NetPulse never reads your location.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Open Location Settings") { store.openLocationSettings() }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }

            if c.isWiFi {
                Panel(c.kind == .hotspotWiFi ? "Hotspot Wi-Fi link" : "Wi-Fi") {
                    InfoRow("Network", c.ssid ?? "Hidden")
                    InfoRow("Signal (RSSI)", c.rssi.map { "\($0) dBm · \(Format.signalQuality($0))" } ?? "—")
                    SignalBar(rssi: c.rssi)
                    InfoRow("Noise", c.noise.map { "\($0) dBm" } ?? "—")
                    InfoRow("Signal-to-noise", c.snr.map { "\($0) dB" } ?? "—")
                    InfoRow("Link rate (PHY)", c.transmitRateMbps.map { Format.rate($0) } ?? "—")
                    InfoRow("Standard", c.wifiStandard ?? "—")
                    InfoRow("Channel", [c.channel.map { "\($0)" }, c.band, c.channelWidth].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "—")
                    InfoRow("Security", c.security ?? "—")
                    InfoRow("Access point (BSSID)", c.bssid ?? "—")
                }
            } else if c.kind == .ethernet || c.kind == .hotspotUSB {
                Panel(c.kind == .ethernet ? "Ethernet" : "USB tethering") {
                    InfoRow("Adapter", c.hardwarePort ?? "—")
                    InfoRow("Link speed", c.linkSpeedMbps.map { Format.rate($0) } ?? "—")
                    InfoRow("Duplex", c.duplex ?? "—")
                }
            }

            Panel("Addresses", trailing: AnyView(Button {
                store.refreshConnection()
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(.link))) {
                InfoRow("Local IP", c.localIP ?? "—", copyable: c.localIP != nil)
                InfoRow("Subnet mask", c.netmask ?? "—")
                InfoRow("Router", c.gateway ?? "—", copyable: c.gateway != nil)
                InfoRow("DNS servers", c.dnsServers.isEmpty ? "—" : c.dnsServers.joined(separator: ", "))
                InfoRow("Public IP", c.publicIP ?? (c.kind == .none ? "—" : "Looking up…"), copyable: c.publicIP != nil)
            }

            Text("Link rate is the speed negotiated with the router or switch — the ceiling for this hop. Your actual internet throughput is on Live Speed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Big banner saying exactly how the Mac is connected.
struct ConnectionTypeHeader: View {
    let connection: ConnectionDetails
    let measured: [String]

    var body: some View {
        let c = connection
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: c.kind.symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(c.kind == .none ? Color.red : Color.accentColor)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(c.kind.label).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if c.vpnActive { Tag("VPN · \(c.vpnInterface ?? "")", color: .indigo) }
                    if c.isMetered { Tag("Metered", color: .orange) }
                    if c.isLowDataMode { Tag("Low Data Mode", color: .orange) }
                    if !measured.isEmpty { Tag("Measuring \(measured.joined(separator: ", "))", color: .gray) }
                }
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var subtitle: String {
        let c = connection
        let port = [c.hardwarePort, c.interfaceName].compactMap { $0 }.joined(separator: " · ")
        switch c.kind {
        case .hotspotWiFi: return "Phone hotspot over Wi-Fi — \(port)"
        case .hotspotUSB: return "Phone tethered by USB — \(port)"
        case .hotspotBluetooth: return "Phone tethered by Bluetooth — \(port)"
        case .none: return "No interface has a route to the internet"
        default: return port
        }
    }
}

struct Tag: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var copyable = false

    init(_ label: String, _ value: String, copyable: Bool = false) {
        self.label = label
        self.value = value
        self.copyable = copyable
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
        .font(.body)
        Divider()
    }
}

/// Signal strength as a coloured bar: -90 dBm (empty) … -30 dBm (full).
struct SignalBar: View {
    let rssi: Int?

    var body: some View {
        let fraction = rssi.map { min(max(Double($0 + 90) / 60, 0), 1) } ?? 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color(fraction)).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 6)
        .padding(.bottom, 4)
    }

    private func color(_ fraction: Double) -> Color {
        fraction > 0.6 ? .green : (fraction > 0.3 ? .orange : .red)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
