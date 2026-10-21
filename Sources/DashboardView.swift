import SwiftUI
import Charts
import AppKit

// MARK: - Main Window
/// Pulse's main window: a source-list sidebar and quiet, System Settings–style
/// detail panes. Monochrome chrome, one accent for data; severity colors a
/// value's mark, never its number (see docs/design/pulse-design-language.md).
struct DashboardView: View {
    @EnvironmentObject private var statsController: PulseStatsController

    /// Persisted in the standard defaults so the window reopens where it was
    /// left; also accepts `-pulse.selectedSection <page>` at launch.
    @AppStorage("pulse.selectedSection") private var selection: Page = .overview
    @AppStorage(PulseSettings.Keys.unitsMode, store: PulseSettings.defaults)
    private var unitsModeRaw = PulseSharedSettings.UnitsMode.automatic.rawValue
    @AppStorage(PulseSettings.Keys.showDisk, store: PulseSettings.defaults) private var showDisk = true
    @AppStorage(PulseSettings.Keys.showNetwork, store: PulseSettings.defaults) private var showNetwork = true
    @AppStorage(PulseSettings.Keys.showBattery, store: PulseSettings.defaults) private var showBattery = true

    private var visibility: Visibility {
        Visibility(
            storage: showDisk,
            network: showNetwork,
            battery: showBattery && statsController.stats.hasBattery
        )
    }

    private var context: PageContext {
        PageContext(
            stats: statsController.stats,
            history: statsController.history,
            unitsMode: PulseSharedSettings.UnitsMode(rawValue: unitsModeRaw) ?? .automatic,
            sampleInterval: statsController.refreshInterval,
            visibility: visibility
        )
    }

    private var pages: [Page] {
        Page.allCases.filter { visibility.shows($0) }
    }

    /// The selection, falling back to Overview when the stored page is hidden
    /// in Settings or not available on this Mac (e.g. Battery on a desktop).
    private var page: Page {
        pages.contains(selection) ? selection : .overview
    }

    private var sidebarSelection: Binding<Page?> {
        Binding(
            get: { page },
            set: { newValue in
                if let newValue { selection = newValue }
            }
        )
    }

    var body: some View {
        let context = context

        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(pages) { item in
                    SidebarRow(page: item)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            PageView(page: page, context: context) { selection = $0 }
                .navigationTitle(page.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            PulseActions.openActivityMonitor()
                        } label: {
                            Label("Activity Monitor", systemImage: "arrow.up.forward.app")
                        }
                        .help("Open Activity Monitor")
                    }
                }
        }
        .frame(minWidth: 760, minHeight: 540)
        .onChange(of: pages) { _, available in
            // A page hidden in Settings should not stay selected behind the scenes.
            if !available.contains(selection) { selection = .overview }
        }
    }
}

// MARK: - Pages
private enum Page: String, CaseIterable, Identifiable {
    case overview, cpu, memory, storage, network, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .storage: return "Storage"
        case .network: return "Network"
        case .battery: return "Battery"
        }
    }

    func symbol(for stats: SystemStats) -> String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .network: return "network"
        case .battery: return BatteryStatusText.symbol(stats)
        }
    }
}

/// Which optional metrics the person chose to show (Settings › Metrics).
private struct Visibility: Equatable {
    let storage: Bool
    let network: Bool
    let battery: Bool

    func shows(_ page: Page) -> Bool {
        switch page {
        case .overview, .cpu, .memory: return true
        case .storage: return storage
        case .network: return network
        case .battery: return battery
        }
    }
}

/// Everything a page needs to draw one frame.
private struct PageContext {
    let stats: SystemStats
    let history: MetricHistory
    let unitsMode: PulseSharedSettings.UnitsMode
    let sampleInterval: TimeInterval
    let visibility: Visibility

    var status: PulseStatus {
        PulseStatus(stats: stats, includesDisk: visibility.storage, includesBattery: visibility.battery)
    }

    /// "Last 90 seconds": the span every history chart covers.
    var windowCaption: String {
        let total = Int((Double(history.capacity) * sampleInterval).rounded())
        if total < 120 { return "Last \(total) seconds" }
        let minutes = Int((Double(total) / 60).rounded())
        if minutes < 120 { return "Last \(minutes) minutes" }
        return "Last \(minutes / 60) hours"
    }

