import SwiftUI
import Charts
import WidgetKit
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Style Tokens
/// The "Quiet Instrument" design language (see docs/design/pulse-design-language.md).
///
/// One rule for warnings, everywhere: **severity colors the mark, never the
/// number.** Bars, rings and history lines turn orange or red when their value
/// is genuinely high; numbers stay in the primary label color, and the status
/// sentence says in words what the color shows. Battery marks follow Apple's
/// battery semantics instead (green, red when low, yellow in Low Power Mode).
enum PulseStyle {
    static let accent = Color.accentColor
    /// Mark colors (bars, rings, lines, status dots).
    static let warning = Color.orange
    static let critical = Color.red

    /// Text colors for the rare words that must carry severity (e.g. "High" in
    /// a Memory pressure row). Darker in light mode so they pass contrast.
    static let warningText = adaptive(light: (0.66, 0.29, 0.0), dark: (1.0, 0.62, 0.04))
    static let criticalText = adaptive(light: (0.84, 0.0, 0.08), dark: (1.0, 0.27, 0.23))

    /// Gauge and bar tracks.
    static let track = Color.primary.opacity(0.10)
    /// Soft tile background — no stroke, no shadow.
    static let tileFill = Color.primary.opacity(0.035)
    /// Chart gridlines and baselines.
    static let grid = Color.primary.opacity(0.12)
    static let baseline = Color.primary.opacity(0.15)

    static let cornerRadius: CGFloat = 12
    static let pagePadding: CGFloat = 28

    // Type scale. Large numerals are light, like Clock and Weather; units sit
    // beside them in secondary.
    static let heroNumber = Font.system(size: 52, weight: .light)
    static let heroUnit = Font.system(size: 22, weight: .regular)
    static let tileNumber = Font.system(size: 30, weight: .light)
    static let tileUnit = Font.system(size: 15, weight: .regular)
    static let rowValue = Font.body.monospacedDigit()

    /// The color of a value's mark: the accent while fine, warning or critical
    /// when high.
    static func markTint(for severity: LoadSeverity) -> Color {
        switch severity {
        case .nominal, .moderate: return accent
        case .high: return warning
        case .critical: return critical
        }
    }

    /// Text color for a severity word, or nil when it should stay neutral.
    static func textTint(for severity: LoadSeverity) -> Color? {
        switch severity {
        case .nominal, .moderate: return nil
        case .high: return warningText
        case .critical: return criticalText
        }
    }

    /// Kept for source compatibility: the mark color for a high value, nil
    /// when fine. Prefer `markTint(for:)`.
    static func tint(for severity: LoadSeverity) -> Color? {
        switch severity {
        case .nominal, .moderate: return nil
        case .high: return warning
        case .critical: return critical
        }
    }

    /// Low Power Mode yellow for marks, darker in light mode so a thin arc
    /// stays visible on white.
    static let lowPowerYellow = adaptive(light: (0.70, 0.53, 0.0), dark: (1.0, 0.84, 0.04))

    /// Apple's battery semantics for marks (bars, rings), in Apple's order:
    /// green while charging; yellow in Low Power Mode; red when low and
    /// discharging; green otherwise (including plugged in and not charging).
    static func batteryMarkTint(_ stats: SystemStats) -> Color {
        guard stats.hasBattery else { return .secondary }
        if stats.isCharging { return .green }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return lowPowerYellow }
        if BatteryStatusText.severity(stats) >= .high { return critical }
        return .green
    }

    /// Source-compatible form without the plugged-in state.
    static func batteryMarkTint(level: Int, isCharging: Bool, hasBattery: Bool) -> Color {
        guard hasBattery else { return .secondary }
        if isCharging { return .green }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return lowPowerYellow }
        if level <= 20 { return critical }
        return .green
    }

    /// Battery numbers stay neutral like every other number. Kept for source
    /// compatibility.
    static func batteryTint(level: Int, isCharging: Bool, hasBattery: Bool) -> Color {
        hasBattery ? .primary : .secondary
    }

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } ?? false
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        return Color(red: light.0, green: light.1, blue: light.2)
        #endif
    }
}

// MARK: - Value Formatting
/// One formatter per quantity, shared by every surface, so a value reads the
/// same in the window, menu, notch and widgets.
enum PulseFormat {
    static func percent(_ value: Double) -> (number: String, unit: String) {
        ("\(Int((SystemStatsMath.unitInterval(value) * 100).rounded()))", "%")
    }

