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
        let entry = MacMonitorEntry(date: Date(), stats: currentStats())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacMonitorEntry>) -> Void) {
        let currentDate = Date()
        let stats = currentStats()
        let entry = MacMonitorEntry(date: currentDate, stats: stats)

        // Refresh every 15 seconds (fastest reliable rate for widgets)
        let nextUpdate = Calendar.current.date(byAdding: .second, value: 15, to: currentDate)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))

        completion(timeline)
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