    func speed(_ value: Double) -> String {
        PulseSharedSettings.formatSpeed(value, unitsMode: unitsMode)
    }

    func speedParts(_ value: Double) -> (number: String, unit: String) {
        PulseFormat.speed(value, unitsMode: unitsMode)
    }
}

private struct PageView: View {
    let page: Page
    let context: PageContext
    let select: (Page) -> Void

    var body: some View {
        switch page {
        case .overview: OverviewPage(context: context, select: select)
        case .cpu: CPUPage(context: context)
        case .memory: MemoryPage(context: context)
        case .storage: StoragePage(context: context)
        case .network: NetworkPage(context: context)
        case .battery: BatteryPage(context: context)
        }
    }
}

// MARK: - Sidebar
/// A source-list row with its current figure trailing, like a Mail count.
/// The title never truncates: it keeps its full width, and the figure gives
/// way instead (the network arrow is dropped first). Each row observes the
/// controller itself so the figure never lags the detail pane (sidebar cells
/// are not always rebuilt with their parent).
private struct SidebarRow: View {
    @EnvironmentObject private var statsController: PulseStatsController

    let page: Page

    private var stats: SystemStats { statsController.stats }

    var body: some View {
        HStack(spacing: 0) {
            Label(page.title, systemImage: page.symbol(for: stats))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            Spacer(minLength: 10)
            value
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(page.title))
        .accessibilityValue(Text(accessibilityValue))
    }

    @ViewBuilder
    private var value: some View {
        switch page {
        case .overview:
            EmptyView()
        case .cpu:
            Text(PulseFormat.percentText(stats.cpuUsage))
        case .memory:
            Text(PulseFormat.percentText(stats.memoryUsage))
        case .storage:
            Text(PulseFormat.percentText(stats.diskUsage))
        case .network:
            let rate = PulseFormat.dominantRate(down: stats.networkDown, up: stats.networkUp)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 3) {
                    Image(systemName: rate.symbol)
                        .imageScale(.small)
                    Text(speed(rate.value))
                }
                Text(speed(rate.value))
            }
        case .battery:
            Text("\(stats.batteryLevel)%")
        }
    }

    /// Always the automatic unit, whatever the Network speed setting: the
    /// figure is then never wider than "999 KB/s" or "9.9 MB/s". The unit
    /// preference applies to the Overview and the Network page.
    private func speed(_ value: Double) -> String {
        let parts = PulseFormat.speed(value, unitsMode: .automatic)
        return "\(parts.number) \(parts.unit)"
    }

    private var accessibilityValue: String {
        switch page {
        case .overview: return ""
        case .cpu: return PulseFormat.percentText(stats.cpuUsage)
        case .memory: return "\(PulseFormat.percentText(stats.memoryUsage)) used"
        case .storage: return "\(PulseFormat.percentText(stats.diskUsage)) full"
        case .network:
            let rate = PulseFormat.dominantRate(down: stats.networkDown, up: stats.networkUp)
            return "\(rate.isDownload ? "Download" : "Upload") \(speed(rate.value))"
        case .battery: return "\(stats.batteryLevel)%"
        }
    }
}

// MARK: - Overview
/// Status in words, then the five metrics: CPU and Memory large with their
/// history, Storage, Network and Battery smaller beneath. Hidden metrics
/// leave no holes; the remaining tiles share the row.
private struct OverviewPage: View {
    let context: PageContext
    let select: (Page) -> Void

    private let spacing: CGFloat = 16
    /// The history marks in the first row: this tall at rest, and at most
    /// `OverviewStack.maxGrowth` taller in a tall window.
    private let historyMarkHeight: CGFloat = 64

    private var stats: SystemStats { context.stats }
    private var history: MetricHistory { context.history }
    private var visibility: Visibility { context.visibility }

