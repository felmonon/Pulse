import SwiftUI
import WidgetKit

// MARK: - Native Widget Colors
struct AppColors {
    static let cpuGreen = Color(red: 0.20, green: 0.67, blue: 0.35)
    static let ramBlue = Color(red: 0.18, green: 0.48, blue: 0.86)
    static let diskAmber = Color(red: 0.91, green: 0.55, blue: 0.15)
    static let batteryGreen = Color(red: 0.20, green: 0.67, blue: 0.35)
    static let networkBlue = Color(red: 0.18, green: 0.48, blue: 0.86)
    static let networkGreen = Color(red: 0.20, green: 0.67, blue: 0.35)
    static let critical = Color(red: 0.86, green: 0.22, blue: 0.20)
    static let ringTrack = Color.secondary.opacity(0.14)
    static let divider = Color.secondary.opacity(0.13)
    static let capsuleFill = Color.primary.opacity(0.055)
    static let subtleFill = Color.secondary.opacity(0.08)
}

// MARK: - Severity-Aware Ring Color
extension AppColors {
    static func ringColor(metric: SystemMetric, severity: LoadSeverity) -> Color {
        switch severity {
        case .nominal, .moderate:
            return metric.baseColor
        case .high:
            return diskAmber
        case .critical:
            return critical
        }
    }

    static func severityColor(_ severity: LoadSeverity, fallback: Color) -> Color {
        switch severity {
        case .nominal, .moderate:
            return fallback
        case .high:
            return diskAmber
        case .critical:
            return critical
        }
    }
}

// MARK: - System Metric
enum SystemMetric: String, CaseIterable {
    case cpu
    case memory
    case disk

    var baseColor: Color {
        switch self {
        case .cpu: return AppColors.cpuGreen
        case .memory: return AppColors.ramBlue
        case .disk: return AppColors.diskAmber
        }
    }

    var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        }
    }
}

// MARK: - Dynamic Color Based on Threshold (for battery/warnings)
func thresholdColor(for progress: Double) -> Color {
    let percentage = SystemStatsMath.unitInterval(progress) * 100
    if percentage < 50 {
        return AppColors.cpuGreen
    } else if percentage < 80 {
        return AppColors.diskAmber
    } else {
        return AppColors.critical
    }
}

// MARK: - Activity Ring
struct CircularProgressView: View {
    let progress: Double
    let icon: String
    let label: String
    let size: CGFloat
    var ringColor: Color = AppColors.cpuGreen
    var severity: LoadSeverity? = nil

    private var clampedProgress: Double {
        SystemStatsMath.unitInterval(progress)
    }

    private var roundedPercentage: Int {
        Int((clampedProgress * 100).rounded())
    }

    private var effectiveSeverity: LoadSeverity {
        severity ?? LoadSeverity.from(usage: progress)
    }

