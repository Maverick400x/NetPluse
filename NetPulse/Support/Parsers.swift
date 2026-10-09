import Foundation

/// Pure text parsers for the output of macOS command-line tools.
/// Kept free of side effects so they can be unit-tested (see NetPulseTests).
enum Parsers {

    /// Extracts the round-trip time from `ping -c 1` output,
    /// e.g. "64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=14.832 ms" → 14.832
    static func pingTime(_ output: String) -> Double? {
        guard let range = output.range(of: "time=") else { return nil }
        let number = output[range.upperBound...].prefix { "0123456789.".contains($0) }
        return Double(number)
    }

    /// Parses `route -n get default` → (gateway, interface).
    static func defaultRoute(_ output: String) -> (gateway: String?, interface: String?) {
        var gateway: String?
        var interface: String?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "gateway": gateway = parts[1]
            case "interface": interface = parts[1]
            default: break
            }
        }
        return (gateway, interface)
    }

    /// Parses `/etc/resolv.conf` style text into nameserver addresses.
    static func nameservers(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "nameserver" else { return nil }
            return String(fields[1])
        }
    }

    struct ARPEntry: Equatable {
        let ip: String
        let mac: String
        let interface: String?
    }

    /// Parses `arp -an` output. Incomplete entries and broadcast/multicast
    /// addresses are skipped.
    /// Example line: "? (192.168.1.1) at a4:2b:b0:1:2:3 on en0 ifscope [ethernet]"
    static func arpTable(_ output: String) -> [ARPEntry] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard let open = line.firstIndex(of: "("),
                  let close = line.firstIndex(of: ")"),
                  open < close else { return nil }
            let ip = String(line[line.index(after: open)..<close])

            let fields = line.split(separator: " ").map(String.init)
            guard let atIndex = fields.firstIndex(of: "at"), atIndex + 1 < fields.count else { return nil }
            let rawMac = fields[atIndex + 1]
            guard rawMac.contains(":") else { return nil }          // "(incomplete)"
            let mac = normalizeMAC(rawMac)
            guard mac != "ff:ff:ff:ff:ff:ff" else { return nil }
            if ip.hasSuffix(".255") || ip.hasPrefix("224.") || ip.hasPrefix("239.") { return nil }

            var iface: String?
            if let onIndex = fields.firstIndex(of: "on"), onIndex + 1 < fields.count {
                iface = fields[onIndex + 1]
            }
            return ARPEntry(ip: ip, mac: mac, interface: iface)
        }
    }

    /// macOS prints MAC octets without leading zeros ("a4:2b:0:1:2:3").
    static func normalizeMAC(_ mac: String) -> String {
        mac.split(separator: ":")
            .map { $0.count == 1 ? "0" + String($0) : String($0) }
            .joined(separator: ":")
            .lowercased()
    }

    /// True when the MAC is "locally administered" — iPhones, Androids and
    /// Macs use these random/private addresses for Wi-Fi privacy.
    static func isPrivateMAC(_ mac: String) -> Bool {
        guard let first = mac.split(separator: ":").first,
              let value = UInt8(first, radix: 16) else { return false }
        return value & 0x02 != 0
    }

    /// Converts dotted IPv4 to a 32-bit integer.
    static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    static func uint32ToIPv4(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    /// Host addresses to probe for a given address and netmask.
    /// Large subnets are clamped to the /24 around the Mac to keep scans fast.
    static func scanTargets(ip: String, netmask: String) -> [String] {
        guard let addr = ipv4ToUInt32(ip), var mask = ipv4ToUInt32(netmask) else { return [] }
        if mask < 0xFFFF_FF00 { mask = 0xFFFF_FF00 }
        let network = addr & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return ((network + 1)..<broadcast)
            .filter { $0 != addr }
            .map(uint32ToIPv4)
    }

    // MARK: - Connection type

    /// Hardware family of an interface, as reported by SystemConfiguration.
    enum HardwareType: Equatable {
        case wifi, ethernet, bluetooth, wwan, other
    }

    /// VPN and tunnel interfaces carry traffic on top of a physical one.
    static func isTunnel(_ bsdName: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf"].contains { bsdName.hasPrefix($0) }
    }

    /// iPhone Personal Hotspot always hands out 172.20.10.0/28.
    static func isIPhoneHotspotAddress(_ ip: String?) -> Bool {
        guard let ip, let value = ipv4ToUInt32(ip) else { return false }
        return value & 0xFFFF_FFF0 == 0xAC14_0A00          // 172.20.10.0/28
    }

    /// Decides how the Mac is connected.
    /// - Parameters:
    ///   - hardware: interface family from SystemConfiguration.
    ///   - displayName: e.g. "Wi-Fi", "USB 10/100/1000 LAN", "iPhone USB", "Bluetooth PAN".
    ///   - isMetered: `NWPath.isExpensive` — macOS sets this for phone hotspots
    ///     (iPhone Wi-Fi/USB hotspot, Android hotspots that advertise "metered").
    ///   - localIP / gateway: used to recognise the iPhone hotspot subnet.
    static func classifyConnection(interface: String?, hardware: HardwareType,
                                   displayName: String?, isMetered: Bool,
                                   localIP: String?, gateway: String?) -> ConnectionKind {
        guard interface != nil else { return .none }
        let name = (displayName ?? "").lowercased()
        let iPhoneSubnet = isIPhoneHotspotAddress(localIP) || isIPhoneHotspotAddress(gateway)
        let phoneByName = ["iphone", "ipad", "android", "rndis", "pixel", "galaxy"].contains { name.contains($0) }

        switch hardware {
        case .wifi:
            return (isMetered || iPhoneSubnet) ? .hotspotWiFi : .wifi
        case .bluetooth:
            return .hotspotBluetooth
        case .wwan:
            return .hotspotUSB
        case .ethernet:
            if name.contains("bluetooth") { return .hotspotBluetooth }
            if phoneByName || iPhoneSubnet || isMetered { return .hotspotUSB }
            return .ethernet
        case .other:
            if name.contains("bluetooth") { return .hotspotBluetooth }
            if phoneByName { return .hotspotUSB }
            return .other
        }
    }

    /// Parses the `media:` line of `ifconfig <iface>` for wired links,
    /// e.g. "media: autoselect (1000baseT <full-duplex,flow-control>)".
    static func ethernetMedia(_ ifconfigOutput: String) -> (speedMbps: Double?, duplex: String?, active: Bool) {
        var speed: Double?
        var duplex: String?
        var active = false
        for rawLine in ifconfigOutput.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("status:") {
                active = line.contains("active") && !line.contains("inactive")
            }
            guard line.hasPrefix("media:"),
                  let open = line.lastIndex(of: "(") else { continue }
            let inside = line[line.index(after: open)...]
            let digits = inside.prefix { "0123456789.".contains($0) }
            if let value = Double(digits) {
                let rest = inside.dropFirst(digits.count)
                speed = rest.hasPrefix("G") || rest.hasPrefix("g") ? value * 1000 : value
            }
            if inside.contains("full-duplex") { duplex = "Full duplex" }
            else if inside.contains("half-duplex") { duplex = "Half duplex" }
        }
        return (speed, duplex, active)
    }
}
