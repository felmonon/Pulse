import SwiftUI
import WidgetKit

// MARK: - Palette
/// One palette for the app, menu bar, notch and widgets. Ring gradients are
/// vivid like Activity rings; text tints use system colors so they adapt to
/// light, dark and Increase Contrast.
enum PulsePalette {
    static let cpu = Color.green
    static let memory = Color.blue
    /// A true violet that matches the storage ring; system purple reads as
    /// magenta next to the ring gradient.
    static let disk = Color(red: 0.62, green: 0.42, blue: 1.0)
    static let networkDown = Color.cyan
    static let networkUp = Color.orange
    static let warning = Color.orange
    static let critical = Color.red

    static let cpuRing = RingGradient(
        start: Color(red: 0.16, green: 0.78, blue: 0.38),
        end: Color(red: 0.62, green: 0.95, blue: 0.30)
    )
    static let memoryRing = RingGradient(
        start: Color(red: 0.04, green: 0.48, blue: 1.00),
        end: Color(red: 0.32, green: 0.84, blue: 1.00)
    )
    static let diskRing = RingGradient(
        start: Color(red: 0.53, green: 0.32, blue: 0.98),
        end: Color(red: 0.86, green: 0.50, blue: 1.00)
    )

    static func severityTint(_ severity: LoadSeverity, fallback: Color) -> Color {
        switch severity {
        case .nominal, .moderate: return fallback
        case .high: return warning
        case .critical: return critical
        }
    }

    static func batteryTint(level: Int, isCharging: Bool, hasBattery: Bool) -> Color {
        guard hasBattery else { return .secondary }
        if isCharging { return .green }
        if level <= 20 { return critical }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .yellow }
        return .primary
    }
}

struct RingGradient {
    let start: Color
    let end: Color
}

// MARK: - Metric Kind
enum MetricKind: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Storage"
        }
    }

    var shortTitle: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "MEM"
        case .disk: return "DISK"
        }
    }

    /// Menu-bar and notch phrasing, where space is tight.
    var compactTitle: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "RAM"
        case .disk: return "Disk"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: return PulsePalette.cpu
        case .memory: return PulsePalette.memory
        case .disk: return PulsePalette.disk
        }
    }

    var ring: RingGradient {
        switch self {
        case .cpu: return PulsePalette.cpuRing
        case .memory: return PulsePalette.memoryRing
        case .disk: return PulsePalette.diskRing
        }
    }

    func value(in stats: SystemStats) -> Double {
        switch self {
        case .cpu: return stats.cpuUsage
        case .memory: return stats.memoryUsage
        case .disk: return stats.diskUsage
        }
    }

    func severity(in stats: SystemStats) -> LoadSeverity {
        switch self {
        case .cpu: return stats.cpuSeverity
        case .memory: return stats.memorySeverity
        case .disk: return stats.diskSeverity
        }
    }

    /// The kinds shown for the current "show storage" preference, outermost
    /// ring first.
    static func visible(includesDisk: Bool) -> [MetricKind] {
        includesDisk ? [.cpu, .memory, .disk] : [.cpu, .memory]
    }
}

// MARK: - Activity Ring
/// A single Activity-style ring: a tinted track with a gradient arc and
/// round caps. Progress changes animate when the caller animates them.
struct ActivityRing: View {
    var progress: Double
    var gradient: RingGradient
    var lineWidth: CGFloat

    private var clamped: Double {
        SystemStatsMath.unitInterval(progress)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(gradient.start.opacity(0.2), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: max(clamped, 0.002))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [gradient.start, gradient.end]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * max(clamped, 0.002))
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
        }
        .padding(lineWidth / 2)
    }
}

/// Nested rings, outermost first, like the Activity summary.
struct ConcentricRings: View {
    let stats: SystemStats
    let kinds: [MetricKind]
    var lineWidth: CGFloat
    var gap: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                ForEach(Array(kinds.enumerated()), id: \.element.id) { index, kind in
                    let inset = CGFloat(index) * (lineWidth + gap)
                    ActivityRing(
                        progress: kind.value(in: stats),
                        gradient: kind.ring,
                        lineWidth: lineWidth
                    )
                    .frame(width: max(side - inset * 2, 0), height: max(side - inset * 2, 0))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(
            kinds.map { "\($0.title) \(PulseSharedSettings.percent($0.value(in: stats)))" }
                .joined(separator: ", ")
        ))
    }
}

// MARK: - Severity
extension LoadSeverity {
    var title: String {
        switch self {
        case .nominal: return "Normal"
        case .moderate: return "Moderate"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .nominal: return "normal"
        case .moderate: return "moderate load"
        case .high: return "high load"
        case .critical: return "critically high"
        }
    }
}

// MARK: - System Pressure Summary
struct PressureSummary {
    let kind: MetricKind
    let progress: Double
    let severity: LoadSeverity

    var label: String { kind.compactTitle }
    var color: Color { kind.tint }

    var percentText: String {
        PulseSharedSettings.percent(progress)
    }

    static func highest(for stats: SystemStats, includesDisk: Bool = true) -> PressureSummary {
        let candidates = MetricKind.visible(includesDisk: includesDisk).map {
            PressureSummary(kind: $0, progress: $0.value(in: stats), severity: $0.severity(in: stats))
        }

        return candidates.max { lhs, rhs in
            if lhs.severity == rhs.severity {
                return lhs.progress < rhs.progress
            }
            return lhs.severity < rhs.severity
        } ?? candidates[0]
    }
}