    private var machineCaption: String {
        [MachineInfo.chipName, MachineInfo.osVersion, "Up \(PulseFormat.uptime(stats.uptime))"]
            .joined(separator: " · ")
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                content(fillHeight: viewport.size.height - PulseStyle.pagePadding * 2)
                    .padding(PulseStyle.pagePadding)
            }
        }
    }

    /// The page without its scroll view, growing toward `fillHeight`.
    func content(fillHeight: CGFloat) -> some View {
        OverviewStack(gaps: [28, spacing], fillHeight: fillHeight) {
            VStack(alignment: .leading, spacing: 0) {
                StatusLine(status: context.status, showsDetail: true)
                Text(machineCaption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: spacing) {
                cpuTile
                memoryTile
            }

            if visibility.storage || visibility.network || visibility.battery {
                HStack(alignment: .top, spacing: spacing) {
                    if visibility.storage { storageTile }
                    if visibility.network { networkTile }
                    if visibility.battery { batteryTile }
                }
            }
        }
    }

    // Row 1 — history at a readable size.

    private var cpuTile: some View {
        let detail = "User \(PulseFormat.percentText(stats.cpuUser)) · System \(PulseFormat.percentText(stats.cpuSystem))"
        return OverviewTile(
            title: "CPU",
            detail: Text(detail),
            accessibilityValue: spoken(PulseFormat.percentText(stats.cpuUsage), detail, alert(.cpu)),
            markHeight: historyMarkHeight,
            growsMark: true,
            action: { select(.cpu) }
        ) {
            ValueText(PulseFormat.percent(stats.cpuUsage), size: .tile, numeric: stats.cpuUsage)
        } mark: {
            sparkline(history.samples.map(\.cpu), kind: .cpu, title: "CPU history")
        }
    }

    private var memoryTile: some View {
        let detail = "\(PulseFormat.gigabytesText(stats.memoryUsed)) of \(PulseFormat.capacityText(stats.memoryTotal))"
        return OverviewTile(
            title: "Memory",
            detail: Text(detail),
            accessibilityValue: spoken(PulseFormat.percentText(stats.memoryUsage), detail, alert(.memory)),
            markHeight: historyMarkHeight,
            growsMark: true,
            action: { select(.memory) }
        ) {
            ValueText(PulseFormat.percent(stats.memoryUsage), size: .tile, numeric: stats.memoryUsage)
        } mark: {
            sparkline(history.samples.map(\.memory), kind: .memory, title: "Memory history")
        }
    }

    // Row 2 — one short mark each, bottoms aligned.

    private var storageTile: some View {
        let detail = "\(PulseFormat.gigabytesText(stats.diskAvailable)) available"
        return OverviewTile(
            title: "Storage",
            detail: Text(detail),
            accessibilityValue: spoken("\(PulseFormat.percentText(stats.diskUsage)) full", detail, alert(.disk)),
            markHeight: 32,
            action: { select(.storage) }
        ) {
            ValueText(PulseFormat.percent(stats.diskUsage), size: .tile, numeric: stats.diskUsage)
        } mark: {
            UsageBar(
                value: stats.diskUsage,
                tint: PulseStyle.markTint(for: MetricKind.disk.markSeverity(in: stats)),
                height: 6
            )
        }
    }

    private var networkTile: some View {
        let rate = PulseFormat.dominantRate(down: stats.networkDown, up: stats.networkUp)
        // The hero shows the busier direction; the detail only the other one.
        let other = rate.isDownload
            ? (symbol: "arrow.up", value: stats.networkUp, name: "upload")
            : (symbol: "arrow.down", value: stats.networkDown, name: "download")
        return OverviewTile(
            title: "Network",
            detail: Text(Image(systemName: other.symbol)) + Text(" \(context.speed(other.value)) \(other.name)"),
            accessibilityValue: "Download \(context.speed(stats.networkDown)), upload \(context.speed(stats.networkUp))",
            markHeight: 32,
            action: { select(.network) }
        ) {
            DirectionalValue(symbol: rate.symbol, parts: context.speedParts(rate.value), numeric: rate.value)
        } mark: {
            sparkline(
                history.samples.map(\.networkDown),
                secondary: history.samples.map(\.networkUp),
                upperBound: history.networkCeiling,
                title: "Network history"
            )
        }
    }

    private var batteryTile: some View {
        let detail = BatteryStatusText.describe(stats)
        let isLow = BatteryStatusText.severity(stats) >= .high
        return OverviewTile(
            title: "Battery",
            detail: Text(detail),
            accessibilityValue: spoken("\(stats.batteryLevel)%", detail, isLow ? "battery low" : nil),
            markHeight: 32,
            action: { select(.battery) }
        ) {
            ValueText(("\(stats.batteryLevel)", "%"), size: .tile, numeric: Double(stats.batteryLevel))
        } mark: {
            UsageBar(value: Double(stats.batteryLevel) / 100, tint: PulseStyle.batteryMarkTint(stats), height: 6)
        }
    }

    /// A tile's history: the line is always the accent, and only the point on
    /// the latest sample takes the metric's current severity, so the past is
    /// never repainted. Until there are enough samples to read as a line, the
    /// tile shows just its baseline and a faint midline.
    private func sparkline(
        _ values: [Double],
        kind: MetricKind? = nil,
        secondary: [Double]? = nil,
        upperBound: Double = 1,
        title: String
    ) -> LineHistoryChart {
        LineHistoryChart(
            values: values,
            capacity: history.capacity,
            secondaryValues: secondary,
            upperBound: upperBound,
            accessibilityTitle: title,
            latestTint: kind.map { PulseStyle.markTint(for: $0.markSeverity(in: stats)) },
            hidesYoungHistory: true,
            showsMidline: true
        )
    }

    /// Spoken when a metric needs attention, so VoiceOver hears what the
    /// status sentence and the mark's color say.
    private func alert(_ kind: MetricKind) -> String? {
        let severity = kind.severity(in: stats)
        return severity >= .high ? kind.spokenSeverity(severity) : nil
    }

    private func spoken(_ parts: String?...) -> String {
        parts.compactMap { $0 }.joined(separator: ", ")
    }
}

