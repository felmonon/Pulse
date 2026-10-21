import SwiftUI
import WidgetKit

// Pulse widgets, in the language of Apple's Batteries widget: thin capacity
// rings with the value inside and the name beneath, nothing else.
//
// One rule for every ring: severity colors the arc, never the number. CPU and
// Storage arcs use `PulseStyle.markTint(for:)` (the accent while fine,
// orange/red when genuinely high). The Memory arc shows occupancy, which is
// not a problem by itself, so it stays in the accent; memory *pressure* is
// said in words (the status sentence, the large widget's Memory row). The
// Battery arc follows Apple's battery colors via `PulseStyle.batteryMarkTint`.
// Numbers and titles stay in the label colors.

// MARK: - Gauge Model

/// One ring in a widget: what it measures and how to present it.
private struct WidgetGauge: Identifiable {
    let id: String
    let title: String
    let value: Double
    /// Shown inside the ring: "62%".
    let valueText: String
    let tint: Color
    /// What VoiceOver says after the title, including any warning in words.
    let accessibilityValue: String
}

private enum WidgetGauges {
    static func make(stats: SystemStats, showDisk: Bool, showBattery: Bool) -> [WidgetGauge] {
        var gauges = MetricKind.visible(includesDisk: showDisk).map { metric($0, stats: stats) }
        if showBattery && stats.hasBattery {
            gauges.append(battery(stats))
        }
        return gauges
    }

    private static func metric(_ kind: MetricKind, stats: SystemStats) -> WidgetGauge {
        let value = kind.value(in: stats)
        let severity = kind.severity(in: stats)
        let percent = PulseFormat.percentText(value)
        return WidgetGauge(
            id: kind.id,
            title: kind.title,
            value: value,
            valueText: percent,
            tint: PulseStyle.markTint(for: kind.markSeverity(in: stats)),
            // Spoken even where the arc stays accent (memory pressure).
            accessibilityValue: severity >= .high
                ? "\(percent), \(kind.spokenSeverity(severity))"
                : percent
        )
    }

    private static func battery(_ stats: SystemStats) -> WidgetGauge {
        let level = min(max(stats.batteryLevel, 0), 100)
        var spoken = ["\(level)%"]
        switch BatteryStatusText.severity(stats) {
        case .critical: spoken.append("very low")
        case .high: spoken.append("low")
        default:
            // The ring turns yellow in Low Power Mode; say so too.
            if !stats.isCharging && ProcessInfo.processInfo.isLowPowerModeEnabled {
                spoken.append("Low Power Mode")
            }
        }
        spoken.append(BatteryStatusText.describe(stats))
        return WidgetGauge(
            id: "battery",
            title: "Battery",
            value: Double(level) / 100,
            valueText: "\(level)%",
            tint: PulseStyle.batteryMarkTint(stats),
            accessibilityValue: spoken.joined(separator: ", ")
        )
    }
}

// MARK: - Gauge Cell

/// A capacity ring with its value inside and its name centered beneath.
private struct GaugeCell: View {
    let gauge: WidgetGauge
    let diameter: CGFloat
    let lineWidth: CGFloat
    let titleFont: Font
    var spacing: CGFloat = 5
    /// A fixed size for the value inside the ring. Nil keeps the gauge's own
    /// proportional size (small and medium widgets).
    var valueFont: Font? = nil

    var body: some View {
        VStack(spacing: spacing) {
            ring
                .frame(width: diameter, height: diameter)

            Text(gauge.title)
                .font(titleFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(gauge.title))
        .accessibilityValue(Text(gauge.accessibilityValue))
    }

    @ViewBuilder
    private var ring: some View {
        if let valueFont {
            CapacityGauge(value: gauge.value, tint: gauge.tint, lineWidth: lineWidth)
                .overlay {
                    Text(gauge.valueText)
                        .font(valueFont)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .padding(.horizontal, lineWidth + 2)
                }
        } else {
            CapacityGauge(value: gauge.value, tint: gauge.tint, lineWidth: lineWidth, centerText: gauge.valueText)
        }
    }
}

/// Rings in a row. `.evenly` spaces them with equal gaps at the edges too
/// (Batteries medium widget); `.justified` pins the outer rings to the edges
/// so the row lines up with a text column beneath it.
private struct GaugeRow: View {
    enum Distribution { case evenly, justified }

