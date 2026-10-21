import WidgetKit
import SwiftUI

// MARK: - Timeline Entry
struct MacMonitorEntry: TimelineEntry {
    let date: Date
    let stats: SystemStats
}

// MARK: - Timeline Provider
struct MacMonitorProvider: TimelineProvider {
    private func currentStats() -> SystemStats {
        SystemMonitor.shared.getStats()
    }

    func placeholder(in context: Context) -> MacMonitorEntry {
        MacMonitorEntry(date: Date(), stats: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (MacMonitorEntry) -> Void) {
        // The gallery preview needs an answer immediately.
        if context.isPreview {
            completion(MacMonitorEntry(date: Date(), stats: currentStats()))
            return
        }
        SystemMonitor.shared.freshStats { stats in
            completion(MacMonitorEntry(date: Date(), stats: stats))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacMonitorEntry>) -> Void) {
        // The extension wakes cold or with a minutes-old baseline; measure a
        // fresh half-second so CPU and network match the menu bar.
        SystemMonitor.shared.freshStats { stats in
            let currentDate = Date()
            let entry = MacMonitorEntry(date: currentDate, stats: stats)
            // Refresh every 15 seconds (fastest reliable rate for widgets)
            let nextUpdate = Calendar.current.date(byAdding: .second, value: 15, to: currentDate)!
            completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
        }
    }
}

// MARK: - Widget Entry View
struct MacMonitorWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: MacMonitorProvider.Entry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(stats: entry.stats)
        case .systemMedium:
            MediumWidgetView(stats: entry.stats)
        case .systemLarge:
            LargeWidgetView(stats: entry.stats)
        default:
            SmallWidgetView(stats: entry.stats)
        }
    }
}

// MARK: - Main Widget
@main
struct MacMonitorWidget: Widget {
    let kind: String = "MacMonitorWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MacMonitorProvider()) { entry in
            MacMonitorWidgetEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Pulse")
        .description("Real-time CPU, memory, storage, battery & network monitoring.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Previews
#Preview("Small", as: .systemSmall) {
    MacMonitorWidget()
} timeline: {
    MacMonitorEntry(date: .now, stats: .placeholder)
}

#Preview("Medium", as: .systemMedium) {
    MacMonitorWidget()
} timeline: {
    MacMonitorEntry(date: .now, stats: .placeholder)
}

#Preview("Large", as: .systemLarge) {
    MacMonitorWidget()
} timeline: {
    MacMonitorEntry(date: .now, stats: .placeholder)
}
