import SwiftUI
import WidgetKit

// MARK: - Shared Widget Pieces

/// "23%" over a small colored caption, the way Fitness lists ring values.
struct RingValueLine: View {
    let kind: MetricKind
    let stats: SystemStats
    var detail: String? = nil
    var valueSize: CGFloat = 18

    private var severity: LoadSeverity { kind.severity(in: stats) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kind.title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(PulsePalette.severityTint(severity, fallback: kind.tint))

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(PulseSharedSettings.percent(kind.value(in: stats)))
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: kind.value(in: stats)))
                    .foregroundStyle(.primary)

                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                if severity >= .high {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PulsePalette.severityTint(severity, fallback: kind.tint))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(kind.title) \(PulseSharedSettings.percent(kind.value(in: stats))), \(severity.accessibilityDescription)"))
    }
}

enum MetricDetail {
    static func short(_ kind: MetricKind, stats: SystemStats) -> String {
        switch kind {
        case .cpu:
            return "\(PulseSharedSettings.percent(stats.cpuUser)) user"
        case .memory:
            return "\(PulseSharedSettings.formatGigabytes(stats.memoryUsed)) of \(PulseSharedSettings.formatGigabytes(stats.memoryTotal))"
        case .disk:
            return "\(PulseSharedSettings.formatGigabytes(stats.diskAvailable)) free"
        }
    }
}

/// Download and upload rates with arrow glyphs; collapses to "Idle" when the
/// link is quiet so it never reads as broken.
struct NetworkRates: View {
    let up: Double
    let down: Double
    var fontSize: CGFloat = 10.5
    @AppStorage(PulseSharedSettings.Keys.unitsMode, store: PulseSharedSettings.defaults) private var unitsModeRaw = PulseSharedSettings.UnitsMode.automatic.rawValue

    private var unitsMode: PulseSharedSettings.UnitsMode {
        PulseSharedSettings.UnitsMode(rawValue: unitsModeRaw) ?? .automatic
    }