/// Stacks the Overview's header and tile rows. When the window is taller than
/// the content, the first tile row (CPU and Memory) takes up to `maxGrowth`
/// of the slack, so their history grows to a readable height (about 120pt)
/// without turning into a tall, empty plot; any remaining slack stays below
/// the tiles. When the window is shorter, the page scrolls at natural size.
/// Each row is proposed one height, so the tiles in a row always match.
private struct OverviewStack: Layout {
    var gaps: [CGFloat]
    var fillHeight: CGFloat
    var growingRow = 1
    var maxGrowth: CGFloat = 56

    private func gap(after index: Int) -> CGFloat {
        gaps.indices.contains(index) ? gaps[index] : gaps.last ?? 0
    }

    private func rowHeights(width: CGFloat?, subviews: Subviews) -> [CGFloat] {
        var heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let gapsTotal = (0..<max(subviews.count - 1, 0)).reduce(0) { $0 + gap(after: $1) }
        let natural = heights.reduce(0, +) + gapsTotal
        if heights.indices.contains(growingRow), fillHeight > natural {
            heights[growingRow] += min(fillHeight - natural, maxGrowth)
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let heights = rowHeights(width: proposal.width, subviews: subviews)
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let gapsTotal = (0..<max(subviews.count - 1, 0)).reduce(0) { $0 + gap(after: $1) }
        return CGSize(width: width, height: heights.reduce(0, +) + gapsTotal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = rowHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: heights[index])
            )
            y += heights[index] + gap(after: index)
        }
    }
}

/// A quiet, clickable summary: label, number, one line of detail and a mark
/// pinned to the bottom so every tile in a row lines up.
private struct OverviewTile<Number: View, Mark: View>: View {
    let title: String
    let detail: Text
    let accessibilityValue: String
    /// The mark's height, or its minimum when it grows to fill the window.
    let markHeight: CGFloat
    var growsMark = false
    let action: () -> Void
    @ViewBuilder let number: () -> Number
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                number()
                    .padding(.top, 6)

                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 2)

                Spacer(minLength: 16)

                mark()
                    .frame(
                        minHeight: markHeight,
                        idealHeight: markHeight,
                        maxHeight: growsMark ? .infinity : markHeight,
                        alignment: .bottom
                    )
                    .frame(maxWidth: .infinity, alignment: .bottom)
                    .layoutPriority(1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(TileButtonStyle())
        // The sidebar already offers the same navigation by keyboard; keeping
        // tiles out of the key loop stops the first tile grabbing focus (and
        // a focus ring) at launch. VoiceOver can still activate them.
        .focusable(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint(Text("Shows \(title) details"))
        .accessibilityAddTraits(.isButton)
    }
}

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileChrome(configuration: configuration)
    }

    private struct TileChrome: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        private var fill: Color {
            if configuration.isPressed { return Color.primary.opacity(0.08) }
            if isHovered { return Color.primary.opacity(0.055) }
            return PulseStyle.tileFill
        }

        var body: some View {
            configuration.label
                .background(fill, in: RoundedRectangle(cornerRadius: PulseStyle.cornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: PulseStyle.cornerRadius, style: .continuous))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isHovered)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