    var body: some View {
        VStack(spacing: size > 56 ? 6 : 5) {
            ZStack {
                Circle()
                    .stroke(AppColors.ringTrack, lineWidth: size * 0.075)

                Circle()
                    .trim(from: 0, to: clampedProgress)
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 2) {
                    Image(systemName: icon)
                        .font(.system(size: size * 0.14, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("\(roundedPercentage)%")
                        .font(.system(size: size * 0.25, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            }
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(label) \(roundedPercentage) percent"))
            .accessibilityValue(Text(effectiveSeverity.accessibilityDescription))

            Text(label)
                .font(.system(size: size > 56 ? 11 : 10, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: size, alignment: .center)
                .lineLimit(1)
        }
        .frame(width: size)
    }
}

extension LoadSeverity {
    var title: String {
        switch self {
        case .nominal: return "OK"
        case .moderate: return "Normal"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .nominal: return "nominal"
        case .moderate: return "moderate load"
        case .high: return "high load"
        case .critical: return "critically high"
        }
    }
}

// MARK: - System Pressure Summary
struct PressureSummary {
    let label: String
    let progress: Double
    let severity: LoadSeverity
    let color: Color

    var percentText: String {
        PulseSharedSettings.percent(progress)
    }

    static func highest(for stats: SystemStats, includesDisk: Bool = true) -> PressureSummary {
        var candidates: [PressureSummary] = [
            .init(
                label: "CPU",
                progress: stats.cpuUsage,
                severity: stats.cpuSeverity,
                color: AppColors.cpuGreen
            ),
            .init(
                label: "RAM",
                progress: stats.memoryUsage,
                severity: stats.memorySeverity,
                color: AppColors.ramBlue
            )
        ]

        if includesDisk {
            candidates.append(
                .init(
                    label: "Disk",
                    progress: stats.diskUsage,
                    severity: stats.diskSeverity,
                    color: AppColors.diskAmber
                )
            )
        }

        return candidates.max { lhs, rhs in
            if lhs.severity == rhs.severity {
                return lhs.progress < rhs.progress
            }
            return lhs.severity < rhs.severity
        } ?? candidates[0]
    }
}

struct PressureSummaryView: View {
    let stats: SystemStats
    var compact = false
    var includesDisk = true

    private var pressure: PressureSummary {
        PressureSummary.highest(for: stats, includesDisk: includesDisk)
    }

    private var statusColor: Color {
        switch pressure.severity {
        case .nominal, .moderate:
            return .secondary
        case .high:
            return AppColors.diskAmber
        case .critical:
            return AppColors.critical
        }
    }

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            if pressure.severity >= .high {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: compact ? 8 : 9, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            Text("\(pressure.label) \(pressure.percentText)")
                .font(.system(size: compact ? 10 : 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if !compact {
                Text(pressure.severity.title)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.horizontal, compact ? 7 : 8)
        .padding(.vertical, compact ? 3 : 4)
        .background(
            Capsule(style: .continuous)
                .fill(AppColors.capsuleFill)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("System pressure \(pressure.label) \(pressure.percentText), \(pressure.severity.accessibilityDescription)"))
    }
}

// MARK: - Widget Header
struct WidgetHeader: View {
    let stats: SystemStats
    var showBattery = true
    var compact = false
    var showFreshness = true

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            Label {
                Text("Pulse")
                    .font(.system(size: compact ? 11 : 13, weight: .semibold, design: .rounded))
            } icon: {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
                    .foregroundStyle(AppColors.ramBlue)
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)

            Spacer(minLength: 6)

            if showFreshness {
                FreshnessView(date: stats.timestamp)
            }

            if showBattery {
                BatteryView(level: stats.batteryLevel, isCharging: stats.isCharging, hasBattery: stats.hasBattery)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Battery View
struct BatteryView: View {
    let level: Int
    let isCharging: Bool
    let hasBattery: Bool

    var color: Color {
        if !hasBattery { return .secondary }
        if level <= 20 { return AppColors.critical }
        if level < 50 { return AppColors.diskAmber }
        return AppColors.batteryGreen
    }

    var icon: String {
        if !hasBattery { return "powerplug" }
        if isCharging { return "battery.100.bolt" }
        switch level {
        case 0..<10: return "battery.0"
        case 10..<25: return "battery.25"
        case 25..<50: return "battery.50"
        case 50..<75: return "battery.75"
        default: return "battery.100"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)

            Text(hasBattery ? "\(level)%" : "AC")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        guard hasBattery else { return "On AC power" }
        let state = isCharging ? "charging" : "on battery"
        return "Battery \(level) percent, \(state)"
    }
}

// MARK: - Network View
struct NetworkView: View {
    let up: Double
    let down: Double
    var compact = false
    @AppStorage(PulseSharedSettings.Keys.unitsMode, store: PulseSharedSettings.defaults) private var unitsModeRaw = PulseSharedSettings.UnitsMode.automatic.rawValue

    private var unitsMode: PulseSharedSettings.UnitsMode {
        PulseSharedSettings.UnitsMode(rawValue: unitsModeRaw) ?? .automatic
    }

    /// Below ~1 KB/s the link is effectively quiet; showing "0 KB/s" on both
    /// legs reads as broken, so we collapse to a calm Idle state.
    private var isIdle: Bool {
        up < 1 && down < 1
    }

    var body: some View {
        if isIdle {
            HStack(spacing: 5) {
                Image(systemName: "wifi")
                    .font(.system(size: compact ? 8 : 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Idle")
                    .font(.system(size: compact ? 9 : 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Network idle"))
        } else {
            HStack(spacing: compact ? 6 : 8) {
                // Upload
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: compact ? 7 : 8, weight: .semibold))
                        .foregroundStyle(AppColors.networkBlue)
                    Text(PulseSharedSettings.formatSpeed(up, unitsMode: unitsMode))
                        .font(.system(size: compact ? 9 : 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }

                // Download
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: compact ? 7 : 8, weight: .semibold))
                        .foregroundStyle(AppColors.networkGreen)
                    Text(PulseSharedSettings.formatSpeed(down, unitsMode: unitsMode))
                        .font(.system(size: compact ? 9 : 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Network. Upload \(PulseSharedSettings.formatSpeed(up, unitsMode: unitsMode)). Download \(PulseSharedSettings.formatSpeed(down, unitsMode: unitsMode))"))
        }
    }
}

// MARK: - Freshness View
struct FreshnessView: View {
    let date: Date

    private var age: TimeInterval {
        max(Date().timeIntervalSince(date), 0)
    }

    private var isStale: Bool {
        age > 120
    }

    private var label: String {
        if age < 60 {
            return "Now"
        } else if age < 3600 {
            return "\(Int(age / 60))m"
        } else {
            return "\(Int(age / 3600))h"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isStale ? "clock.badge.exclamationmark" : "clock")
                .font(.system(size: 10, weight: .medium))

            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(isStale ? AppColors.diskAmber : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(isStale ? "Stats are stale, last updated \(label) ago" : "Updated \(label)"))
    }
}

// MARK: - Widget Divider
/// Hairline divider used between widget sections. Subtle so it reads as
/// structure, not as a heavy rule.
struct WidgetDivider: View {
    var axis: Axis.Set = .horizontal

    var body: some View {
        Rectangle()
            .fill(AppColors.divider)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .vertical ? nil : 1
            )
    }
}

// MARK: - Linear Metric Row
/// Compact metric row using the same quiet structure as system widgets.
struct LinearMetricRow: View {
    enum Style {
        case compact   // medium widget: 10pt labels, 4pt dot, tight
        case standard  // large widget: 11pt labels, 6pt dot, more air
    }

    let label: String
    let value: String
    let color: Color
    var progress: Double? = nil
    var severity: LoadSeverity? = nil
    var style: Style = .standard

    private var clampedProgress: Double {
        guard let progress else { return 0 }
        return min(max(progress, 0), 1)
    }

    private var showsBar: Bool { progress != nil }

    private var dotSize: CGFloat { style == .compact ? 4 : 6 }
    private var barHeight: CGFloat { style == .compact ? 2 : 3 }
    private var fontSize: CGFloat { style == .compact ? 10 : 11 }
    private var rowSpacing: CGFloat { style == .compact ? 5 : 6 }
    private var effectiveSeverity: LoadSeverity {
        severity ?? progress.map(LoadSeverity.from(usage:)) ?? .nominal
    }
    private var effectiveColor: Color {
        AppColors.severityColor(effectiveSeverity, fallback: color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack(spacing: 6) {
                if showsBar {
                    Circle()
                        .fill(effectiveColor)
                        .frame(width: dotSize, height: dotSize)
                }

                Text(label)
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(value)
                    .font(.system(size: fontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .fixedSize()
            }

            if showsBar {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.16))
                        Capsule()
                            .fill(effectiveColor)
                            .frame(width: max(geo.size.width * clampedProgress, barHeight))
                    }
                }
                .frame(height: barHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label), \(value), \(effectiveSeverity.accessibilityDescription)"))
    }
}

// MARK: - Small Widget
struct SmallWidgetView: View {
    let stats: SystemStats
    @AppStorage(PulseSharedSettings.Keys.showBattery, store: PulseSharedSettings.defaults) private var showBattery = true
    @AppStorage(PulseSharedSettings.Keys.showDisk, store: PulseSharedSettings.defaults) private var showDisk = true
    @AppStorage(PulseSharedSettings.Keys.showNetwork, store: PulseSharedSettings.defaults) private var showNetwork = true

    private var pressure: PressureSummary {
        PressureSummary.highest(for: stats, includesDisk: showDisk)
    }

    var body: some View {
        VStack(spacing: 9) {
            WidgetHeader(
                stats: stats,
                showBattery: showBattery,
                compact: true,
                showFreshness: false
            )

            Spacer()

            HStack(spacing: 14) {
                CircularProgressView(
                    progress: stats.cpuUsage,
                    icon: SystemMetric.cpu.icon,
                    label: "CPU",
                    size: 52,
                    ringColor: AppColors.ringColor(metric: .cpu, severity: stats.cpuSeverity),
                    severity: stats.cpuSeverity
                )

                CircularProgressView(
                    progress: stats.memoryUsage,
                    icon: SystemMetric.memory.icon,
                    label: "RAM",
                    size: 52,
                    ringColor: AppColors.ringColor(metric: .memory, severity: stats.memorySeverity),
                    severity: stats.memorySeverity
                )
            }

            Spacer()

            footer
        }
        .padding(14)
    }

    @ViewBuilder
    private var footer: some View {
        if pressure.severity >= .high || !showNetwork {
            HStack {
                PressureSummaryView(stats: stats, compact: false, includesDisk: showDisk)
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)

                NetworkView(up: stats.networkUp, down: stats.networkDown, compact: true)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Medium Widget
struct MediumWidgetView: View {
    let stats: SystemStats
    @AppStorage(PulseSharedSettings.Keys.showBattery, store: PulseSharedSettings.defaults) private var showBattery = true
    @AppStorage(PulseSharedSettings.Keys.showDisk, store: PulseSharedSettings.defaults) private var showDisk = true
    @AppStorage(PulseSharedSettings.Keys.showNetwork, store: PulseSharedSettings.defaults) private var showNetwork = true

    var body: some View {
        VStack(spacing: 10) {
            WidgetHeader(stats: stats, showBattery: showBattery, compact: true)

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                CircularProgressView(
                    progress: stats.cpuUsage,
                    icon: SystemMetric.cpu.icon,
                    label: "CPU",
                    size: 48,
                    ringColor: AppColors.ringColor(metric: .cpu, severity: stats.cpuSeverity),
                    severity: stats.cpuSeverity
                )

                Spacer(minLength: 18)

                CircularProgressView(
                    progress: stats.memoryUsage,
                    icon: SystemMetric.memory.icon,
                    label: "RAM",
                    size: 48,
                    ringColor: AppColors.ringColor(metric: .memory, severity: stats.memorySeverity),
                    severity: stats.memorySeverity
                )

                if showDisk {
                    Spacer(minLength: 18)

                    CircularProgressView(
                        progress: stats.diskUsage,
                        icon: SystemMetric.disk.icon,
                        label: "Disk",
                        size: 48,
                        ringColor: AppColors.ringColor(metric: .disk, severity: stats.diskSeverity),
                        severity: stats.diskSeverity
                    )
                }

                Spacer(minLength: 0)
            }

            WidgetDivider()

            HStack(spacing: 8) {
                PressureSummaryView(stats: stats, compact: false, includesDisk: showDisk)
                Spacer(minLength: 4)
                if showNetwork {
                    NetworkView(up: stats.networkUp, down: stats.networkDown, compact: true)
                }
            }
        }
        .padding(14)
    }
}

// MARK: - Large Widget
struct LargeWidgetView: View {
    let stats: SystemStats
    @AppStorage(PulseSharedSettings.Keys.showBattery, store: PulseSharedSettings.defaults) private var showBattery = true
    @AppStorage(PulseSharedSettings.Keys.showDisk, store: PulseSharedSettings.defaults) private var showDisk = true
    @AppStorage(PulseSharedSettings.Keys.showNetwork, store: PulseSharedSettings.defaults) private var showNetwork = true
    @AppStorage(PulseSharedSettings.Keys.showActiveApps, store: PulseSharedSettings.defaults) private var showActiveApps = true

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                WidgetHeader(stats: stats, showBattery: showBattery)
                PressureSummaryView(stats: stats, includesDisk: showDisk)
            }

            HStack(spacing: 22) {
                CircularProgressView(
                    progress: stats.cpuUsage,
                    icon: SystemMetric.cpu.icon,
                    label: "CPU",
                    size: 64,
                    ringColor: AppColors.ringColor(metric: .cpu, severity: stats.cpuSeverity),
                    severity: stats.cpuSeverity
                )

                CircularProgressView(
                    progress: stats.memoryUsage,
                    icon: SystemMetric.memory.icon,
                    label: "Memory",
                    size: 64,
                    ringColor: AppColors.ringColor(metric: .memory, severity: stats.memorySeverity),
                    severity: stats.memorySeverity
                )

                if showDisk {
                    CircularProgressView(
                        progress: stats.diskUsage,
                        icon: SystemMetric.disk.icon,
                        label: "Storage",
                        size: 64,
                        ringColor: AppColors.ringColor(metric: .disk, severity: stats.diskSeverity),
                        severity: stats.diskSeverity
                    )
                }
            }

            // Divider
            WidgetDivider()

            // Stats
            VStack(spacing: 10) {
                LinearMetricRow(
                    label: "Memory",
                    value: "\(PulseSharedSettings.formatGigabytes(stats.memoryUsed)) / \(PulseSharedSettings.formatGigabytes(stats.memoryTotal))",
                    color: AppColors.ramBlue,
                    progress: stats.memoryUsage,
                    severity: stats.memorySeverity,
                    style: .standard
                )

                if showDisk {
                    LinearMetricRow(
                        label: "Storage",
                        value: "\(PulseSharedSettings.formatGigabytes(stats.diskUsed)) of \(PulseSharedSettings.formatGigabytes(stats.diskTotal))",
                        color: AppColors.diskAmber,
                        progress: stats.diskUsage,
                        severity: stats.diskSeverity,
                        style: .standard
                    )

                    if stats.diskPurgeable > 0.1 {
                        LinearMetricRow(
                            label: "Purgeable",
                            value: PulseSharedSettings.formatGigabytes(stats.diskPurgeable),
                            color: .white.opacity(0.45),
                            style: .standard
                        )
                    }
                }

                if showNetwork {
                    HStack {
                        Image(systemName: "network")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text("Network")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)

                        Spacer()

                        NetworkView(up: stats.networkUp, down: stats.networkDown)
                    }
                }
            }

            // Apps
            if showActiveApps, !stats.activeApps.isEmpty {
                WidgetDivider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Running Apps")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)

                    Label(stats.activeApps.prefix(4).joined(separator: ", "), systemImage: "macwindow.on.rectangle")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .padding(16)
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
                .frame(width: 360, height: 170)
                .previewDisplayName("Medium")

            LargeWidgetView(stats: .placeholder)
                .frame(width: 360, height: 380)
                .previewDisplayName("Large")
        }
    }
}