    static func percentText(_ value: Double) -> String {
        let parts = percent(value)
        return parts.number + parts.unit
    }

    /// One decimal below 100 GB ("6.1 GB"), whole numbers above ("494 GB").
    static func gigabytes(_ value: Double) -> (number: String, unit: String) {
        let parts = PulseSharedSettings.formatGigabytes(value).split(separator: " ")
        return (String(parts.first ?? "0"), parts.count > 1 ? String(parts[1]) : "GB")
    }

    static func gigabytesText(_ value: Double) -> String {
        PulseSharedSettings.formatGigabytes(value)
    }

    /// Installed capacities read as round figures ("8 GB", "494 GB").
    static func capacityText(_ value: Double) -> String {
        let rounded = value.rounded()
        return abs(value - rounded) < 0.05 || value >= 100
            ? "\(Int(rounded)) GB"
            : PulseSharedSettings.formatGigabytes(value)
    }

    static func speed(_ value: Double, unitsMode: PulseSharedSettings.UnitsMode) -> (number: String, unit: String) {
        let parts = PulseSharedSettings.formatSpeed(value, unitsMode: unitsMode).split(separator: " ", maxSplits: 1)
        return (String(parts.first ?? "0"), parts.count > 1 ? String(parts[1]) : "")
    }

    /// The busier network direction, for single-value spots (sidebar, tiles).
    static func dominantRate(down: Double, up: Double) -> (symbol: String, value: Double, isDownload: Bool) {
        up > down ? ("arrow.up", up, false) : ("arrow.down", down, true)
    }

    static func uptime(_ uptime: TimeInterval) -> String {
        PulseSharedSettings.formatUptime(uptime)
    }

    static func batteryTime(minutes: Int) -> String {
        PulseSharedSettings.formatBatteryTime(minutes: minutes)
    }
}

// MARK: - Value Text
/// A number with a smaller secondary unit, always in the primary label color.
/// Severity belongs on the value's mark (see `PulseStyle.markTint`).
///
/// Display sizes (hero, tile) change in place without rolling digits — at a
/// one-second refresh a rolling 52pt number is illegible much of the time.
/// Compact sizes roll subtly unless Reduce Motion is on.
struct ValueText: View {
    enum Size {
        case hero, tile, row, compact

        var number: Font {
            switch self {
            case .hero: return PulseStyle.heroNumber
            case .tile: return PulseStyle.tileNumber
            case .row: return PulseStyle.rowValue
            case .compact: return Font.callout.monospacedDigit()
            }
        }

        var unit: Font {
            switch self {
            case .hero: return PulseStyle.heroUnit
            case .tile: return PulseStyle.tileUnit
            case .row: return .body
            case .compact: return .callout
            }
        }

        var rollsDigits: Bool {
            self == .row || self == .compact
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let number: String
    let unit: String
    var size: Size = .tile
    /// Drives the numeric content transition.
    var numeric: Double = 0

    init(_ parts: (number: String, unit: String), size: Size = .tile, numeric: Double = 0) {
        self.number = parts.number
        self.unit = parts.unit
        self.size = size
        self.numeric = numeric
    }

    @available(*, deprecated, message: "Numbers stay primary; pass severity to the value's mark via PulseStyle.markTint(for:)")
    init(_ parts: (number: String, unit: String), size: Size = .tile, severity: LoadSeverity, numeric: Double = 0) {
        self.init(parts, size: size, numeric: numeric)
    }

    /// "%" hugs the number ("91%"); other units follow a space, a thin one at
    /// display sizes where a full space looks loose ("6.1 GB").
    private var unitSeparator: String {
        guard unit != "%" else { return "" }
        switch size {
        case .hero, .tile: return "\u{2009}"
        case .row, .compact: return " "
        }
    }

    private var rolls: Bool {
        size.rollsDigits && !reduceMotion
    }

    var body: some View {
        (Text(number)
            .font(size.number)
            .foregroundStyle(.primary)
        + Text(unit.isEmpty ? "" : unitSeparator + unit)
            .font(size.unit)
            .foregroundStyle(.secondary))
        .contentTransition(rolls ? .numericText(value: numeric) : .identity)
        .lineLimit(1)
        .animation(rolls ? .easeOut(duration: 0.25) : nil, value: numeric)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(number) \(unit)"))
    }
}

// MARK: - Line History Chart
/// A single line with a faint area fill. The x-domain is fixed to the window
/// capacity so new samples enter on the right edge and older ones slide left,
/// like Activity Monitor. A young history (fewer than `areaThreshold`
/// samples) draws only the line, a point on the latest sample and a visible
/// baseline, so it reads as a chart that has just started rather than a glitch.
/// An optional secondary series (e.g. upload) is a quiet dashed line.
struct LineHistoryChart: View {
    static let areaThreshold = 8