    let gauges: [WidgetGauge]
    let diameter: CGFloat
    let lineWidth: CGFloat
    var distribution: Distribution = .evenly
    var valueFont: Font? = nil

    /// The outer gap of an `.evenly` row of `count` rings in `width`: where
    /// the first ring starts.
    static func evenInset(width: CGFloat, count: Int, diameter: CGFloat) -> CGFloat {
        let count = CGFloat(max(count, 1))
        return max((width - count * diameter) / (count + 1), 0)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if distribution == .evenly { Spacer(minLength: 0) }
            ForEach(Array(gauges.enumerated()), id: \.element.id) { index, gauge in
                if index > 0 { Spacer(minLength: 0) }
                GaugeCell(gauge: gauge, diameter: diameter, lineWidth: lineWidth, titleFont: .caption, spacing: 6, valueFont: valueFont)
            }
            if distribution == .evenly { Spacer(minLength: 0) }
        }
    }
}

// MARK: - Small Widget
struct SmallWidgetView: View {
    let stats: SystemStats
    @AppStorage(PulseSharedSettings.Keys.showBattery, store: PulseSharedSettings.defaults) private var showBattery = true
    @AppStorage(PulseSharedSettings.Keys.showDisk, store: PulseSharedSettings.defaults) private var showDisk = true

    /// Ring diameter and gutters. The vertical gutter is set 3pt tighter
    /// than the horizontal one because the title's line box already adds
    /// space below the glyphs; optically both read as the same ~16pt gap.
    private static let ring: CGFloat = 46
    private static let horizontalGutter: CGFloat = 16
    private static let verticalGutter: CGFloat = 13

