import SwiftUI
import AppKit
import WidgetKit

/// Holds the menu bar / widget customisation and pushes every change to the
/// App Group so the widget redraws straight away.
@MainActor
final class Customization: ObservableObject {
    @Published var settings: DisplaySettings {
        didSet {
            guard settings != oldValue else { return }
            SharedStore.saveSettings(settings)
            scheduleWidgetReload()
        }
    }

    private var reloadTask: Task<Void, Never>?

    init() {
        settings = SharedStore.loadSettings()
    }

    func reset() {
        settings = .standard
    }

    /// Debounced so dragging through options doesn't spam WidgetKit.
    private func scheduleWidgetReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

/// What the menu bar item shows, drawn according to the user's settings.
struct MenuBarContent: View {
    let downloadMbps: Double
    let uploadMbps: Double
    let latencyMs: Double?
    let kind: ConnectionKind
    let offline: Bool
    let settings: DisplaySettings
    var color: Color = .black      // black = template image; macOS recolours it for light/dark

    var body: some View {
        HStack(spacing: 4) {
            if settings.menuBarShowIcon || settings.menuBarStyle == .iconOnly {
                Image(systemName: offline ? "wifi.exclamationmark" : kind.symbol)
                    .font(.system(size: 13, weight: .medium))
            }
            switch settings.menuBarStyle {
            case .iconOnly:
                EmptyView()
            case .stacked:
                VStack(alignment: .trailing, spacing: -1) {
                    fixedText(piece(arrow: "↑", mbps: uploadMbps), template: rateTemplate(arrow: "↑"))
                    fixedText(piece(arrow: "↓", mbps: downloadMbps), template: rateTemplate(arrow: "↓"))
                }
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
            default:
                fixedText(singleLine, template: singleLineTemplate)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
            }
        }
        .foregroundStyle(color)
        .padding(.vertical, 1)
        .fixedSize()
    }

    // MARK: Text building

    private func piece(arrow: String, mbps: Double) -> String {
        let rate = Format.rate(mbps, unit: settings.menuBarUnit, compact: settings.menuBarCompact)
        return settings.menuBarShowArrows ? "\(arrow) \(rate)" : rate
    }

    private var ping: String {
        guard let latencyMs else { return "— ms" }
        return String(format: "%.0f ms", latencyMs)
    }

    private var singleLine: String {
        switch settings.menuBarStyle {
        case .downloadOnly: return piece(arrow: "↓", mbps: downloadMbps)
        case .uploadOnly: return piece(arrow: "↑", mbps: uploadMbps)
        case .speedAndPing: return "\(piece(arrow: "↓", mbps: downloadMbps))  \(piece(arrow: "↑", mbps: uploadMbps))  \(ping)"
        case .ping: return ping
        default: return "\(piece(arrow: "↓", mbps: downloadMbps))  \(piece(arrow: "↑", mbps: uploadMbps))"
        }
    }

    // Widest possible text for each piece, used to reserve a fixed width.
    private func rateTemplate(arrow: String) -> String {
        let unit = Format.rate(250, unit: settings.menuBarUnit, compact: settings.menuBarCompact)
            .drop { $0.isNumber || $0 == "." }
        let body = "888" + String(unit)
        return settings.menuBarShowArrows ? "\(arrow) \(body)" : body
    }

    private var singleLineTemplate: String {
        switch settings.menuBarStyle {
        case .downloadOnly: return rateTemplate(arrow: "↓")
        case .uploadOnly: return rateTemplate(arrow: "↑")
        case .speedAndPing: return "\(rateTemplate(arrow: "↓"))  \(rateTemplate(arrow: "↑"))  888 ms"
        case .ping: return "888 ms"
        default: return "\(rateTemplate(arrow: "↓"))  \(rateTemplate(arrow: "↑"))"
        }
    }

    /// With "fixed width" on, a hidden copy of the widest text reserves space so
    /// the menu bar item (and the icons next to it) don't shift every second.
    @ViewBuilder
    private func fixedText(_ text: String, template: String) -> some View {
        if settings.menuBarFixedWidth {
            ZStack(alignment: .trailing) {
                Text(template).hidden()
                Text(text)
            }
        } else {
            Text(text)
        }
    }
}

/// Turns the SwiftUI menu bar content into a template image. The menu bar
/// only renders plain text and images reliably, so drawing our own image is
/// what makes icons and the two-line layout possible.
@MainActor
enum MenuBarRenderer {
    static func image<V: View>(_ view: V) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let cgImage = renderer.cgImage else { return nil }
        let size = NSSize(width: CGFloat(cgImage.width) / renderer.scale,
                          height: CGFloat(cgImage.height) / renderer.scale)
        let image = NSImage(cgImage: cgImage, size: size)
        image.isTemplate = true
        return image
    }
}