    var body: some View {
        if up < 1 && down < 1 {
            Label("Idle", systemImage: "wifi")
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Network idle"))
        } else {
            HStack(spacing: 8) {
                rate(symbol: "arrow.down", value: down, tint: PulsePalette.networkDown)
                rate(symbol: "arrow.up", value: up, tint: PulsePalette.networkUp)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Download \(PulseSharedSettings.formatSpeed(down, unitsMode: unitsMode)), upload \(PulseSharedSettings.formatSpeed(up, unitsMode: unitsMode))"))
        }
    }

    private func rate(symbol: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: fontSize - 1, weight: .bold))
                .foregroundStyle(tint)
            Text(PulseSharedSettings.formatSpeed(value, unitsMode: unitsMode))
                .font(.system(size: fontSize, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Small Widget
struct SmallWidgetView: View {
    let stats: SystemStats
    @AppStorage(PulseSharedSettings.Keys.showBattery, store: PulseSharedSettings.defaults) private var showBattery = true
    @AppStorage(PulseSharedSettings.Keys.showDisk, store: PulseSharedSettings.defaults) private var showDisk = true

    private var kinds: [MetricKind] { MetricKind.visible(includesDisk: showDisk) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ConcentricRings(stats: stats, kinds: kinds, lineWidth: 9.5, gap: 1.5)
                    .frame(width: 70, height: 70)

                Spacer(minLength: 4)

                if showBattery {
                    BatteryGlyph(
                        level: stats.batteryLevel,
                        isCharging: stats.isCharging,
                        hasBattery: stats.hasBattery,
                        showsPercent: false,
                        font: .system(size: 13, weight: .medium)
                    )
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(kinds) { kind in
                    let severity = kind.severity(in: stats)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(PulseSharedSettings.percent(kind.value(in: stats)))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: kind.value(in: stats)))
                            .foregroundStyle(PulsePalette.severityTint(severity, fallback: kind.tint))
                        Text(kind.shortTitle)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        if severity >= .high {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(PulsePalette.severityTint(severity, fallback: kind.tint))
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Medium Widget
struct MediumWidgetView: View {
    let stats: SystemStats
    @AppStorage(PulseSharedSettings.Keys.showBattery, store: PulseSharedSettings.defaults) private var showBattery = true
    @AppStorage(PulseSharedSettings.Keys.showDisk, store: PulseSharedSettings.defaults) private var showDisk = true
    @AppStorage(PulseSharedSettings.Keys.showNetwork, store: PulseSharedSettings.defaults) private var showNetwork = true

    private var kinds: [MetricKind] { MetricKind.visible(includesDisk: showDisk) }

    var body: some View {
        HStack(spacing: 18) {
            ConcentricRings(stats: stats, kinds: kinds, lineWidth: 13, gap: 2)
                .frame(width: 122, height: 122)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(kinds) { kind in
                    RingValueLine(kind: kind, stats: stats, detail: MetricDetail.short(kind, stats: stats))
                }

                if showNetwork || showBattery {
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        if showNetwork {
                            NetworkRates(up: stats.networkUp, down: stats.networkDown, fontSize: 10)
                        }
                        Spacer(minLength: 0)
                        if showBattery {
                            BatteryGlyph(
                                level: stats.batteryLevel,
                                isCharging: stats.isCharging,
                                hasBattery: stats.hasBattery,
                                font: .system(size: 10, weight: .semibold, design: .rounded)
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(16)
    }
}

// MARK: - Large Widget
struct LargeWidgetView: View {
    let stats: SystemStats
    @AppStorage(PulseSharedSettings.Keys.showBattery, store: PulseSharedSettings.defaults) private var showBattery = true
    @AppStorage(PulseSharedSettings.Keys.showDisk, store: PulseSharedSettings.defaults) private var showDisk = true
    @AppStorage(PulseSharedSettings.Keys.showNetwork, store: PulseSharedSettings.defaults) private var showNetwork = true
    @AppStorage(PulseSharedSettings.Keys.showActiveApps, store: PulseSharedSettings.defaults) private var showActiveApps = true

    private var kinds: [MetricKind] { MetricKind.visible(includesDisk: showDisk) }
    private var status: PulseStatus { PulseStatus(stats: stats, includesDisk: showDisk) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: status.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(status.tint)
                Text(status.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if showBattery {
                    BatteryGlyph(level: stats.batteryLevel, isCharging: stats.isCharging, hasBattery: stats.hasBattery)
                }
            }
            .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 20) {
                ConcentricRings(stats: stats, kinds: kinds, lineWidth: 13, gap: 2)
                    .frame(width: 108, height: 108)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(kinds) { kind in
                        RingValueLine(kind: kind, stats: stats, detail: MetricDetail.short(kind, stats: stats), valueSize: 19)
                    }
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 9) {
                breakdownRow(
                    title: "Memory",
                    value: "\(PulseSharedSettings.formatGigabytes(stats.memoryUsed)) used",
                    segments: [
                        UsageSegment(id: "app", value: stats.memoryApp, color: PulsePalette.memory),
                        UsageSegment(id: "wired", value: stats.memoryWired, color: .teal),
                        UsageSegment(id: "compressed", value: stats.memoryCompressed, color: .indigo)
                    ],
                    total: stats.memoryTotal
                )

                if showDisk {
                    breakdownRow(
                        title: "Storage",
                        value: "\(PulseSharedSettings.formatGigabytes(stats.diskAvailable)) available",
                        segments: [
                            UsageSegment(id: "used", value: stats.diskUsed, color: PulsePalette.disk),
                            UsageSegment(id: "purgeable", value: stats.diskPurgeable, color: PulsePalette.disk.opacity(0.35))
                        ],
                        total: stats.diskTotal
                    )
                }

                if showNetwork {
                    HStack {
                        Text("Network")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        NetworkRates(up: stats.networkUp, down: stats.networkDown, fontSize: 11)
                    }
                }

                if showBattery && stats.hasBattery {
                    HStack {
                        Text("Battery")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(stats.batteryLevel)% · \(BatteryStatusText.describe(stats))")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if !stats.cpuCoreUsage.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU Cores")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    CoreStrip(cores: stats.cpuCoreUsage)
                        .frame(height: 18)
                }
            }

            Spacer(minLength: 0)

            if showActiveApps, let frontmost = stats.activeApps.first {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                        .foregroundStyle(.secondary)
                    Text(frontmost)
                        .foregroundStyle(.primary)
                    if stats.activeApps.count > 1 {
                        Text("+ \(stats.activeApps.dropFirst().prefix(3).joined(separator: ", "))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func breakdownRow(title: String, value: String, segments: [UsageSegment], total: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))

            SegmentedUsageBar(segments: segments, total: total, height: 6)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews
struct WidgetViews_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            SmallWidgetView(stats: .placeholder)
                .frame(width: 170, height: 170)
                .previewDisplayName("Small")

            MediumWidgetView(stats: .placeholder)
                .frame(width: 364, height: 170)
                .previewDisplayName("Medium")

            LargeWidgetView(stats: .placeholder)
                .frame(width: 364, height: 382)
                .previewDisplayName("Large")
        }
    }
}
