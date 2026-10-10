# NetPulse — macOS Network Analyser + Desktop Widget

A native macOS app (Swift + SwiftUI) that monitors your network in real time, with a
**live menu-bar readout**, a **desktop widget**, on-device **anomaly detection**, and
**DevOps hooks** (Prometheus/Grafana, CI) plus an **ML pipeline** for the project report.

| Feature | Where | How it works |
|---|---|---|
| Live upload/download speed | Overview, Live Speed, menu bar | 64-bit interface byte counters from the kernel (`sysctl NET_RT_IFLIST2`), sampled every second |
| Connection info | Connection | CoreWLAN (SSID, RSSI, noise, channel, security), `getifaddrs`, default route, DNS, public IP |
| Ping / latency | Ping & Latency | `/sbin/ping` every 2 s → average, min/max, jitter, packet loss, chart |
| Devices on network | Devices | UDP probe sweep of the subnet → reads the ARP table → reverse-DNS names |
| Anomaly detection | Insights | Rolling z-score on latency + rules (loss, jitter, weak signal, network change, new device) |
| Internet speed test | Speed Test, menu bar, Overview, widget | Apple `networkQuality` or Cloudflare engine → download, upload, idle & loaded latency, data used, history |
| Connection type | Connection, Overview, menu bar, widget | Wi-Fi, phone hotspot (Wi-Fi / USB / Bluetooth), Ethernet, + VPN |
| Desktop widget | macOS desktop / Notification Center | WidgetKit, small / medium / large, reads data shared via an App Group |
| Customisation | Customize | Menu bar style, units, smoothing, icon; widget colours, background, stats — with live previews |
| Metrics export | Insights | CSV every 5 s (ML dataset) + Prometheus endpoint `:9464/metrics` |

### Connection type detection

| Shown as | How it's detected |
|---|---|
| **Wi-Fi** | Default-route interface is a Wi-Fi interface (CoreWLAN + SystemConfiguration) |
| **Hotspot (Wi-Fi)** | Wi-Fi, and macOS marks the path *expensive* (phone hotspots), or the address is in the iPhone hotspot range 172.20.10.0/28 |
| **Hotspot (USB)** | Wired interface named "iPhone USB"/Android tethering, or a metered wired link |
| **Hotspot (Bluetooth)** | Bluetooth PAN interface |
| **Ethernet** | Wired interface (built-in, USB or Thunderbolt adapter), not metered |
| **+ VPN** | Default route goes through a tunnel (`utun…`); NetPulse looks through it to the physical link |

It re-checks instantly when you switch networks (Network.framework path monitor) and every 10 s.

### How each number is measured (accuracy notes)

| Metric | Source | Notes |
|---|---|---|
| Download / Upload | Kernel 64-bit byte counters of the **active interface only** | bits ÷ true elapsed time (monotonic clock), every 1 s. 1 Mbps = 1,000,000 bit/s. Counts all traffic on that link (it is usage, not a speed test) |
| This session | Same counters | Decimal units (1 MB = 1,000,000 bytes) |
| Ping | `/sbin/ping`, one probe every 2 s | Exact RTT reported by ping. No reply within 1.5 s = lost |
| Packet loss | Last 60 probes (2 min) | lost ÷ sent |
| Jitter | Last 60 probes | Mean difference between consecutive replies |
| Signal / Noise / SNR | CoreWLAN | Wi-Fi only; dBm as reported by the Wi-Fi chip |
| Link rate | CoreWLAN (Wi-Fi) or `ifconfig` media (Ethernet) | Negotiated link speed — the ceiling for that hop, not internet speed |
| Devices | ARP table after a subnet probe | Devices that answered recently; includes this Mac and the router |
| Speed test | Apple `networkQuality` or Cloudflare streams | Capacity of the connection (see §3b). Live Speed = what you use; Speed Test = the maximum |

Switching networks resets ping history, peaks, anomaly baselines and the device list, so
every number describes the network you're on now. App Nap is disabled while NetPulse runs
so the 1-second sampling stays precise when the window is hidden.

---

## 1. Requirements

