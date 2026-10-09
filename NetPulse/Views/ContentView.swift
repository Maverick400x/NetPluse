import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, speed, latency, connection, devices, insights, customize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .speed: return "Live Speed"
        case .latency: return "Ping & Latency"
        case .connection: return "Connection"
        case .devices: return "Devices"
        case .insights: return "Insights"
        case .customize: return "Customize"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .speed: return "arrow.up.arrow.down"
        case .latency: return "waveform.path.ecg"
        case .connection: return "wifi"
        case .devices: return "laptopcomputer.and.iphone"
        case .insights: return "sparkles"
        case .customize: return "paintbrush"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: NetworkStore
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol)
                    .badge(badge(for: item))
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ScrollView {
                Group {
                    switch selection ?? .overview {
                    case .overview: OverviewView()
                    case .speed: SpeedView()
                    case .latency: LatencyView()
                    case .connection: ConnectionView()
                    case .devices: DevicesView()
                    case .insights: InsightsView()
                    case .customize: CustomizeView()
                    }
                }
                .padding(20)
            }
            .navigationTitle((selection ?? .overview).title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    StatusBadge(status: store.status)
                }
            }
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .devices: return store.devices.count
        case .insights: return store.insights.filter { $0.severity != .info }.count
        default: return 0
        }
    }
}