    let values: [Double]
    let capacity: Int
    var secondaryValues: [Double]? = nil
    var upperBound: Double = 1
    var showsAxis = false
    var axisLabel: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    var lineWidth: CGFloat = 1.5
    /// The line's color. Keep the accent; current severity goes on
    /// `latestTint` so history is never recolored.
    var tint: Color = PulseStyle.accent
    /// VoiceOver name, e.g. "CPU history". Empty hides the chart from VoiceOver.
    var accessibilityTitle: String = ""
    /// Severity color for the current value only: drawn as a point on the
    /// latest sample. The history keeps the color it was drawn in (`tint`), so
    /// the past is never repainted by today's state.
    var latestTint: Color? = nil
    /// Small, axis-less charts (tiles) show only their baseline and midline
    /// until enough samples exist to read as a line.
    var hidesYoungHistory = false
    /// A faint gridline at half scale, for small charts without an axis.
    var showsMidline = false

    private var isYoung: Bool { values.count < Self.areaThreshold }

    private func x(_ index: Int, count: Int) -> Int {
        index + max(capacity - count, 0)
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Baseline", 0))
                .foregroundStyle(PulseStyle.baseline)
                .lineStyle(StrokeStyle(lineWidth: 0.5))

            if showsMidline {
                RuleMark(y: .value("Midline", upperBound / 2))
                    .foregroundStyle(PulseStyle.grid.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
            }

            if !(hidesYoungHistory && isYoung) {
                historyMarks
            }
        }
        .chartXScale(domain: 0...max(capacity - 1, 1))
        .chartYScale(domain: 0...max(upperBound, 0.0001))
        .chartXAxis(.hidden)
        .chartYAxis {
            if showsAxis {
                AxisMarks(position: .trailing, values: [0, upperBound / 2, upperBound]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(PulseStyle.grid)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            // Fixed width keeps the plot the same width on every page.
                            Text(axisLabel(number))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(accessibilityTitle.isEmpty)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(Text(accessibilitySummary))
    }

    @ChartContentBuilder
    private var historyMarks: some ChartContent {
        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
            if !isYoung {
                AreaMark(
                    x: .value("Time", x(index, count: values.count)),
                    y: .value("Value", min(value, upperBound))
                )
                .foregroundStyle(
                    LinearGradient(colors: [tint.opacity(0.14), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.monotone)
            }

            LineMark(
                x: .value("Time", x(index, count: values.count)),
                y: .value("Value", min(value, upperBound)),
                series: .value("Series", "Primary")
            )
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
            }

            if isYoung, let last = values.last {
            PointMark(
                x: .value("Time", x(values.count - 1, count: values.count)),
                y: .value("Value", min(last, upperBound))
            )
            .foregroundStyle(tint)
            .symbolSize(lineWidth * 9)
            }

            if let secondaryValues {
            ForEach(Array(secondaryValues.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Time", x(index, count: secondaryValues.count)),
                    y: .value("Value", min(value, upperBound)),
                    series: .value("Series", "Secondary")
                )
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: max(lineWidth * 0.8, 1), lineCap: .round, lineJoin: .round, dash: [3, 2]))
                .interpolationMethod(.monotone)
            }
            }

        if let latestTint, !isYoung, let last = values.last {
            PointMark(
                x: .value("Time", x(values.count - 1, count: values.count)),
                y: .value("Value", min(last, upperBound))
            )
            .foregroundStyle(latestTint)
            .symbolSize(lineWidth * 14)
        }
    }

    /// "Now 23%, average 19%, peak 41%", in the chart's own units.
    private var accessibilitySummary: String {
        guard let last = values.last, !values.isEmpty else { return "No data yet" }
        let average = values.reduce(0, +) / Double(values.count)
        let peak = values.max() ?? last
        return "Now \(axisLabel(last)), average \(axisLabel(average)), peak \(axisLabel(peak))"
    }
}

// MARK: - Bars
/// A thin capsule meter: a tinted fill on a neutral track. Pass
/// `PulseStyle.markTint(for:)` (or `batteryMarkTint`) as the tint.
struct UsageBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let value: Double
    var tint: Color = PulseStyle.accent
    var height: CGFloat = 4
    /// Override for dark-only surfaces (the notch island) where the standard
    /// track nearly disappears on pure black.
    var track: Color = PulseStyle.track

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(track)
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(geometry.size.width * SystemStatsMath.unitInterval(value), value > 0 ? height : 0))
                    .widgetAccentable()
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: value)
        .accessibilityHidden(true)
    }
}

