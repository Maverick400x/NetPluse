import Foundation
import Darwin

struct NetworkDevice: Identifiable, Hashable {
    var id: String { ip }
    let ip: String
    let mac: String
    var hostname: String?
    var isGateway = false
    var isThisMac = false
    var usesPrivateMAC: Bool { Parsers.isPrivateMAC(mac) }

    /// Sort key so 192.168.1.9 comes before 192.168.1.10.
    var sortKey: UInt32 { Parsers.ipv4ToUInt32(ip) ?? 0 }
}

/// Discovers devices on the local subnet.
///
/// How it works (no root needed):
///  1. Send a 1-byte UDP packet to every address in the subnet. To deliver
///     it, macOS must first resolve each address with ARP.
///  2. Wait a moment for ARP replies, then read the kernel's ARP cache
///     (`arp -an`). Every device that answered appears there with its MAC.
///  3. Try a reverse-DNS / mDNS lookup to get friendly hostnames.
enum DeviceScanner {

    static func scan(localIP: String, netmask: String, gateway: String?, interface: String?) async -> [NetworkDevice] {
        let targets = Parsers.scanTargets(ip: localIP, netmask: netmask)
        guard !targets.isEmpty else { return [] }

        await Task.detached(priority: .utility) { probe(targets) }.value
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        let arpOutput = await Shell.runAsync("/usr/sbin/arp", ["-an"], timeout: 5)
        let targetSet = Set(targets)
        var entries = Parsers.arpTable(arpOutput).filter { targetSet.contains($0.ip) }
        if let interface {
            entries = entries.filter { $0.interface == nil || $0.interface == interface }
        }

        var devices = entries.map { entry in
            NetworkDevice(ip: entry.ip, mac: entry.mac, isGateway: entry.ip == gateway)
        }

        // This Mac never appears in its own ARP cache, so add it explicitly.
        devices.append(NetworkDevice(ip: localIP, mac: "—", hostname: Host.current().localizedName, isThisMac: true))

        // Resolve hostnames in parallel.
        let names = await withTaskGroup(of: (String, String?).self) { group in
            for device in devices where device.hostname == nil {
                group.addTask { (device.ip, reverseLookup(device.ip)) }
            }
            var result: [String: String] = [:]
            for await (ip, name) in group { if let name { result[ip] = name } }
            return result
        }
        for index in devices.indices where devices[index].hostname == nil {
            devices[index].hostname = names[devices[index].ip]
        }

        return devices.sorted { $0.sortKey < $1.sortKey }
    }

    /// Fires one UDP datagram at each target (port 9 = "discard").
    private static func probe(_ targets: [String]) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var payload: UInt8 = 0
        for ip in targets {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(9).bigEndian
            guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { continue }
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(fd, &payload, 1, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            usleep(2_000)   // spread packets out a little so the router isn't flooded
        }
    }

    /// Reverse DNS (also answers .local mDNS names on most networks).
    private static func reverseLookup(_ ip: String) -> String? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { return nil }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard result == 0 else { return nil }
        let name = String(cString: host)
        return name == ip ? nil : name.replacingOccurrences(of: ".local.", with: ".local")
    }
}
