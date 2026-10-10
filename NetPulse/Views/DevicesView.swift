import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var store: NetworkStore
    @State private var search = ""

    private var filtered: [NetworkDevice] {
        guard !search.isEmpty else { return store.devices }
        return store.devices.filter {
            $0.ip.contains(search) || $0.mac.localizedCaseInsensitiveContains(search)
                || ($0.hostname ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.devices.count) devices on \(store.connection.ssid ?? "this network")")
                        .font(.title3.weight(.semibold))
                    Text(store.lastScan.map { "Last scan \($0.shortTime) · rescans every 5 minutes" } ?? "Scanning the network…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button {
                    store.scanDevices()
                } label: {
                    if store.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Scan now", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .disabled(store.isScanning || store.connection.localIP == nil)
            }

            Table(filtered) {
                TableColumn("Device") { device in
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: device))
                            .foregroundStyle(device.isThisMac ? Color.accentColor : Color.secondary)
                            .frame(width: 18)
                        Text(device.hostname ?? "Unknown device")
                            .foregroundStyle(device.hostname == nil ? Color.secondary : Color.primary)
                    }
                }
                .width(min: 180, ideal: 240)
                TableColumn("IP address") { device in
                    Text(device.ip).monospacedDigit().textSelection(.enabled)
                }
                .width(min: 110, ideal: 130)
                TableColumn("MAC address") { device in
                    Text(device.mac).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                .width(min: 150, ideal: 170)
                TableColumn("Notes") { device in
                    Text(notes(for: device)).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 380)

            Text("Devices are found by probing every address on your subnet and reading the Mac's ARP table. Phones often use a private (randomised) MAC, so they may show up as new devices after reconnecting. Some devices ignore probes while asleep.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func icon(for device: NetworkDevice) -> String {
        if device.isThisMac { return "laptopcomputer" }
        if device.isGateway { return "wifi.router" }
        if device.usesPrivateMAC { return "iphone" }
        return "network"
    }

    private func notes(for device: NetworkDevice) -> String {
        var parts: [String] = []
        if device.isThisMac { parts.append("This Mac") }
        if device.isGateway { parts.append("Router / gateway") }
        if device.usesPrivateMAC { parts.append("Private MAC (likely phone/laptop)") }
        return parts.joined(separator: " · ")
    }
}
