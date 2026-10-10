import XCTest

final class ParsersTests: XCTestCase {

    func testPingTime() {
        let output = """
        PING 1.1.1.1 (1.1.1.1): 56 data bytes
        64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=14.832 ms
        """
        XCTAssertEqual(Parsers.pingTime(output), 14.832)
        XCTAssertNil(Parsers.pingTime("Request timeout for icmp_seq 0"))
    }

    func testDefaultRoute() {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.1.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        let route = Parsers.defaultRoute(output)
        XCTAssertEqual(route.gateway, "192.168.1.1")
        XCTAssertEqual(route.interface, "en0")
    }

    func testNameservers() {
        let text = "# comment\nnameserver 192.168.1.1\nnameserver\t8.8.8.8\nsearch home\n"
        XCTAssertEqual(Parsers.nameservers(text), ["192.168.1.1", "8.8.8.8"])
    }

    func testARPTable() {
        let output = """
        ? (192.168.1.1) at a4:2b:b0:1:2:3 on en0 ifscope [ethernet]
        ? (192.168.1.7) at (incomplete) on en0 ifscope [ethernet]
        ? (192.168.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
        ? (192.168.1.20) at 3a:11:22:33:44:55 on en0 ifscope [ethernet]
        """
        let entries = Parsers.arpTable(output)
        XCTAssertEqual(entries.map(\.ip), ["192.168.1.1", "192.168.1.20"])
        XCTAssertEqual(entries.first?.mac, "a4:2b:b0:01:02:03")
        XCTAssertEqual(entries.first?.interface, "en0")
    }

    func testPrivateMAC() {
        XCTAssertTrue(Parsers.isPrivateMAC("3a:11:22:33:44:55"))
        XCTAssertFalse(Parsers.isPrivateMAC("a4:2b:b0:01:02:03"))
    }

    func testScanTargets() {
        let targets = Parsers.scanTargets(ip: "192.168.1.24", netmask: "255.255.255.0")
        XCTAssertEqual(targets.count, 253)              // .1 … .254 minus this Mac
        XCTAssertEqual(targets.first, "192.168.1.1")
        XCTAssertEqual(targets.last, "192.168.1.254")
        XCTAssertFalse(targets.contains("192.168.1.24"))

        // Big subnets are clamped to the surrounding /24.
        XCTAssertEqual(Parsers.scanTargets(ip: "10.0.5.9", netmask: "255.255.0.0").count, 253)
    }

    func testClassifyConnection() {
        func kind(_ hw: Parsers.HardwareType, _ name: String?, metered: Bool = false,
                  ip: String? = "192.168.1.24", gw: String? = "192.168.1.1") -> ConnectionKind {
            Parsers.classifyConnection(interface: "en0", hardware: hw, displayName: name,
                                       isMetered: metered, localIP: ip, gateway: gw)
        }
        XCTAssertEqual(kind(.wifi, "Wi-Fi"), .wifi)
        XCTAssertEqual(kind(.wifi, "Wi-Fi", metered: true), .hotspotWiFi)                       // Android/iPhone hotspot
        XCTAssertEqual(kind(.wifi, "Wi-Fi", ip: "172.20.10.3", gw: "172.20.10.1"), .hotspotWiFi) // iPhone subnet
        XCTAssertEqual(kind(.ethernet, "USB 10/100/1000 LAN"), .ethernet)
        XCTAssertEqual(kind(.ethernet, "Thunderbolt Ethernet Slot 1"), .ethernet)
        XCTAssertEqual(kind(.ethernet, "iPhone USB", metered: true), .hotspotUSB)
        XCTAssertEqual(kind(.bluetooth, "Bluetooth PAN"), .hotspotBluetooth)
        XCTAssertEqual(Parsers.classifyConnection(interface: nil, hardware: .other, displayName: nil,
                                                  isMetered: false, localIP: nil, gateway: nil), .none)
    }

    func testTunnelAndHotspotSubnet() {
        XCTAssertTrue(Parsers.isTunnel("utun4"))
        XCTAssertFalse(Parsers.isTunnel("en0"))
        XCTAssertTrue(Parsers.isIPhoneHotspotAddress("172.20.10.14"))
        XCTAssertFalse(Parsers.isIPhoneHotspotAddress("172.20.10.16"))
        XCTAssertFalse(Parsers.isIPhoneHotspotAddress("192.168.1.1"))
    }

    func testEthernetMedia() {
        let gigabit = """
        en7: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tmedia: autoselect (1000baseT <full-duplex,flow-control>)
        \tstatus: active
        """
        let media = Parsers.ethernetMedia(gigabit)
        XCTAssertEqual(media.speedMbps, 1000)
        XCTAssertEqual(media.duplex, "Full duplex")
        XCTAssertTrue(media.active)

        XCTAssertEqual(Parsers.ethernetMedia("\tmedia: autoselect (2500Base-T <full-duplex>)").speedMbps, 2500)
        XCTAssertEqual(Parsers.ethernetMedia("\tmedia: autoselect (10Gbase-T <full-duplex>)").speedMbps, 10_000)
        XCTAssertEqual(Parsers.ethernetMedia("\tmedia: autoselect (100baseTX <half-duplex>)").duplex, "Half duplex")
        XCTAssertNil(Parsers.ethernetMedia("\tmedia: autoselect\n\tstatus: inactive").speedMbps)
    }