    var body: some View {
        let gauges = WidgetGauges.make(stats: stats, showDisk: showDisk, showBattery: showBattery)
        Group {
            if gauges.count >= 3 {
                // 2×2 like Batteries; with three, the third centers beneath
                // the pair so the grid has no empty quadrant.
                Grid(horizontalSpacing: Self.horizontalGutter, verticalSpacing: Self.verticalGutter) {
                    GridRow {
                        ForEach(gauges.prefix(2)) { cell($0) }
                    }
                    GridRow {
                        if gauges.count == 3 {
                            cell(gauges[2]).gridCellColumns(2)
                        } else {
                            ForEach(gauges.dropFirst(2).prefix(2)) { cell($0) }
                        }
                    }
                }
            } else {
                // Two rings: larger, side by side, centered.
                HStack(alignment: .top, spacing: 20) {
                    ForEach(gauges) { gauge in
                        GaugeCell(gauge: gauge, diameter: 58, lineWidth: 5, titleFont: .caption, spacing: 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cell(_ gauge: WidgetGauge) -> some View {
        GaugeCell(gauge: gauge, diameter: Self.ring, lineWidth: 4.5, titleFont: .caption2, spacing: 4)
    }
}

// MARK: - Medium Widget
struct MediumWidgetView: View {
    let stats: SystemStats
    @AppStorage(PulseSharedSettings.Keys.showBattery, store: PulseSharedSettings.defaults) private var showBattery = true
    @AppStorage(PulseSharedSettings.Keys.showDisk, store: PulseSharedSettings.defaults) private var showDisk = true

    /// Ring size when the widget also has to say what's wrong.
    private static let attentionRing: CGFloat = 52

    var body: some View {
        let gauges = WidgetGauges.make(stats: stats, showDisk: showDisk, showBattery: showBattery)
        let status = PulseStatus(stats: stats, includesDisk: showDisk, includesBattery: showBattery)
        Group {
            if status.severity >= .high {
                attention(gauges: gauges, status: status)
            } else {
                GaugeRow(gauges: gauges, diameter: 58, lineWidth: 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The same evenly spaced row, a little smaller, under one sentence that
    /// names the problem — so a colored ring never speaks by color alone. The
    /// sentence starts where the first ring does.
    private func attention(gauges: [WidgetGauge], status: PulseStatus) -> some View {
        GeometryReader { geometry in
            let inset = GaugeRow.evenInset(width: geometry.size.width, count: gauges.count, diameter: Self.attentionRing)
            VStack(alignment: .leading, spacing: 14) {
                StatusLine(status: status, font: .subheadline)
                    .lineLimit(1)
                    .padding(.leading, max(inset, 16))
                    .padding(.trailing, 16)

                GaugeRow(gauges: gauges, diameter: Self.attentionRing, lineWidth: 4.5)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

// MARK: - Large Widget
struct LargeWidgetView: View {
    let stats: SystemStats
    @AppStorage(PulseSharedSettings.Keys.showBattery, store: PulseSharedSettings.defaults) private var showBattery = true
    @AppStorage(PulseSharedSettings.Keys.showDisk, store: PulseSharedSettings.defaults) private var showDisk = true
    @AppStorage(PulseSharedSettings.Keys.showNetwork, store: PulseSharedSettings.defaults) private var showNetwork = true
    @AppStorage(PulseSharedSettings.Keys.unitsMode, store: PulseSharedSettings.defaults) private var unitsModeRaw = PulseSharedSettings.UnitsMode.automatic.rawValue

    private var unitsMode: PulseSharedSettings.UnitsMode {
        PulseSharedSettings.UnitsMode(rawValue: unitsModeRaw) ?? .automatic
    }

    private var showsBatteryRow: Bool { showBattery && stats.hasBattery }

    private var isLowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    var body: some View {
        // The cores row is the first thing to go if the widget can't hold
        // everything; nothing is ever squeezed to make room.
        ViewThatFits(in: .vertical) {
            content(showsCores: !stats.cpuCoreUsage.isEmpty)
            content(showsCores: false)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private enum Row: Hashable { case memory, storage, network, battery }

    private var rows: [Row] {
        var rows: [Row] = [.memory]
        if showDisk { rows.append(.storage) }
        if showNetwork { rows.append(.network) }
        if showsBatteryRow { rows.append(.battery) }
        return rows
    }

    /// Fixed rhythm first. When a setting hides rows (or a desktop Mac has no
    /// battery), the gaps may each open up a little, up to a cap, so the
    /// content keeps its proportions instead of leaving one void at the
    /// bottom. The hairline keeps a fixed 16pt on both sides.
    private func content(showsCores: Bool) -> some View {
        let gauges = WidgetGauges.make(stats: stats, showDisk: showDisk, showBattery: showBattery)
        let rows = rows
        // One gap above every subview after the first, in order.
        var gaps: [BreathingStack.Gap] = [
            .init(min: 20, max: 28),    // status → rings
            .fixed(0),                  // rings → hairline (padded)
            .fixed(0)                   // hairline → first row
        ]
        gaps += Array(repeating: .init(min: 15, max: 21), count: max(rows.count - 1, 0))
        if showsCores { gaps.append(.init(min: 15, max: 21)) }

        return BreathingStack(gaps: gaps) {
            // Every condition is named: the worst as the sentence, the
            // others beneath it.
            StatusLine(
                status: PulseStatus(stats: stats, includesDisk: showDisk, includesBattery: showBattery),
                font: .subheadline,
                showsDetail: true,
                detailFont: .caption
            )
            .lineLimit(2)

            GaugeRow(
                gauges: gauges,
                diameter: 64,
                lineWidth: 5.5,
                distribution: gauges.count >= 3 ? .justified : .evenly,
                valueFont: .system(size: 17, weight: .semibold)
            )

            Divider()
                .padding(.vertical, 16)

            ForEach(rows, id: \.self) { row in
                view(for: row)
            }

            if showsCores {
                CoresRow(cores: stats.cpuCoreUsage)
            }
        }
    }

    @ViewBuilder
    private func view(for row: Row) -> some View {
        switch row {
        case .memory: memoryRow
        case .storage: storageRow
        case .network: networkRow
        case .battery: batteryRow
        }
    }

    // MARK: Rows
    // Text only: the rings already show percentages, so these add what the
    // rings can't — amounts, rates, time, and memory pressure in words.

    private var memoryRow: some View {
        let used = PulseFormat.gigabytesText(stats.memoryUsed)
        let total = PulseFormat.capacityText(stats.memoryTotal)
        let severity = stats.memorySeverity
        let pressure = Self.pressurePhrase(severity)
        var spoken = "\(used) of \(total) used"
        if severity >= .high { spoken += ", \(MetricKind.memory.spokenSeverity(severity))" }
        return InfoRow(title: "Memory") {
            // Without room for both, the capacity yields to the pressure.
            ViewThatFits(in: .horizontal) {
                Text(used)
                    + Text(" of \(total)").foregroundStyle(.secondary)
                    + Self.pressureSuffix(pressure, severity: severity)
                Text(used)
                    + Self.pressureSuffix(pressure, severity: severity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Memory"))
        .accessibilityValue(Text(spoken))
    }

    private var storageRow: some View {
        let available = PulseFormat.gigabytesText(stats.diskAvailable)
        return InfoRow(title: "Storage") {
            Text(available)
            + Text(" available").foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Storage"))
        .accessibilityValue(Text("\(available) available"))
    }

    private var networkRow: some View {
        let down = PulseFormat.speed(stats.networkDown, unitsMode: unitsMode)
        let up = PulseFormat.speed(stats.networkUp, unitsMode: unitsMode)
        return InfoRow(title: "Network") {
            rate("arrow.down", stats.networkDown)
            + Text("   ")
            + rate("arrow.up", stats.networkUp)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Network"))
        .accessibilityValue(Text("Download \(down.number) \(down.unit), upload \(up.number) \(up.unit)"))
    }

    private var batteryRow: some View {
        let description = BatteryStatusText.describe(stats)
        let lowPower = isLowPowerMode
        let base: Text = {
            if let split = Self.leadingTime(in: description) {
                // "3:23 remaining": the figure in primary, the words quieter,
                // like "9.9 GB available".
                return Text(split.time) + Text(split.rest).foregroundStyle(.secondary)
            }
            return Text(description)
        }()
        return InfoRow(title: "Battery") {
            // The ring turns yellow in Low Power Mode; the row says why.
            if lowPower {
                ViewThatFits(in: .horizontal) {
                    base + Text(" · ").foregroundStyle(.secondary) + Text("Low Power Mode")
                    Text("Low Power Mode")
                }
            } else {
                base
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery"))
        .accessibilityValue(Text(lowPower ? "\(description), Low Power Mode" : description))
    }

    /// An arrow glyph in secondary followed by the rate in primary, as one
    /// `Text` so the glyph sits on the text baseline.
    private func rate(_ symbol: String, _ value: Double) -> Text {
        let parts = PulseFormat.speed(value, unitsMode: unitsMode)
        return Text(Image(systemName: symbol))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        + Text(" \(parts.number) \(parts.unit)")
    }

    /// "High pressure" / "Critical pressure" when memory pressure is a
    /// problem; nil otherwise.
    private static func pressurePhrase(_ severity: LoadSeverity) -> String? {
        switch severity {
        case .high: return "High pressure"
        case .critical: return "Critical pressure"
        case .nominal, .moderate: return nil
        }
    }

    /// " · High pressure", the words in the contrast-safe severity color.
    private static func pressureSuffix(_ phrase: String?, severity: LoadSeverity) -> Text {
        guard let phrase else { return Text("") }
        let words = Text(phrase)
        return Text(" · ").foregroundStyle(.secondary)
            + (PulseStyle.textTint(for: severity).map { words.foregroundStyle($0) } ?? words)
    }

    /// Splits "3:23 remaining" into ("3:23", " remaining"); nil when the
    /// description doesn't start with a time ("Fully charged").
    private static func leadingTime(in text: String) -> (time: String, rest: String)? {
        guard let space = text.firstIndex(of: " ") else { return nil }
        let head = text[..<space]
        guard head.contains(":"), head.allSatisfy({ $0.isNumber || $0 == ":" }) else { return nil }
        return (String(head), String(text[space...]))
    }
}

// MARK: - Large Widget Pieces

/// A top-aligned, leading-aligned vertical stack with explicit gaps. It asks
/// for its natural height (children plus minimum gaps); given more, it opens
/// the gaps evenly toward their caps and leaves anything beyond at the bottom.
private struct BreathingStack: Layout {
    struct Gap {
        let min: CGFloat
        let max: CGFloat

        static func fixed(_ value: CGFloat) -> Gap { Gap(min: value, max: value) }
    }

    /// `gaps[i]` sits above subview `i + 1`.
    let gaps: [Gap]

    private func gap(_ index: Int) -> Gap {
        index < gaps.count ? gaps[index] : .fixed(0)
    }

    private func heights(_ subviews: Subviews, width: CGFloat?) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }

    private func extras(spare: CGFloat, count: Int) -> [CGFloat] {
        var extra = Array(repeating: CGFloat(0), count: count)
        var remaining = max(spare, 0)
        var open = (0..<count).filter { gap($0).max > gap($0).min }
        while remaining > 0.25, !open.isEmpty {
            let share = remaining / CGFloat(open.count)
            var stillOpen: [Int] = []
            for index in open {
                let room = gap(index).max - gap(index).min - extra[index]
                let added = Swift.min(room, share)
                extra[index] += added
                remaining -= added
                if room - added > 0.01 { stillOpen.append(index) }
            }
            open = stillOpen
        }
        return extra
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let gapCount = Swift.max(subviews.count - 1, 0)
        let natural = heights(subviews, width: width).reduce(0, +)
            + (0..<gapCount).reduce(0) { $0 + gap($1).min }
        let room = (0..<gapCount).reduce(0) { $0 + gap($1).max - gap($1).min }
        guard let proposed = proposal.height, proposed.isFinite else {
            return CGSize(width: width, height: natural)
        }
        return CGSize(width: width, height: Swift.min(Swift.max(proposed, natural), natural + room))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = heights(subviews, width: bounds.width)
        let gapCount = Swift.max(subviews.count - 1, 0)
        let natural = heights.reduce(0, +) + (0..<gapCount).reduce(0) { $0 + gap($1).min }
        let extra = extras(spare: bounds.height - natural, count: gapCount)

        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            if index > 0 { y += gap(index - 1).min + extra[index - 1] }
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: heights[index])
            )
            y += heights[index]
        }
    }
}

/// Title on the leading edge in secondary, value on the trailing edge in
/// primary with monospaced digits.
private struct InfoRow<Value: View>: View {
    let title: String
    @ViewBuilder let value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .font(.body)
        .lineLimit(1)
    }
}

/// "Cores" as a row like the others, with the shared per-core strip on the
/// trailing edge where the other rows' values sit. The label is centered on
/// the meters (the cluster captions hang beneath them). On Macs with many
/// cores the meters narrow rather than overflow.
private struct CoresRow: View {
    let cores: [Double]

    private static let meterHeight: CGFloat = 20

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(barWidth: 6, barSpacing: 4)
            row(barWidth: 4, barSpacing: 3)
            row(barWidth: 3, barSpacing: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("CPU cores"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private func row(barWidth: CGFloat, barSpacing: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Cores")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: Self.meterHeight)
            Spacer(minLength: 8)
            CoreStrip(cores: cores, barWidth: barWidth, height: Self.meterHeight, barSpacing: barSpacing, showsCaptions: true)
        }
    }

    private var accessibilitySummary: String {
        let busiest = cores.max() ?? 0
        return "\(cores.count) cores, busiest at \(PulseFormat.percentText(busiest))"
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