/// A one-line, human status for the whole Mac — the headline Apple would
/// write instead of a number.
struct PulseStatus {
    let headline: String
    let symbol: String
    let tint: Color
    let severity: LoadSeverity
    let isHot: Bool

    init(stats: SystemStats, includesDisk: Bool = true) {
        let pressure = PressureSummary.highest(for: stats, includesDisk: includesDisk)
        severity = pressure.severity
        isHot = stats.thermalLevel >= .serious

        switch pressure.severity {
        case .nominal, .moderate:
            if isHot {
                headline = "Your Mac is running hot"
                symbol = "thermometer.high"
                tint = PulsePalette.warning
            } else {
                headline = "Everything looks good"
                symbol = "checkmark.circle.fill"
                tint = .green
            }
        case .high:
            headline = pressure.kind == .memory
                ? "Memory pressure is high"
                : "\(pressure.kind.title) usage is high"
            symbol = "exclamationmark.triangle.fill"
            tint = PulsePalette.warning
        case .critical:
            headline = pressure.kind == .disk
                ? "Storage is almost full"
                : "\(pressure.kind.title) is under heavy load"
            symbol = "exclamationmark.octagon.fill"
            tint = PulsePalette.critical
        }
    }

    var shortTitle: String {
        switch severity {
        case .nominal, .moderate: return isHot ? "Running Hot" : "All Good"
        case .high: return "High Load"
        case .critical: return "Critical"
        }
    }
}

extension ThermalLevel: Comparable {
    static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var tint: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return PulsePalette.warning
        case .critical: return PulsePalette.critical
        }
    }
}

// MARK: - Status Badge
struct StatusBadge: View {
    let title: String
    let symbol: String
    let tint: Color
    var compact = false

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
        }
        .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
        .foregroundStyle(tint)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, compact ? 7 : 8)
        .padding(.vertical, compact ? 2.5 : 3.5)
        .background(tint.opacity(0.14), in: Capsule(style: .continuous))
    }
}

// MARK: - Battery Glyph
struct BatteryGlyph: View {
    let level: Int
    let isCharging: Bool
    let hasBattery: Bool
    var showsPercent = true
    var font: Font = .system(size: 11, weight: .semibold, design: .rounded)

    private var symbol: String {
        guard hasBattery else { return "powerplug.fill" }
        if isCharging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var tint: Color {
        PulsePalette.batteryTint(level: level, isCharging: isCharging, hasBattery: hasBattery)
    }

    var body: some View {
        HStack(spacing: 4) {
            if showsPercent {
                Text(hasBattery ? "\(level)%" : "AC")
                    .font(font)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Image(systemName: symbol)
                .symbolRenderingMode(isCharging ? .palette : .hierarchical)
                .foregroundStyle(tint, Color.secondary)
                .font(font)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        guard hasBattery else { return "On power adapter" }
        return "Battery \(level) percent\(isCharging ? ", charging" : "")"
    }
}

// MARK: - Battery Status Text
enum BatteryStatusText {
    /// Battery-menu phrasing: "Charging · 0:48 until full", "2:15 remaining",
    /// "Fully Charged", "Not Charging".
    static func describe(_ stats: SystemStats) -> String {
        guard stats.hasBattery else { return "Power Adapter" }

        if stats.isCharging {
            if let minutes = stats.batteryMinutesRemaining {
                return "\(PulseSharedSettings.formatBatteryTime(minutes: minutes)) until full"
            }
            return "Charging"
        }

        if stats.isPluggedIn {
            return stats.batteryLevel >= 99 ? "Fully Charged" : "Not Charging"
        }

        if let minutes = stats.batteryMinutesRemaining {
            return "\(PulseSharedSettings.formatBatteryTime(minutes: minutes)) remaining"
        }
        return "On Battery"
    }

    static func powerSource(_ stats: SystemStats) -> String {
        stats.isPluggedIn ? "Power Adapter" : "Battery"
    }
}

// MARK: - Segmented Usage Bar
/// A capsule split into proportional segments, like the storage bar in
/// System Settings.
struct UsageSegment: Identifiable {
    let id: String
    let value: Double
    let color: Color
}

struct SegmentedUsageBar: View {
    let segments: [UsageSegment]
    let total: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let safeTotal = total > 0 ? total : 1
            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    let fraction = SystemStatsMath.unitInterval(segment.value / safeTotal)
                    if fraction > 0.002 {
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(width * fraction - 1.5, 1.5))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, height: height, alignment: .leading)
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: height)
    }
}

// MARK: - Core Strip
/// One bar per logical core, like Activity Monitor's CPU History window.
struct CoreStrip: View {
    let cores: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, usage in
                GeometryReader { geometry in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(PulsePalette.cpu.opacity(0.12))
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [PulsePalette.cpuRing.end, PulsePalette.cpuRing.start],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: max(geometry.size.height * SystemStatsMath.unitInterval(usage), 2))
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(Text("Core \(index + 1), \(PulseSharedSettings.percent(usage))"))
            }
        }
        .animation(.easeOut(duration: 0.35), value: cores)
    }
}

// MARK: - Legend Dot
struct LegendItem: View {
    let title: String
    var value: String = ""
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
            if !value.isEmpty {
                Text(value)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
    }
}