    func testFormat() {
        XCTAssertEqual(Format.rate(0.5), "500 Kbps")
        XCTAssertEqual(Format.rate(5.3), "5.3 Mbps")
        XCTAssertEqual(Format.rate(250), "250 Mbps")
        XCTAssertEqual(Format.signalQuality(-50), "Excellent")
        XCTAssertEqual(Format.signalQuality(-80), "Weak")
        XCTAssertEqual(Format.bytes(2_300_000), "2.3 MB")
    }

    func testCustomUnits() {
        XCTAssertEqual(Format.rate(0.03, unit: .bits), "30 Kbps")
        XCTAssertEqual(Format.rate(0.03, unit: .bytes), "3.8 KB/s")       // 30,000 bit/s ÷ 8
        XCTAssertEqual(Format.rate(250, unit: .bytes), "31 MB/s")
        XCTAssertEqual(Format.rate(1.2, unit: .bits, compact: true), "1.2M")
        XCTAssertEqual(Format.rate(1500, unit: .bits), "1.5 Gbps")
        XCTAssertEqual(Format.rate(0, unit: .bits), "0 Kbps")
    }

    func testNetworkQualityJSON() {
        let output = """
        {
          "base_rtt" : 18.5,
          "dl_flows" : 12,
          "dl_throughput" : 236551104,
          "interface_name" : "en0",
          "responsiveness" : 1200,
          "ul_flows" : 12,
          "ul_throughput" : 38114560
        }
        """
        let report = Parsers.networkQuality(output)
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.downloadMbps ?? 0, 236.551104, accuracy: 0.0001)   // bits/s → Mbps
        XCTAssertEqual(report?.uploadMbps ?? 0, 38.11456, accuracy: 0.0001)
        XCTAssertEqual(report?.idleLatencyMs, 18.5)
        XCTAssertEqual(report?.loadedLatencyMs ?? 0, 50, accuracy: 0.001)         // 60,000 / 1200 RPM
        XCTAssertEqual(report?.interfaceName, "en0")
        XCTAssertNil(Parsers.networkQuality("Error: no connection"))
    }

    func testCloudflareTrace() {
        let trace = "fl=123\nip=49.36.1.2\ncolo=BOM\nloc=IN\ntls=TLSv1.3\n"
        let fields = Parsers.keyValueLines(trace)
        XCTAssertEqual(fields["colo"], "BOM")
        XCTAssertEqual(fields["loc"], "IN")
    }

    func testSteadyStateThroughput() {
        // Slow start in the first 2 s, then a steady 100 Mbps (12.5 MB/s).
        var samples: [(time: Double, bytes: UInt64)] = [(0, 0), (1, 1_000_000), (2, 5_000_000)]
        for second in 3...10 {
            samples.append((Double(second), 5_000_000 + UInt64(second - 2) * 12_500_000))
        }
        XCTAssertEqual(Parsers.steadyStateMbps(samples, warmup: 2), 100, accuracy: 0.001)
        XCTAssertEqual(Parsers.steadyStateMbps([(0, 0)], warmup: 2), 0)
    }

    func testMedianAndJitter() {
        XCTAssertEqual(Parsers.median([30, 10, 20]), 20)
        XCTAssertEqual(Parsers.median([10, 20, 30, 40]), 25)
        XCTAssertNil(Parsers.median([]))
        XCTAssertEqual(Parsers.jitter([10, 14, 12]), 3)
    }

    func testSettingsDecodeFallsBackToDefaults() throws {
        let json = #"{"menuBarStyle":"stacked","widgetAccent":"teal"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(DisplaySettings.self, from: json)
        XCTAssertEqual(settings.menuBarStyle, .stacked)
        XCTAssertEqual(settings.widgetAccent, .teal)
        XCTAssertEqual(settings.menuBarUnit, .bits)                       // missing → default
    }
}

final class AnalyticsTests: XCTestCase {

    func testLatencyStats() {
        let stats = LatencyStats(results: [10, 20, nil, 30])
        XCTAssertEqual(stats.average, 20)
        XCTAssertEqual(stats.packetLoss, 0.25)
        XCTAssertEqual(stats.jitter, 10)
        XCTAssertEqual(stats.minimum, 10)
        XCTAssertEqual(stats.maximum, 30)
    }

    func testAnomalyDetectorFlagsSpike() {
        let detector = AnomalyDetector(windowSize: 60, minimumSamples: 30, threshold: 3)
        for i in 0..<40 {
            XCTAssertNil(detector.observe("latency", value: 20 + Double(i % 3), floor: 2))
        }
        XCTAssertNotNil(detector.observe("latency", value: 120, floor: 2))
        XCTAssertNil(detector.observe("latency", value: 22, floor: 2))
    }

    func testAnomalyDetectorNeedsWarmUp() {
        let detector = AnomalyDetector(minimumSamples: 30)
        XCTAssertNil(detector.observe("latency", value: 500))
    }
}
