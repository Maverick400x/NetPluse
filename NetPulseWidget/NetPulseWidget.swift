import WidgetKit
import SwiftUI

struct NetPulseEntry: TimelineEntry {
    let date: Date
    let snapshot: NetSnapshot
    let settings: DisplaySettings
}

/// Reads the latest snapshot and the user's widget customisation, both
/// written by the NetPulse app into the shared App Group.
/// macOS decides how often widgets refresh; the app also requests a reload
/// about once a minute while running, and immediately after a customisation change.
struct NetPulseProvider: TimelineProvider {
    func placeholder(in context: Context) -> NetPulseEntry {
        NetPulseEntry(date: Date(), snapshot: .placeholder, settings: .standard)
    }

    func getSnapshot(in context: Context, completion: @escaping (NetPulseEntry) -> Void) {
        let snapshot = context.isPreview ? NetSnapshot.placeholder : (SharedStore.load() ?? NetSnapshot.placeholder)
        completion(NetPulseEntry(date: Date(), snapshot: snapshot, settings: SharedStore.loadSettings()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NetPulseEntry>) -> Void) {
        let entry = NetPulseEntry(date: Date(),
                                  snapshot: SharedStore.load() ?? .placeholder,
                                  settings: SharedStore.loadSettings())
        let next = Date().addingTimeInterval(5 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct NetPulseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NetPulseEntry

    var body: some View {
        WidgetContentView(snapshot: entry.snapshot, family: family, settings: entry.settings)
            .containerBackground(for: .widget) {
                Rectangle().fill(WidgetContentView.background(entry.settings))
            }
    }
}

struct NetPulseWidget: Widget {
    let kind = "NetPulseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NetPulseProvider()) { entry in
            NetPulseWidgetView(entry: entry)
        }
        .configurationDisplayName("NetPulse")
        .description("Network speed, ping and status at a glance. Customise it in the NetPulse app.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct NetPulseWidgetBundle: WidgetBundle {
    var body: some Widget {
        NetPulseWidget()
    }
}

#Preview(as: .systemMedium) {
    NetPulseWidget()
} timeline: {
    NetPulseEntry(date: .now, snapshot: .placeholder, settings: .standard)
}