/// A monochrome segmented capsule (System Settings Storage style, in a single
/// hue). Segment shades step from the tint toward the background in light
/// mode and toward white in dark mode — opaque, so they stay distinct and
/// legible on dark fills. A segment may override its color (e.g. a neutral
/// "purgeable"); the remainder is the neutral track.
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        var color: Color? = nil
    }

    /// The shade for the segment at `index` (0 = the tint itself).
    static func shade(_ index: Int, tint: Color, in environment: EnvironmentValues) -> Color {
        guard index > 0 else { return tint }
        let resolved = tint.resolve(in: environment)
        if environment.colorScheme == .dark {
            // Mix toward white (in linear space): lighter, never muddier.
            let amounts: [Float] = [0, 0.32, 0.58, 0.78]
            let t = amounts[min(index, amounts.count - 1)]
            return Color(
                .sRGBLinear,
                red: Double(resolved.linearRed + (1 - resolved.linearRed) * t),
                green: Double(resolved.linearGreen + (1 - resolved.linearGreen) * t),
                blue: Double(resolved.linearBlue + (1 - resolved.linearBlue) * t)
            )
        }
        let opacities: [Double] = [1.0, 0.55, 0.3, 0.16]
        return tint.opacity(opacities[min(index, opacities.count - 1)])
    }

    @Environment(\.self) private var environment

    let segments: [Segment]
    let total: Double
    var height: CGFloat = 6
    var tint: Color = PulseStyle.accent

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let safeTotal = total > 0 ? total : 1
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    let fraction = SystemStatsMath.unitInterval(segment.value / safeTotal)
                    if fraction > 0.002 {
                        Rectangle()
                            .fill(segment.color ?? Self.shade(index, tint: tint, in: environment))
                            .frame(width: max(width * fraction - 1, 1))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, height: height, alignment: .leading)
            .background(PulseStyle.track)
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A legend dot for `SegmentedBar`, matching the System Settings Storage
/// legend. Index -1 is the empty remainder (drawn hollow); `color` overrides
/// the shade for segments that override theirs.
struct SegmentSwatch: View {
    @Environment(\.self) private var environment

    let index: Int
    var tint: Color = PulseStyle.accent
    var color: Color? = nil

    var body: some View {
        Group {
            if index < 0 {
                Circle()
                    .strokeBorder(Color.secondary, lineWidth: 1)
            } else {
                Circle()
                    .fill(color ?? SegmentedBar.shade(index, tint: tint, in: environment))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

// MARK: - Core Strip
/// One meter per logical core, like Activity Monitor's CPU History, grouped
/// into the efficiency and performance clusters (Apple silicon numbers the
/// efficiency cores first). Fixed-width capsules, leading-aligned, in the
/// accent: per-core load is normal; severity belongs to the CPU total.
struct CoreStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let cores: [Double]
    var barWidth: CGFloat = 12
    var height: CGFloat = 44
    var barSpacing: CGFloat = 4
    var clusterSpacing: CGFloat = 16
    var showsCaptions = true
    var tint: Color = PulseStyle.accent

    private var groups: [(caption: String?, range: Range<Int>)] {
        if let clusters = MachineInfo.coreClusters, clusters.efficiency + clusters.performance == cores.count {
            return [
                ("Efficiency", 0..<clusters.efficiency),
                ("Performance", clusters.efficiency..<cores.count),
            ]
        }
        return [(nil, 0..<cores.count)]
    }

    var body: some View {
        HStack(alignment: .top, spacing: clusterSpacing) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .bottom, spacing: barSpacing) {
                        ForEach(Array(group.range), id: \.self) { index in
                            meter(cores[index])
                                .accessibilityElement()
                                .accessibilityLabel(Text("\(group.caption.map { "\($0) core" } ?? "Core") \(index - group.range.lowerBound + 1)"))
                                .accessibilityValue(Text(PulseFormat.percentText(cores[index])))
                        }
                    }
                    if showsCaptions, let caption = group.caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: cores)
    }

    private func meter(_ usage: Double) -> some View {
        ZStack(alignment: .bottom) {
            Capsule(style: .continuous)
                .fill(PulseStyle.track)
            // A rectangle clipped by the track, so a lightly loaded core
            // reads as a short bar rather than a dot.
            Rectangle()
                .fill(tint)
                .frame(height: height * SystemStatsMath.unitInterval(usage))
                .widgetAccentable()
        }
        .frame(width: barWidth, height: height)
        .clipShape(Capsule(style: .continuous))
    }
}

// MARK: - Capacity Gauge
/// The Batteries-widget ring: a thin neutral track and a single arc. The
/// center holds either the value (preferred — it labels itself) or a
/// monochrome symbol sized to the ring.
struct CapacityGauge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let value: Double
    var tint: Color = PulseStyle.accent
    var lineWidth: CGFloat = 4
    var centerText: String? = nil
    var symbol: String? = nil