- macOS 14 Sonoma or later (desktop widgets need 14+)
- Xcode 16 or later (free from the App Store)
- [Homebrew](https://brew.sh) and XcodeGen: `brew install xcodegen`
- An Apple ID added in **Xcode → Settings → Accounts** (a free personal team is fine)

## 2. Build & run

Run these in Terminal **one line at a time** (zsh does not treat `#` as a comment
when pasted, so keep comments out of pasted commands):

```bash
cd ~/Desktop/NetPulse
xcodegen generate
open NetPulse.xcodeproj
```

`xcodegen generate` creates `NetPulse.xcodeproj` from `project.yml`. Re-run it after
adding or removing source files.

In Xcode:

1. Select the **NetPulse** project → **Signing & Capabilities**.
2. For **both** targets (`NetPulse` and `NetPulseWidget`) choose your **Team**.
   (Better: put your Team ID in `DEVELOPMENT_TEAM` in `project.yml` — see §8 — so
   regenerating the project never clears it.)
3. Press **⌘R**. Run the unit tests with **⌘U**.

On first launch macOS asks for:
- **Location** — only so macOS reveals the Wi-Fi name (SSID). Location itself is never read.
- **Local Network** — needed for the device scan.

You'll see the main window plus a live **↓ 30 Kbps  ↑ 69 Kbps** item in the menu bar.

## 3. Add the desktop widget

1. Run the app at least once from Xcode (this registers the widget).
2. Right-click the desktop → **Edit Widgets…**
3. Search **NetPulse**, pick small / medium / large, and drag it onto the desktop.

> macOS limits how often widgets refresh (every few minutes). That's why the
> **menu bar** item is the live view and the widget is the at-a-glance summary.
> If the widget says *"App not running"*, NetPulse hasn't updated it in 10 minutes.

## 3a. Customise the menu bar and widget

Open NetPulse → **Customize** (sidebar). Both sections show live previews.

**Menu bar**
- *Show*: download + upload, stacked two-line, download only, upload only, speed + ping, ping only, or icon only
- *Units*: bits (Mbps) or bytes (MB/s) · *Smoothing*: live, 3 s or 5 s average
- Connection icon (Wi-Fi / hotspot / Ethernet), arrows, compact units ("1.2M"), fixed width

**Widget**
- Colour theme, background (System / Tinted / Dark), units, speed chart on/off, upload on/off
- Which stats appear and in what order (small shows 1, medium 3, large 6)

Settings are saved to the shared App Group, so the widget updates within a second or two.

## 3b. Internet speed test

Open NetPulse → **Speed Test** (or press ▶ in the menu bar popover, or **⌘T** on the page).

| Engine | How it measures | Good for |
|---|---|---|
| **Apple (networkQuality)** — default | Runs macOS's built-in `/usr/bin/networkQuality` against Apple's CDN with many parallel flows. Sequential mode tests download and upload separately (~40 s); parallel mode is faster (~20 s) | The most accurate result on a Mac |
| **Cloudflare** | NetPulse's own test against speed.cloudflare.com: 15 latency probes, then 6 download and 4 upload streams for 10 s each on separate connections. Throughput = bytes after a 2 s warm-up ÷ time | A second opinion from a different network; also works where Apple's CDN is slow |

Results shown:

- **Download / Upload** — capacity in Mbps (1 Mbps = 1,000,000 bit/s)
- **Idle latency** — round trip on a quiet connection (+ jitter for Cloudflare)
- **Loaded latency** — round trip while the link is full. The gap from idle is
  *bufferbloat* (Low < 30 ms, Moderate < 100 ms, High above). Apple reports it as
  "responsiveness" in RPM; NetPulse converts it: 60,000 ÷ RPM = ms
- **Data used** — real bytes moved on the interface during the test (kernel counters)
- **Server / ISP** — Apple CDN host, or the Cloudflare data centre (e.g. BOM = Mumbai)

Every result is saved with the network name, connection type (Wi-Fi / hotspot /
Ethernet) and VPN state, so **History** can compare them and shows averages per
connection type. Results are stored in
`~/Library/Application Support/NetPulse/speedtests.json` and exported to
`speedtests.csv` in the same folder (**Show CSV in Finder**).

**Automatic tests** can run every 1–24 hours while NetPulse is open (skipping metered
hotspots by default) — useful for building a dataset for the report. The latest result
also appears on the Overview card, in the menu bar popover, as a widget stat
("Speed test" in Customize) and in Prometheus (`netpulse_speedtest_*`).

> A test fills the connection, so while it runs NetPulse pauses latency anomaly alerts
> and skips rows in `metrics.csv` — the test's own traffic would otherwise look like an
> incident to the ML model. On a metered connection (phone hotspot) NetPulse asks before
> testing: a test can use several hundred MB on a fast link.

## 4. Project structure

```
NetPulse/
├── project.yml                 XcodeGen spec (app, widget, tests)
├── Shared/                       code compiled into both app and widget
│   ├── NetSnapshot.swift          data model, connection types, formatting
│   ├── DisplaySettings.swift      menu bar / widget customisation (App Group)
│   └── WidgetContentView.swift    widget layout (also used for in-app previews)
├── NetPulse/
│   ├── App/
│   │   ├── NetPulseApp.swift      entry point (@main): window, menu bar, settings
│   │   ├── NetworkStore.swift     central state: timers, monitors, publishing
│   │   ├── Customization.swift    settings store + menu bar renderer
│   │   └── SpeedTestController.swift  runs tests, history, schedule, CSV
│   ├── Monitors/
│   │   ├── InterfaceStats.swift   kernel byte counters → speed
│   │   ├── Pinger.swift           latency + stats (jitter, loss)
│   │   ├── PathObserver.swift     instant network-change + metered detection
│   │   ├── ConnectionInfo.swift   connection type, Wi-Fi, Ethernet, IP, DNS, public IP
│   │   ├── SpeedTest.swift        speed test engines (Apple networkQuality, Cloudflare)
│   │   ├── DeviceScanner.swift    subnet sweep + ARP table
│   │   ├── AnomalyDetector.swift  rolling z-score model
│   │   └── MetricsExport.swift    CSV logger + Prometheus HTTP endpoint
│   ├── Support/                parsers (unit-tested) + shell helper
│   ├── Views/                  SwiftUI screens (incl. Customize) + menu-bar popover
│   └── Assets.xcassets         app icon
├── NetPulseWidget/             WidgetKit extension (@main for the widget)
├── NetPulseTests/              XCTest unit tests
├── devops/                     Prometheus + Grafana (docker compose)
├── ml/                         Isolation Forest anomaly model (Python)
└── .github/workflows/build.yml CI: tests, unsigned build, ML smoke test
```

**Data flow**

```
 kernel counters ─┐
 ping ────────────┤                 ┌─► SwiftUI window + menu bar (live, 1 s)
 CoreWLAN / IP ───┼─► NetworkStore ─┼─► App Group ─► Desktop widget (~1 min)
 ARP scan ────────┤   + Anomaly     ├─► metrics.csv ─► ml/anomaly_model.py
                  ┘     Detector    └─► :9464/metrics ─► Prometheus ─► Grafana
```

## 5. DevOps part

**CI/CD** — `.github/workflows/build.yml` runs on every push: generates the project,
runs the unit tests, builds an unsigned Release app and uploads it as an artifact,
and smoke-tests the ML model. Push the repo to GitHub to see it run.

**Monitoring stack** — with NetPulse running (endpoint on by default):

```bash
curl localhost:9464/metrics                     # check the endpoint
docker compose -f devops/docker-compose.yml up -d
```

Open Grafana at http://localhost:3000 (admin / admin) → dashboard **NetPulse**
(provisioned automatically: speed, latency, jitter, loss, RSSI, devices, anomalies).
Prometheus is at http://localhost:9090.

> The endpoint listens on all interfaces so Docker can reach it. Turn it off in
> **Insights** or **Settings (⌘,)** when you don't need it.

## 6. AI/ML part

The app writes a row every 5 seconds to
`~/Library/Application Support/NetPulse/metrics.csv`
(`download_mbps, upload_mbps, latency_ms, jitter_ms, packet_loss, rssi_dbm, device_count, anomaly, connection_type, network, vpn`).

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r ml/requirements.txt
python ml/anomaly_model.py --demo     # synthetic data with known incidents
python ml/anomaly_model.py            # your real data (after running NetPulse a while)
```

It trains an **Isolation Forest** on all features and compares it with the app's
**z-score baseline**, writing `ml-report/summary.txt` (precision / recall / F1 on the
demo data), `anomalies.csv` and `report.png`. On the synthetic demo the Isolation Forest
reaches ~0.97 precision vs ~0.64 for the z-score rule — a ready-made results table.

Ideas to extend for the report: train an LSTM/Prophet model to *forecast* latency,
export the model to Core ML (`coremltools`) and run it inside the app, or classify the
*cause* of an anomaly (Wi-Fi vs ISP vs router) from the feature pattern.

## 7. Distributing the app

| Route | Needs | Result |
|---|---|---|
| **Copy App** (demo) | Free Apple ID (Personal Team) | `.app` for your own Mac; other Macs warn "unidentified developer" → right-click → **Open** |
| **Direct Distribution** | Apple Developer Program (99 USD/year or local equivalent) | Developer ID–signed and notarized; opens on any Mac without warnings. Share as `.dmg`/`.zip` (e.g. GitHub Releases) |
| **Mac App Store** | Developer Program + code changes | App Store requires the App Sandbox; NetPulse currently runs `ping`, `route`, `arp`, `ifconfig` and `networkQuality`, which the sandbox blocks (the Cloudflare speed test engine is sandbox-safe). These must first be replaced with native APIs |

Steps (Copy App / Direct Distribution):

1. Make sure **both** targets have a Team (see §8).
2. **⇧⌘K** (Clean), then **Product → Archive**.
3. In the Archives window choose the archive → **Distribute App** →
   **Custom → Copy App** (free) or **Direct Distribution** (paid; signs and notarizes).
4. Export, then zip it or put it in a `.dmg` to share.

For the App Store you'd also use your own bundle ID (e.g. `com.yourname.netpulse`),
create the app in App Store Connect, add screenshots, a privacy policy URL and the
App Privacy answers, then **Distribute App → App Store Connect → Upload** and submit
for review.

## 8. Keeping your Team ID

`xcodegen generate` rebuilds the project from `project.yml`, which resets the Team you
picked in Xcode. To make it permanent, find your Team ID (Xcode → Settings → Accounts,
or developer.apple.com → Account → Membership) and set it in `project.yml`:

```yaml
DEVELOPMENT_TEAM: "AB12CD34EF"
```

Then run `xcodegen generate` again.

## 9. Troubleshooting

| Problem | Fix |
|---|---|
| Wi-Fi name shows "Hidden" | System Settings → Privacy & Security → Location Services → enable NetPulse |
| Widget not in the gallery | Run the app once from Xcode, then restart the widget picker; check both targets have a Team |
| Widget shows sample data | App Group not shared — both targets must be signed with the same Team |
| No devices found | Allow Local Network access (System Settings → Privacy & Security → Local Network) |
| `Address already in use` for metrics | Another process is on port 9464 — change `MetricsServer(port:)` |
| Speeds look low | It shows traffic actually flowing, not max capacity. Run a speed test to see the peak |
| `zsh: command not found: xcodegen` | Run `brew install xcodegen` on its own line (no trailing comment) |
| `No Team Found in Archive` | Set the Team for both targets (or `DEVELOPMENT_TEAM`, §8), Clean, archive again |
| Public IP shows "Looking up…" | NetPulse tries ipify, icanhazip and ifconfig.me and retries every 30 s; check that your network allows them |
| Speed test: "networkQuality could not complete" | Check the connection, or switch the engine to Cloudflare |
| Speed test: "Couldn't reach speed.cloudflare.com" | Cloudflare may be blocked on that network (some colleges/offices) — use the Apple engine |
| Speed test result lower than expected | Wi-Fi signal, other devices and the test server all matter. Compare both engines, test near the router, or plug in Ethernet |
| Connection type looks wrong | Check Connection → the "Measuring enX" tag and adapter name; hotspots are detected via macOS's *metered* flag or the iPhone 172.20.10.x range |
