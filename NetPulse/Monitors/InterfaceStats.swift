import Foundation
import Darwin

struct InterfaceCounters: Equatable {
    var received: UInt64
    var sent: UInt64
}

/// Reads per-interface byte counters straight from the kernel.
///
/// Uses `sysctl(NET_RT_IFLIST2)`, which returns 64-bit counters
/// (`if_data64`). The older `getifaddrs` counters are 32-bit and wrap
/// around every 4 GB, which breaks long-running monitoring.
enum InterfaceStats {

    static func counters() -> [String: InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return [:]
        }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else {
            return [:]
        }

        var result: [String: InterfaceCounters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }

                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        result[name] = InterfaceCounters(
                            received: info.ifm_data.ifi_ibytes,
                            sent: info.ifm_data.ifi_obytes
                        )
                    }
                }
                offset += messageLength
            }
        }
        return result
    }

    /// Physical interfaces only (Wi-Fi and Ethernet are "en*" on macOS).
    /// Loopback, VPN tunnels (utun) and AirDrop (awdl) are excluded so
    /// traffic is not double-counted.
    static func physicalCounters() -> [String: InterfaceCounters] {
        counters().filter { $0.key.hasPrefix("en") }
    }
}
