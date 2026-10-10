import SwiftUI
import WidgetKit

/// Customisation for the menu bar item and the desktop widget, with live previews.
struct CustomizeView: View {
    @EnvironmentObject private var store: NetworkStore
    @EnvironmentObject private var customization: Customization

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            menuBarSection
            widgetSection
            HStack {
                Spacer()
                Button("Reset to defaults", role: .destructive) { customization.reset() }
            }
        }
    }

    // MARK: - Menu bar

    private var menuBarSection: some View {
        Panel("Menu bar") {
            // Live preview on a light and a dark strip, like the real menu bar.
            HStack(spacing: 12) {
                menuBarPreview(dark: false)
                menuBarPreview(dark: true)
            }

            Form {
                Picker("Show", selection: $customization.settings.menuBarStyle) {
                    ForEach(DisplaySettings.MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Units", selection: $customization.settings.menuBarUnit) {
                    ForEach(DisplaySettings.RateUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Smoothing", selection: $customization.settings.menuBarAverageSeconds) {
                    Text("Live (1 s)").tag(1)
                    Text("3 s average").tag(3)
                    Text("5 s average").tag(5)
                }
                .pickerStyle(.segmented)
                Toggle("Connection icon (Wi-Fi / hotspot / Ethernet)", isOn: $customization.settings.menuBarShowIcon)
                Toggle("Arrows ↓ ↑", isOn: $customization.settings.menuBarShowArrows)
                    .disabled(rateHidden)
                Toggle("Compact units (1.2M instead of 1.2 Mbps)", isOn: $customization.settings.menuBarCompact)
                    .disabled(rateHidden)
                Toggle("Fixed width (stops nearby icons jumping)", isOn: $customization.settings.menuBarFixedWidth)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private var rateHidden: Bool {
        let style = customization.settings.menuBarStyle
        return style == .ping || style == .iconOnly
    }

    private func menuBarPreview(dark: Bool) -> some View {
        HStack(spacing: 10) {
            Spacer()
            Image(systemName: "battery.75percent")
            Image(systemName: "wifi")
            MenuBarContent(
                downloadMbps: store.downloadMbps,
                uploadMbps: store.uploadMbps,
                latencyMs: store.latencyMs,
                kind: store.connection.kind,
                offline: store.status == .offline,
                settings: customization.settings,
                color: dark ? .white : .black
            )
            Text(Date(), style: .time)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(dark ? Color.white : Color.black)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background(dark ? Color(white: 0.16) : Color(white: 0.93), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Widget

    private var widgetSection: some View {
        Panel("Desktop widget") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    widgetPreview(.systemSmall, size: CGSize(width: 170, height: 170), name: "Small")
                    widgetPreview(.systemMedium, size: CGSize(width: 364, height: 170), name: "Medium")
                    widgetPreview(.systemLarge, size: CGSize(width: 364, height: 382), name: "Large")
                }
                .padding(.vertical, 4)
            }

            HStack(alignment: .top, spacing: 18) {
                Form {
                    LabeledContent("Colour") {
                        HStack(spacing: 8) {
                            ForEach(DisplaySettings.Accent.allCases) { accent in
                                Button {
                                    customization.settings.widgetAccent = accent
                                } label: {
                                    Circle()
                                        .fill(LinearGradient(colors: [accent.download, accent.upload],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 22, height: 22)
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(
                                            customization.settings.widgetAccent == accent ? 0.9 : 0), lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                                .help(accent.label)
                            }
                        }
                    }
                    Picker("Background", selection: $customization.settings.widgetBackground) {
                        ForEach(DisplaySettings.WidgetBackground.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Units", selection: $customization.settings.widgetUnit) {
                        ForEach(DisplaySettings.RateUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Speed chart", isOn: $customization.settings.widgetShowChart)
                    Toggle("Upload speed", isOn: $customization.settings.widgetShowUpload)
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(maxWidth: 420)

                metricsPicker
                    .frame(maxWidth: 320)
            }

            Label("To add the widget: right-click the desktop → Edit Widgets… → search “NetPulse”. Changes here apply to it within a second or two.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func widgetPreview(_ family: WidgetFamily, size: CGSize, name: String) -> some View {
        VStack(spacing: 6) {
            WidgetContentView(snapshot: store.makeSnapshot(), family: family, settings: customization.settings)
                .padding(16)
                .frame(width: size.width, height: size.height)
                .background(WidgetContentView.background(customization.settings))
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.quaternary))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Choose which stats the widget shows, and their order.
    private var metricsPicker: some View {
        let chosen = customization.settings.widgetMetrics
        let others = DisplaySettings.WidgetMetric.allCases.filter { !chosen.contains($0) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Stats shown").font(.subheadline.weight(.semibold))
            Text("Small shows the 1st, medium the first 3, large the first 6.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(Array(chosen.enumerated()), id: \.element) { index, metric in
                HStack {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                    Text(metric.label)
                    Spacer()
                    Button { move(metric, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                    Button { move(metric, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == chosen.count - 1)
                    Button { remove(metric) } label: { Image(systemName: "minus.circle") }
                        .disabled(chosen.count <= 1)
                }
                .buttonStyle(.borderless)
            }

            if !others.isEmpty {
                Menu("Add stat") {
                    ForEach(others) { metric in
                        Button(metric.label) { customization.settings.widgetMetrics.append(metric) }
                    }
                }
                .fixedSize()
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private func move(_ metric: DisplaySettings.WidgetMetric, by offset: Int) {
        var list = customization.settings.widgetMetrics
        guard let index = list.firstIndex(of: metric) else { return }
        let target = index + offset
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        customization.settings.widgetMetrics = list
    }

    private func remove(_ metric: DisplaySettings.WidgetMetric) {
        customization.settings.widgetMetrics.removeAll { $0 == metric }
    }
}