    init(value: Double, tint: Color = PulseStyle.accent, lineWidth: CGFloat = 4, centerText: String? = nil, symbol: String? = nil) {
        self.value = value
        self.tint = tint
        self.lineWidth = lineWidth
        self.centerText = centerText
        self.symbol = symbol
    }

    /// Source-compatible form: a symbol in the center.
    init(value: Double, symbol: String, tint: Color = PulseStyle.accent, lineWidth: CGFloat = 4) {
        self.init(value: value, tint: tint, lineWidth: lineWidth, centerText: nil, symbol: symbol)
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle()
                    .stroke(PulseStyle.track, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: SystemStatsMath.unitInterval(value))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
                if let centerText {
                    Text(centerText)
                        .font(.system(size: max(side * 0.24, 9), weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .padding(.horizontal, lineWidth + 2)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: max(side * 0.3, 9), weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .padding(lineWidth / 2)
        .aspectRatio(1, contentMode: .fit)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: value)
        .accessibilityHidden(true)
    }
}

// MARK: - Detail Row
/// Label on the left in secondary, value on the right. Stack with `Divider()`.
struct DetailRow: View {
    let title: String
    let value: String
    var valueTint: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(valueTint ?? .primary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Status Line
/// The sentence that summarizes the Mac's state. Calm by default; a small dot
/// in the warning color appears only when something needs attention. With
/// `showsDetail`, a second line names any other conditions so no warning
/// relies on color alone.
struct StatusLine: View {
    let status: PulseStatus
    var font: Font = .title3
    var showsDetail = false
    /// The second sentence's font; defaults to the headline's so the two read
    /// as one paragraph.
    var detailFont: Font? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let tint = status.attentionTint {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                Text(status.headline)
                    .font(font)
                    .foregroundStyle(.secondary)
            }
            if showsDetail, let detail = status.detail {
                Text(detail)
                    .font(detailFont ?? font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, status.attentionTint == nil ? 0 : 15)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Metric Kind
enum MetricKind: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case disk

    var id: String { rawValue }

    /// The one name for each metric, on every surface.
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Storage"
        }
    }

    /// Same vocabulary as `title`; kept so tight spots can change later in
    /// one place.
    var compactTitle: String { title }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        }
    }

    /// Percent used, the canonical compact figure for every metric.
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

    /// The severity that colors this metric's MARK. Memory marks show
    /// occupancy, which is not a problem by itself; memory *pressure* is said
    /// in words (status sentence, "High pressure"), so its marks stay accent.
    func markSeverity(in stats: SystemStats) -> LoadSeverity {
        self == .memory ? .nominal : severity(in: stats)
    }

    /// VoiceOver wording for this metric's severity.
    func spokenSeverity(_ severity: LoadSeverity) -> String {
        switch (self, severity) {
        case (_, .nominal), (_, .moderate): return "normal"
        case (.cpu, .high): return "high load"
        case (.cpu, .critical): return "very high load"
        case (.memory, .high): return "memory pressure high"
        case (.memory, .critical): return "memory pressure critical"
        case (.disk, .high): return "getting full"
        case (.disk, .critical): return "almost full"
        }
    }

    static func visible(includesDisk: Bool) -> [MetricKind] {
        includesDisk ? [.cpu, .memory, .disk] : [.cpu, .memory]
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

extension ThermalLevel: Comparable {
    static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Only abnormal thermal states earn a (text) color.
    var attentionTint: Color? {
        switch self {
        case .nominal, .fair: return nil
        case .serious: return PulseStyle.warningText
        case .critical: return PulseStyle.criticalText
        }
    }
}

// MARK: - System Pressure Summary
struct PressureSummary {
    let kind: MetricKind
    let progress: Double
    let severity: LoadSeverity

    var label: String { kind.title }

    var percentText: String {
        PulseSharedSettings.percent(progress)
    }

    /// The metric for ambient, always-visible spots (resting notch island,
    /// menu-bar text): only the live metrics, CPU and Memory. Storage is a
    /// slow capacity, so it speaks through the status sentence and panels
    /// instead of taking over the ambient surfaces for days.
    static func ambient(for stats: SystemStats) -> PressureSummary {
        let cpu = PressureSummary(kind: .cpu, progress: stats.cpuUsage, severity: stats.cpuSeverity)
        let memory = PressureSummary(kind: .memory, progress: stats.memoryUsage, severity: stats.memorySeverity)
        return memory.severity > cpu.severity ? memory : cpu
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

/// What needs attention on the Mac, in words. Collects every high metric, a
/// low battery and heat; the worst becomes the headline and the rest a second
/// sentence, so no condition is shown by color alone.
struct PulseStatus {
    enum Condition: Equatable {
        case metric(MetricKind, LoadSeverity)
        case batteryLow(LoadSeverity)
        case hot

        var severity: LoadSeverity {
            switch self {
            case .metric(_, let severity), .batteryLow(let severity): return severity
            case .hot: return .high
            }
        }

        /// Tie-break order when severities match: transient problems lead; the
        /// long-standing disk condition yields the headline to them.
        var priority: Int {
            switch self {
            case .metric(.cpu, _): return 0
            case .metric(.memory, _): return 1
            case .hot: return 2
            case .batteryLow: return 3
            case .metric(.disk, _): return 4
            }
        }

        /// The mark color this condition uses elsewhere, so the status dot
        /// always matches it (a low battery is red, as on its own mark).
        var tint: Color {
            switch self {
            case .batteryLow: return PulseStyle.critical
            default: return severity >= .critical ? PulseStyle.critical : PulseStyle.warning
            }
        }

        var noun: String {
            switch self {
            case .metric(.cpu, _): return "CPU"
            case .metric(.memory, _): return "memory"
            case .metric(.disk, _): return "storage"
            case .batteryLow: return "battery"
            case .hot: return "temperature"
            }
        }
    }

    /// Worst condition first.
    let conditions: [Condition]
    /// Full sentence: "Your startup disk is almost full."
    let headline: String
    /// Short phrase for tight spots (notch island): "Startup disk almost full".
    let shortHeadline: String
    /// Other conditions, e.g. "CPU usage and memory pressure are also high."
    let detail: String?
    let severity: LoadSeverity
    let isHot: Bool
    /// The worst metric (CPU when nothing is high), for callers that feature one.
    let kind: MetricKind

    init(stats: SystemStats, includesDisk: Bool = true, includesBattery: Bool = true) {
        var found: [Condition] = MetricKind.visible(includesDisk: includesDisk).compactMap { kind in
            let severity = kind.severity(in: stats)
            return severity >= .high ? .metric(kind, severity) : nil
        }
        if includesBattery, stats.hasBattery, !stats.isCharging, !stats.isPluggedIn, stats.batteryLevel <= 20 {
            found.append(.batteryLow(stats.batteryLevel <= 10 ? .critical : .high))
        }
        isHot = stats.thermalLevel >= .serious
        if isHot { found.append(.hot) }

        conditions = found.sorted {
            $0.severity == $1.severity ? $0.priority < $1.priority : $0.severity > $1.severity
        }
        severity = conditions.first?.severity ?? .nominal
        kind = PressureSummary.highest(for: stats, includesDisk: includesDisk).kind

        guard let worst = conditions.first else {
            headline = "Everything is running normally."
            shortHeadline = "Running normally"
            detail = nil
            return
        }
        (headline, shortHeadline) = Self.phrases(for: worst)
        detail = Self.detail(for: Array(conditions.dropFirst()))
    }

    /// The dot color beside the headline (the worst condition's own mark
    /// color), or nil when all is well.
    var attentionTint: Color? {
        conditions.first?.tint
    }

    private static func phrases(for condition: Condition) -> (String, String) {
        switch condition {
        case .metric(.cpu, .critical): return ("CPU is under heavy load.", "CPU under heavy load")
        case .metric(.cpu, _): return ("CPU usage is high.", "CPU usage high")
        case .metric(.memory, .critical): return ("Memory pressure is critical.", "Memory pressure critical")
        case .metric(.memory, _): return ("Memory pressure is high.", "Memory pressure high")
        case .metric(.disk, .critical): return ("Your startup disk is almost full.", "Startup disk almost full")
        case .metric(.disk, _): return ("Your startup disk is getting full.", "Startup disk filling up")
        case .batteryLow(.critical): return ("Your battery is very low.", "Battery very low")
        case .batteryLow: return ("Your battery is low.", "Battery low")
        case .hot: return ("Your Mac is running hot.", "Running hot")
        }
    }

    private static func detail(for others: [Condition]) -> String? {
        // Three or more: a compact list keeps every condition named in words
        // without turning a menu into a paragraph.
        if others.count >= 3 {
            let nouns = others.map(\.noun)
            let list = nouns.dropLast().joined(separator: ", ") + " and " + nouns[nouns.count - 1]
            return list.prefix(1).uppercased() + list.dropFirst() + " also need attention."
        }
        var high: [String] = []
        var clauses: [String] = []
        for condition in others {
            switch condition {
            case .metric(.cpu, _): high.append("CPU usage")
            case .metric(.memory, _): high.append("memory pressure")
            case .metric(.disk, _): clauses.append("the startup disk is nearly full")
            case .batteryLow: clauses.append("the battery is low")
            case .hot: clauses.append("your Mac is running hot")
            }
        }
        if !high.isEmpty {
            clauses.insert("\(high.joined(separator: " and ")) \(high.count == 1 ? "is" : "are") also high", at: 0)
        }
        guard !clauses.isEmpty else { return nil }
        let sentence = clauses.count == 1
            ? clauses[0]
            : clauses.dropLast().joined(separator: ", ") + ", and " + clauses[clauses.count - 1]
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }
}

// MARK: - Battery Status Text
enum BatteryStatusText {
    /// Battery-menu phrasing: "0:48 until full", "2:15 remaining",
    /// "Fully charged", "Not charging".
    static func describe(_ stats: SystemStats) -> String {
        guard stats.hasBattery else { return "Power adapter" }

        if stats.isCharging {
            if let minutes = stats.batteryMinutesRemaining {
                return "\(PulseFormat.batteryTime(minutes: minutes)) until full"
            }
            return "Charging"
        }

        if stats.isPluggedIn {
            return stats.batteryLevel >= 99 ? "Fully charged" : "Not charging"
        }

        if let minutes = stats.batteryMinutesRemaining {
            return "\(PulseFormat.batteryTime(minutes: minutes)) remaining"
        }
        return "On battery"
    }

    /// "On battery power", "Charging", "Power adapter".
    static func powerState(_ stats: SystemStats) -> String {
        guard stats.hasBattery else { return "Power adapter" }
        if stats.isCharging { return "Charging" }
        return stats.isPluggedIn ? "Power adapter" : "On battery power"
    }

    static func powerSource(_ stats: SystemStats) -> String {
        stats.isPluggedIn ? "Power adapter" : "Battery"
    }

    static func symbol(_ stats: SystemStats) -> String {
        guard stats.hasBattery else { return "powerplug" }
        if stats.isCharging { return "battery.100percent.bolt" }
        switch stats.batteryLevel {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Battery severity for marks/status: high at ≤20%, critical at ≤10%,
    /// only while discharging.
    static func severity(_ stats: SystemStats) -> LoadSeverity {
        guard stats.hasBattery, !stats.isCharging, !stats.isPluggedIn else { return .nominal }
        if stats.batteryLevel <= 10 { return .critical }
        if stats.batteryLevel <= 20 { return .high }
        return .nominal
    }
}
