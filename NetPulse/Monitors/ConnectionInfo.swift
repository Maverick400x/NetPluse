import Foundation
import CoreWLAN
import CoreLocation
import SystemConfiguration
import Darwin

struct ConnectionDetails: Equatable {
    // How we're connected
    var kind: ConnectionKind = .none
    var interfaceName: String?          // physical interface carrying the traffic, e.g. en0
    var hardwarePort: String?           // e.g. "Wi-Fi", "USB 10/100/1000 LAN", "iPhone USB"
    var vpnInterface: String?           // e.g. utun4 when a VPN owns the default route
    var isMetered = false               // macOS "expensive" path (phone hotspots)
    var isLowDataMode = false           // macOS "constrained" path

    // Wi-Fi radio (Wi-Fi and Wi-Fi hotspot only)
    var ssid: String?
    var bssid: String?
    var rssi: Int?
    var noise: Int?
    var transmitRateMbps: Double?
    var channel: Int?
    var channelWidth: String?
    var band: String?
    var wifiStandard: String?
    var security: String?

    // Wired (Ethernet / USB tethering)
    var linkSpeedMbps: Double?
    var duplex: String?

    // Addresses
    var localIP: String?
    var netmask: String?
    var gateway: String?
    var dnsServers: [String] = []
    var publicIP: String?

    var isWiFi: Bool { kind.usesWiFiRadio }
    var vpnActive: Bool { vpnInterface != nil }

    /// Signal-to-noise ratio in dB (higher is better; >25 dB is good).
    var snr: Int? {
        guard let rssi, let noise else { return nil }
        return rssi - noise
    }

    /// Identifies "the same network" across refreshes. The SSID is compared
    /// separately because it appears only after Location access is granted.
    var networkKey: String {
        [kind.rawValue, gateway ?? "", interfaceName ?? "", vpnInterface ?? ""].joined(separator: "|")
    }
}

enum ConnectionInfo {

    /// Collects everything except the public IP. Blocking — call off the main thread.
    static func fetch(path: PathObserver.State) -> ConnectionDetails {
        var details = ConnectionDetails()
        details.isMetered = path.isExpensive
        details.isLowDataMode = path.isConstrained

        // 1. Which interface owns the default route?
        let route = Parsers.defaultRoute(Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 3))
        var interface = route.interface
        details.gateway = route.gateway

        // 2. With a VPN the default route is a tunnel (utun…). Look through it
        //    to the physical interface that actually carries the packets.
        if let name = interface, Parsers.isTunnel(name) {
            details.vpnInterface = name
            interface = path.physicalInterface ?? firstPhysicalInterfaceWithIPv4()
            if let physical = interface {
                let scoped = Parsers.defaultRoute(Shell.run("/sbin/route", ["-n", "get", "-ifscope", physical, "default"], timeout: 3))
                details.gateway = scoped.gateway
            }
        }
        if interface == nil, path.isSatisfied {
            interface = path.physicalInterface
        }
        details.interfaceName = interface