// MARK: - Shared Page Parts
/// The large light number and one secondary line that open every detail pane.
/// The hero keeps proportional digits, so pages apply `.monospacedDigit()` to
/// their live rows only, never to the whole form.
private struct PageHeader: View {
    let value: (number: String, unit: String)
    let numeric: Double
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ValueText(value, size: .hero, numeric: numeric)
            Text(caption)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }
}

/// The busier network direction: a secondary arrow, then the speed.
private struct DirectionalValue: View {
    let symbol: String
    let parts: (number: String, unit: String)
    var size: ValueText.Size = .tile
    let numeric: Double

    private var arrowFont: Font {
        switch size {
        case .hero: return .system(size: 30, weight: .light)
        case .tile: return .system(size: 19, weight: .regular)
        case .row, .compact: return .callout
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size == .hero ? 6 : 4) {
            Image(systemName: symbol)
                .font(arrowFont)
                .foregroundStyle(.secondary)
            ValueText(parts, size: size, numeric: numeric)
        }
    }
}

/// One live history chart with its time span and an optional legend.
private struct HistoryBlock<Legend: View>: View {
    let caption: String
    let chart: LineHistoryChart
    @ViewBuilder var legend: () -> Legend

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer(minLength: 12)
                legend()
            }
            chart
                .frame(height: 190)
        }
        .padding(.vertical, 6)
    }
}

private extension HistoryBlock where Legend == EmptyView {
    init(caption: String, chart: LineHistoryChart) {
        self.init(caption: caption, chart: chart) {
            EmptyView()
        }
    }
}

/// A legend row for a segmented bar: swatch, name, value.
private struct SwatchRow: View {
    let title: String
    let index: Int
    var tint: Color = PulseStyle.accent
    /// Overrides the swatch's shade, matching a segment that overrides its own.
    var color: Color? = nil
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
        } label: {
            HStack(spacing: 8) {
                SegmentSwatch(index: index, tint: tint, color: color)
                Text(title)
            }
        }
    }
}

/// The page's single action, set trailing beneath the last group.
private struct PageAction: View {
    let title: String
    var note: String? = nil
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if let note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(title, action: action)
        }
        .padding(.top, 4)
    }
}

private extension View {
    /// Applies a severity text color only when there is one; otherwise leaves
    /// the system's own label color in place.
    @ViewBuilder
    func attentionTint(_ color: Color?) -> some View {
        if let color {
            foregroundStyle(color)
        } else {
            self
        }
    }
}

// MARK: - CPU
private struct CPUPage: View {
    let context: PageContext
    private var stats: SystemStats { context.stats }

