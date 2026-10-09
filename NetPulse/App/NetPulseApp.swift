import SwiftUI

@main
struct NetPulseApp: App {
    @StateObject private var store = NetworkStore()
    @StateObject private var customization = Customization()

    var body: some Scene {
        WindowGroup("NetPulse", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(customization)
                .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 720)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
                .environmentObject(customization)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

/// The live item in the macOS menu bar, drawn from the Customize settings.
struct MenuBarLabel: View {
    @EnvironmentObject private var store: NetworkStore
    @EnvironmentObject private var customization: Customization

    var body: some View {
        let settings = customization.settings
        let content = MenuBarContent(
            downloadMbps: averaged(\.download, seconds: settings.menuBarAverageSeconds),
            uploadMbps: averaged(\.upload, seconds: settings.menuBarAverageSeconds),
            latencyMs: store.latencyMs,
            kind: store.connection.kind,
            offline: store.status == .offline,
            settings: settings
        )
        if let image = MenuBarRenderer.image(content) {
            Image(nsImage: image)
        } else {
            Text("↓ \(Format.rate(store.downloadMbps))  ↑ \(Format.rate(store.uploadMbps))")
                .monospacedDigit()
        }
    }

    /// Mean of the last N one-second samples (N = 1 means the live value).
    private func averaged(_ key: KeyPath<NetworkStore.RatePoint, Double>, seconds: Int) -> Double {
        let samples = store.rateHistory.suffix(max(seconds, 1))
        guard !samples.isEmpty else { return 0 }
        return samples.map { $0[keyPath: key] }.reduce(0, +) / Double(samples.count)
    }
}