        if let resolv = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) {
            details.dnsServers = Parsers.nameservers(resolv)
        }

        guard let name = interface else {
            details.kind = .none
            return details
        }

        if let address = ipv4Address(of: name) {
            details.localIP = address.ip
            details.netmask = address.netmask
        }

        // 3. Identify the hardware behind the interface.
        let hardware = hardwareInfo(bsdName: name)
        details.hardwarePort = hardware.displayName
        details.kind = Parsers.classifyConnection(
            interface: name,
            hardware: hardware.type,
            displayName: hardware.displayName,
            isMetered: path.isExpensive,
            localIP: details.localIP,
            gateway: details.gateway
        )

        // 4. Type-specific measurements.
        if details.kind.usesWiFiRadio, let wifi = CWWiFiClient.shared().interface(withName: name) {
            fillWiFi(&details, from: wifi)
        } else if hardware.type == .ethernet {
            let media = Parsers.ethernetMedia(Shell.run("/sbin/ifconfig", [name], timeout: 3))
            details.linkSpeedMbps = media.speedMbps
            details.duplex = media.duplex
        }
        return details
    }

    private static func fillWiFi(_ details: inout ConnectionDetails, from wifi: CWInterface) {
        details.ssid = wifi.ssid()          // nil until Location access is granted
        details.bssid = wifi.bssid()
        // CoreWLAN reports 0 when a value is unavailable; 0 is never a real reading.
        let rssi = wifi.rssiValue()
        details.rssi = rssi < 0 ? rssi : nil
        let noise = wifi.noiseMeasurement()
        details.noise = noise < 0 ? noise : nil
        let rate = wifi.transmitRate()
        details.transmitRateMbps = rate > 0 ? rate : nil
        if let channel = wifi.wlanChannel() {
            details.channel = channel.channelNumber
            details.band = bandName(channel.channelBand)
            details.channelWidth = widthName(channel.channelWidth)
        }
        details.wifiStandard = phyModeName(wifi.activePHYMode())
        details.security = securityName(wifi.security())
    }

    /// Hardware type and user-facing name ("Wi-Fi", "iPhone USB", …) for a BSD interface.
    static func hardwareInfo(bsdName: String) -> (type: Parsers.HardwareType, displayName: String?) {
        let wifiNames = Set(CWWiFiClient.shared().interfaceNames() ?? [])
        let all = (SCNetworkInterfaceCopyAll() as NSArray) as? [SCNetworkInterface] ?? []

        for item in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(item) as String?, bsd == bsdName else { continue }
            let display = SCNetworkInterfaceGetLocalizedDisplayName(item) as String?
            let rawType = SCNetworkInterfaceGetInterfaceType(item) as String?
            let raw = rawType ?? ""
            let type: Parsers.HardwareType
            if raw == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                type = .wifi
            } else if raw == (kSCNetworkInterfaceTypeEthernet as String) {
                type = .ethernet
            } else if raw == (kSCNetworkInterfaceTypeBluetooth as String) {
                type = .bluetooth
            } else if raw == (kSCNetworkInterfaceTypeWWAN as String) {
                type = .wwan
            } else {
                type = .other
            }
            return (wifiNames.contains(bsdName) ? .wifi : type, display)
        }
        return (wifiNames.contains(bsdName) ? .wifi : .other, nil)
    }

    /// Used when a VPN hides the physical interface from the routing table.
    private static func firstPhysicalInterfaceWithIPv4() -> String? {
        let candidates = (CWWiFiClient.shared().interfaceNames() ?? []) + (0..<16).map { "en\($0)" }
        return candidates.first { name in
            guard let ip = ipv4Address(of: name)?.ip else { return false }
            return !ip.hasPrefix("169.254.")            // ignore self-assigned addresses
        }
    }

    /// Looks up the public IP address. Tries several plain-text echo services
    /// so one being down or blocked doesn't leave the field empty.
    static func fetchPublicIP() async -> String? {
        let services = ["https://api.ipify.org", "https://icanhazip.com", "https://ifconfig.me/ip"]
        for service in services {
            guard let url = URL(string: service) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // Accept only something that looks like an IPv4/IPv6 address.
            if !text.isEmpty, text.count <= 45, text.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) {
                return text
            }
        }
        return nil
    }

    /// IPv4 address and netmask for an interface, via getifaddrs.
    static func ipv4Address(of interface: String) -> (ip: String, netmask: String)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name) == interface else { continue }
            let mask = entry.ifa_netmask.flatMap(numericHost) ?? "255.255.255.0"
            if let ip = numericHost(addr) { return (ip, mask) }
        }
        return nil
    }

    private static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                 &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return result == 0 ? String(cString: host) : nil
    }

    private static func bandName(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        default: return nil
        }
    }

    private static func widthName(_ width: CWChannelWidth) -> String? {
        switch width {
        case .width20MHz: return "20 MHz"
        case .width40MHz: return "40 MHz"
        case .width80MHz: return "80 MHz"
        case .width160MHz: return "160 MHz"
        default: return nil
        }
    }

    private static func phyModeName(_ mode: CWPHYMode) -> String? {
        switch mode {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "Wi-Fi 4 (802.11n)"
        case .mode11ac: return "Wi-Fi 5 (802.11ac)"
        case .mode11ax: return "Wi-Fi 6 (802.11ax)"
        default: return nil
        }
    }

    private static func securityName(_ security: CWSecurity) -> String? {
        switch security {
        case .none: return "Open"
        case .WEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Transition: return "WPA2/WPA3 Personal"
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise: return "WPA Enterprise"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        default: return nil
        }
    }
}

/// macOS hides the Wi-Fi name (SSID) from apps without Location access.
/// This asks once at launch; nothing is ever done with the location itself.
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool {
        let status = manager.authorizationStatus
        return status != .notDetermined && status != .denied && status != .restricted
    }

    func requestIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onChange?()
    }
}