    var body: some View {
        Form {
            sections
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    var sections: some View {
        Section {
            HistoryBlock(
                caption: context.windowCaption,
                chart: LineHistoryChart(
                    values: context.history.samples.map(\.cpu),
                    capacity: context.history.capacity,
                    showsAxis: true,
                    accessibilityTitle: "CPU history, \(context.windowCaption.lowercased())",
                    latestTint: PulseStyle.markTint(for: MetricKind.cpu.markSeverity(in: stats))
                )
            )
        } header: {
            PageHeader(
                value: PulseFormat.percent(stats.cpuUsage),
                numeric: stats.cpuUsage,
                caption: "User \(PulseFormat.percentText(stats.cpuUser)) · System \(PulseFormat.percentText(stats.cpuSystem))"
            )
        }

        if !stats.cpuCoreUsage.isEmpty {
            Section("Cores") {
                // Captioned Efficiency | Performance clusters in the accent:
                // per-core load is normal; severity belongs to the total.
                CoreStrip(cores: stats.cpuCoreUsage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
        }

        Section {
            Group {
                LabeledContent("Chip", value: MachineInfo.chipName)
                LabeledContent("Uptime", value: PulseFormat.uptime(stats.uptime))
                LabeledContent("Thermal state") {
                    Text(stats.thermalLevel.title)
                        .attentionTint(stats.thermalLevel.attentionTint)
                }
            }
            .monospacedDigit()
        }
    }
}

// MARK: - Memory
private struct MemoryPage: View {
    let context: PageContext
    private var stats: SystemStats { context.stats }

    var body: some View {
        Form {
            sections
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    var sections: some View {
        Section {
            // Occupancy is not a problem by itself, so the line stays the
            // accent; memory pressure is said in words below.
            HistoryBlock(
                caption: context.windowCaption,
                chart: LineHistoryChart(
                    values: context.history.samples.map { $0.memory * stats.memoryTotal },
                    capacity: context.history.capacity,
                    upperBound: max(stats.memoryTotal, 1),
                    showsAxis: true,
                    axisLabel: { PulseFormat.capacityText($0) },
                    accessibilityTitle: "Memory used, \(context.windowCaption.lowercased())",
                    latestTint: PulseStyle.markTint(for: MetricKind.memory.markSeverity(in: stats))
                )
            )
        } header: {
            PageHeader(
                value: PulseFormat.gigabytes(stats.memoryUsed),
                numeric: stats.memoryUsed,
                caption: "used of \(PulseFormat.capacityText(stats.memoryTotal)) · \(PulseFormat.percentText(stats.memoryUsage))"
            )
        }

        Section {
            SegmentedBar(
                segments: [
                    .init(id: "app", value: stats.memoryApp),
                    .init(id: "wired", value: stats.memoryWired),
                    .init(id: "compressed", value: stats.memoryCompressed)
                ],
                total: stats.memoryTotal
            )
            .padding(.vertical, 6)
            SwatchRow(title: "App memory", index: 0, value: PulseFormat.gigabytesText(stats.memoryApp))
            SwatchRow(title: "Wired memory", index: 1, value: PulseFormat.gigabytesText(stats.memoryWired))
            SwatchRow(title: "Compressed", index: 2, value: PulseFormat.gigabytesText(stats.memoryCompressed))
        }

        Section {
            Group {
                LabeledContent("Memory pressure") {
                    Text(stats.memorySeverity.title)
                        .attentionTint(PulseStyle.textTint(for: stats.memorySeverity))
                }
                LabeledContent("Cached files", value: PulseFormat.gigabytesText(stats.memoryCached))
                LabeledContent("Swap used", value: stats.swapUsed > 0.005 ? PulseFormat.gigabytesText(stats.swapUsed) : "None")
            }
            .monospacedDigit()
        }
    }
}

// MARK: - Storage
private struct StoragePage: View {
    let context: PageContext
    private var stats: SystemStats { context.stats }

    /// Purgeable space is neither a problem nor free yet: a neutral shade.
    private let purgeableColor = Color.secondary.opacity(0.45)

    private var freeSpace: Double {
        max(stats.diskAvailable - stats.diskPurgeable, 0)
    }

    /// Only the Used segment carries the disk's severity.
    private var usedTint: Color {
        PulseStyle.markTint(for: MetricKind.disk.markSeverity(in: stats))
    }

    private var footnote: String? {
        stats.diskSeverity >= .high
            ? "Freeing up space helps macOS install updates and keep your Mac responsive."
            : nil
    }

    var body: some View {
        Form {
            sections
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    var sections: some View {
        Section {
            SegmentedBar(
                segments: [
                    .init(id: "used", value: stats.diskUsed),
                    .init(id: "purgeable", value: stats.diskPurgeable, color: purgeableColor)
                ],
                total: stats.diskTotal,
                tint: usedTint
            )
            .padding(.vertical, 6)
            SwatchRow(title: "Used", index: 0, tint: usedTint, value: PulseFormat.gigabytesText(stats.diskUsed))
            SwatchRow(title: "Purgeable", index: 1, color: purgeableColor, value: PulseFormat.gigabytesText(stats.diskPurgeable))
            SwatchRow(title: "Free", index: -1, value: PulseFormat.gigabytesText(freeSpace))
        } header: {
            PageHeader(
                value: PulseFormat.gigabytes(stats.diskAvailable),
                numeric: stats.diskAvailable,
                caption: "available of \(PulseFormat.capacityText(stats.diskTotal)) · \(PulseFormat.percentText(stats.diskUsage)) full"
            )
        }

        Section {
            LabeledContent("Volume", value: StartupVolume.name)
            LabeledContent("Format", value: StartupVolume.format)
            LabeledContent("Capacity", value: PulseFormat.capacityText(stats.diskTotal))
                .monospacedDigit()
        } footer: {
            PageAction(title: "Storage Settings…", note: footnote) {
                PulseActions.openStorageSettings()
            }
        }
    }
}

// MARK: - Network
private struct NetworkPage: View {
    let context: PageContext
    private var stats: SystemStats { context.stats }
    private var samples: [MetricSample] { context.history.samples }

    private func peak(_ keyPath: KeyPath<MetricSample, Double>) -> String {
        context.speed(samples.map { $0[keyPath: keyPath] }.max() ?? 0)
    }

    private func average(_ keyPath: KeyPath<MetricSample, Double>) -> String {
        guard !samples.isEmpty else { return context.speed(0) }
        return context.speed(samples.reduce(0) { $0 + $1[keyPath: keyPath] } / Double(samples.count))
    }

    var body: some View {
        Form {
            sections
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    var sections: some View {
        let axis = SpeedAxis(ceiling: context.history.networkCeiling, unitsMode: context.unitsMode)

        Section {
            // The chart's caption states the span once; the peak and average
            // rows sit directly beneath it and share it.
            HistoryBlock(
                caption: context.windowCaption,
                chart: LineHistoryChart(
                    values: samples.map(\.networkDown),
                    capacity: context.history.capacity,
                    secondaryValues: samples.map(\.networkUp),
                    upperBound: axis.ceiling,
                    showsAxis: true,
                    axisLabel: { axis.isTick($0) ? axis.tickLabel($0) : context.speed($0) },
                    accessibilityTitle: "Download history, \(context.windowCaption.lowercased())"
                )
            ) {
                HStack(spacing: 14) {
                    LegendKey(title: "Download", style: .solid)
                    LegendKey(title: "Upload", style: .dashed)
                }
            }
        } header: {
            HStack(alignment: .top, spacing: 24) {
                RateHeader(title: "Download", parts: context.speedParts(stats.networkDown), numeric: stats.networkDown)
                RateHeader(title: "Upload", parts: context.speedParts(stats.networkUp), numeric: stats.networkUp)
            }
            .textCase(nil)
            .padding(.bottom, 10)
        }

        Section {
            Group {
                LabeledContent("Peak download", value: peak(\.networkDown))
                LabeledContent("Peak upload", value: peak(\.networkUp))
                LabeledContent("Average download", value: average(\.networkDown))
                LabeledContent("Average upload", value: average(\.networkUp))
            }
            .monospacedDigit()
        }
    }
}

/// One direction of the Network header: a quiet label over a large number.
private struct RateHeader: View {
    let title: String
    let parts: (number: String, unit: String)
    let numeric: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
            ValueText(parts, size: .hero, numeric: numeric)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A short line drawn exactly like its series, then the series name.
private struct LegendKey: View {
    enum Style { case solid, dashed }

    let title: String
    let style: Style

    var body: some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 1, y: 1))
                path.addLine(to: CGPoint(x: 15, y: 1))
            }
            .stroke(
                style == .solid ? AnyShapeStyle(PulseStyle.accent) : AnyShapeStyle(Color.secondary),
                style: StrokeStyle(
                    lineWidth: style == .solid ? 1.5 : 1.2,
                    lineCap: .round,
                    dash: style == .solid ? [] : [3, 2]
                )
            )
            .frame(width: 16, height: 2)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Battery
private struct BatteryPage: View {
    let context: PageContext
    private var stats: SystemStats { context.stats }

    private var timeRow: (title: String, value: String) {
        let value = stats.batteryMinutesRemaining.map { PulseFormat.batteryTime(minutes: $0) } ?? "—"
        if stats.isCharging { return ("Time until full", value) }
        return ("Time remaining", stats.isPluggedIn ? "—" : value)
    }

    var body: some View {
        Form {
            sections
        }
        .formStyle(.grouped)
    }

    /// The caption already names the power source ("On battery power",
    /// "Charging", "Power adapter"), so no row repeats it.
    @ViewBuilder
    var sections: some View {
        Section {
            UsageBar(value: Double(stats.batteryLevel) / 100, tint: PulseStyle.batteryMarkTint(stats), height: 6)
                .padding(.vertical, 8)

            LabeledContent(timeRow.title, value: timeRow.value)
                .monospacedDigit()
            LabeledContent("Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
        } header: {
            PageHeader(
                value: ("\(stats.batteryLevel)", "%"),
                numeric: Double(stats.batteryLevel),
                caption: BatteryStatusText.powerState(stats)
            )
        } footer: {
            PageAction(title: "Battery Settings…") {
                PulseActions.openBatterySettings()
            }
        }
    }
}

// MARK: - Speed Axis
/// A network chart's vertical scale in one unit. The ceiling is rounded up so
/// its half is a clean tick too, and all three ticks (0, half, ceiling) share
/// KB/s or MB/s, chosen from the ceiling, so the reader never converts
/// between gridlines ("0 MB/s · 0.5 MB/s · 1.0 MB/s").
private struct SpeedAxis {
    /// The top of the chart, in KB/s.
    let ceiling: Double
    let usesMegabytes: Bool
    /// Decimals shared by every non-zero tick.
    private let decimals: Int

    init(ceiling kilobytes: Double, unitsMode: PulseSharedSettings.UnitsMode) {
        // KB/s: halves of 10, 20, 30… are whole numbers. MB/s: even steps,
        // so sub-1 MB/s ceilings keep a one-decimal half (0.2, 0.4…).
        let kilobyteCeiling = Self.rounded(max(kilobytes, 8), steps: [1, 2, 3, 4, 5, 6, 8, 10])
        switch unitsMode {
        case .automatic:
            // Same switch as the figures: never a four-digit KB/s tick.
            usesMegabytes = kilobyteCeiling >= 999.5
        case .kilobytesPerSecond:
            usesMegabytes = false
        case .megabytesPerSecond:
            usesMegabytes = true
        }

        if usesMegabytes {
            let megabytes = Self.rounded(max(kilobytes / 1024, 0.2), steps: [1, 2, 4, 6, 8, 10])
            ceiling = megabytes * 1024
            decimals = Self.decimals(for: megabytes / 2)
        } else {
            ceiling = kilobyteCeiling
            decimals = 0
        }
    }

    /// True for the values the chart draws as ticks.
    func isTick(_ kilobytes: Double) -> Bool {
        [0, ceiling / 2, ceiling].contains { abs($0 - kilobytes) <= ceiling * 1e-6 }
    }

    /// "0.5 MB/s". Ticks too wide for the axis column ("2,000 KB/s" with the
    /// KB/s setting) drop their unit; the zero tick always keeps it, so the
    /// axis still names its one unit.
    func tickLabel(_ kilobytes: Double) -> String {
        let unit = usesMegabytes ? "MB/s" : "KB/s"
        let isZero = kilobytes <= ceiling * 1e-6
        guard !isZero else { return "0 \(unit)" }
        let number = usesMegabytes
            ? String(format: "%.\(decimals)f", kilobytes / 1024)
            : PulseFormat.speed(kilobytes, unitsMode: .kilobytesPerSecond).number
        let label = "\(number) \(unit)"
        return label.count <= 8 ? label : number
    }

    /// `value` rounded up to the next step × power of ten.
    private static func rounded(_ value: Double, steps: [Double]) -> Double {
        let magnitude = pow(10, floor(log10(value)))
        let step = steps.first { $0 * magnitude >= value * (1 - 1e-9) } ?? 10
        return step * magnitude
    }

    /// The decimals needed to write `value` exactly (0.5 → 1, 3 → 0).
    private static func decimals(for value: Double) -> Int {
        var places = 0
        while places < 3, abs(value * pow(10, Double(places)) - (value * pow(10, Double(places))).rounded()) > 1e-6 {
            places += 1
        }
        return places
    }
}

// MARK: - Machine Details
private enum StartupVolume {
    private static let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
        .volumeLocalizedNameKey,
        .volumeLocalizedFormatDescriptionKey
    ])

    static let name = values?.volumeLocalizedName ?? "Macintosh HD"
    static let format = values?.volumeLocalizedFormatDescription ?? "APFS"
}
