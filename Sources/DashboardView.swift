import SwiftUI
import Charts
import AppKit
import WidgetKit

// MARK: - Surfaces
/// Grouped-content colors in the style of Health and Fitness: a soft page
/// with raised cards, tuned separately for light and dark appearances.
enum PulseSurface {
    static let page = Color(nsColor: NSColor(name: "PulsePage") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.075, green: 0.075, blue: 0.08, alpha: 1)
            : NSColor(srgbRed: 0.949, green: 0.949, blue: 0.965, alpha: 1)
    })

    static let card = Color(nsColor: NSColor(name: "PulseCard") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.137, green: 0.137, blue: 0.149, alpha: 1)
            : NSColor.white
    })
}

// MARK: - Dashboard
struct DashboardView: View {
    @EnvironmentObject private var statsController: PulseStatsController
    @Environment(\.openSettings) private var openSettings

    @AppStorage(PulseSettings.Keys.showBattery, store: PulseSettings.defaults) private var showBattery = true
    @AppStorage(PulseSettings.Keys.showDisk, store: PulseSettings.defaults) private var showDisk = true
    @AppStorage(PulseSettings.Keys.showNetwork, store: PulseSettings.defaults) private var showNetwork = true

    private var stats: SystemStats { statsController.stats }

    private enum Card: String, Identifiable {
        case cpu, memory, network, storage, battery, system
        var id: String { rawValue }
    }

    private var cards: [Card] {
        var cards: [Card] = [.cpu, .memory]
        if showNetwork { cards.append(.network) }
        if showDisk { cards.append(.storage) }
        if showBattery && stats.hasBattery { cards.append(.battery) }
        cards.append(.system)
        return cards
    }

    private var cardRows: [[Card]] {
        stride(from: 0, to: cards.count, by: 2).map { Array(cards[$0..<min($0 + 2, cards.count)]) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                OverviewHero(stats: stats, refreshInterval: statsController.refreshInterval)

                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    ForEach(cardRows, id: \.first) { row in
                        GridRow {
                            ForEach(row) { card in
                                cardView(card)
                                    .gridCellColumns(row.count == 1 ? 2 : 1)
                            }
                        }
                    }
                }

                WidgetGallery(stats: stats)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .background(PulseSurface.page.ignoresSafeArea())
        .navigationTitle("Pulse")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    statsController.refresh(reloadWidgets: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh Now (⌘R)")

                Button {
                    PulseActions.openActivityMonitor()
                } label: {
                    Label("Activity Monitor", systemImage: "chart.bar.xaxis")
                }
                .help("Open Activity Monitor")

                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Pulse Settings (⌘,)")
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            statsController.refresh()
        }
    }

    private var subtitle: String {
        stats.isStale ? "Waiting for fresh stats" : "Live · \(PulseSharedSettings.intervalDescription(statsController.refreshInterval).lowercased())"
    }

    @ViewBuilder
    private func cardView(_ card: Card) -> some View {
        switch card {
        case .cpu: CPUCard(stats: stats, history: statsController.history)
        case .memory: MemoryCard(stats: stats, history: statsController.history)
        case .network: NetworkCard(stats: stats, history: statsController.history)
        case .storage: StorageCard(stats: stats)
        case .battery: BatteryCard(stats: stats)
        case .system: SystemCard(stats: stats)
        }
    }
}

// MARK: - Overview Hero
struct OverviewHero: View {
    let stats: SystemStats
    let refreshInterval: TimeInterval
    @AppStorage(PulseSettings.Keys.showDisk, store: PulseSettings.defaults) private var showDisk = true

    private var kinds: [MetricKind] { MetricKind.visible(includesDisk: showDisk) }
    private var status: PulseStatus { PulseStatus(stats: stats, includesDisk: showDisk) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            layout(showsGlance: true)
            layout(showsGlance: false)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func layout(showsGlance: Bool) -> some View {
        HStack(alignment: .center, spacing: 0) {
            ConcentricRings(stats: stats, kinds: kinds, lineWidth: 21, gap: 3)
                .frame(width: 172, height: 172)
                .padding(.trailing, 32)
                .animation(.spring(response: 0.7, dampingFraction: 0.85), value: stats.timestamp)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Label {
                        Text(status.headline)
                    } icon: {
                        Image(systemName: status.symbol)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(status.tint)
                    }
                    .font(.system(size: 24, weight: .bold))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: status.headline)

                    Text("\(MachineInfo.chipName) · \(MachineInfo.osVersion) · Up \(PulseSharedSettings.formatUptime(stats.uptime))")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(alignment: .top, spacing: 26) {
                    ForEach(kinds) { kind in
                        HeroStat(kind: kind, stats: stats)
                    }
                }
            }
            .fixedSize()

            Spacer(minLength: showsGlance ? 24 : 0)

            if showsGlance {
                Divider()
                    .frame(height: 140)
                    .padding(.trailing, 24)
                GlanceColumn(stats: stats)
                    .frame(width: 190, alignment: .leading)
            }
        }
    }
}

/// Battery, network and temperature at a glance, beside the rings.
struct GlanceColumn: View {
    let stats: SystemStats
    @AppStorage(PulseSettings.Keys.showBattery, store: PulseSettings.defaults) private var showBattery = true
    @AppStorage(PulseSettings.Keys.showNetwork, store: PulseSettings.defaults) private var showNetwork = true
    @AppStorage(PulseSettings.Keys.unitsMode, store: PulseSettings.defaults) private var unitsModeRaw = PulseSettings.UnitsMode.automatic.rawValue

    private var unitsMode: PulseSettings.UnitsMode {
        PulseSettings.UnitsMode(rawValue: unitsModeRaw) ?? .automatic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showBattery && stats.hasBattery {
                row(
                    symbol: stats.isCharging ? "bolt.fill" : "battery.75percent",
                    tint: .green,
                    title: "Battery",
                    value: "\(stats.batteryLevel)%",
                    detail: BatteryStatusText.describe(stats)
                )
            }
            if showNetwork {
                row(
                    symbol: "arrow.up.arrow.down",
                    tint: PulsePalette.networkDown,
                    title: "Network",
                    value: "↓ \(PulseSharedSettings.formatSpeed(stats.networkDown, unitsMode: unitsMode))",
                    detail: "↑ \(PulseSharedSettings.formatSpeed(stats.networkUp, unitsMode: unitsMode))"
                )
            }
            row(
                symbol: "thermometer.medium",
                tint: stats.thermalLevel.tint,
                title: "Temperature",
                value: stats.thermalLevel.title,
                detail: nil
            )
        }
    }

    private func row(symbol: String, tint: Color, title: String, value: String, detail: String?) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct HeroStat: View {
    let kind: MetricKind
    let stats: SystemStats

    private var severity: LoadSeverity { kind.severity(in: stats) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kind.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind.tint)

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int((SystemStatsMath.unitInterval(kind.value(in: stats)) * 100).rounded()))")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText(value: kind.value(in: stats)))
                Text("%")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .foregroundStyle(PulsePalette.severityTint(severity, fallback: .primary))
            .animation(.snappy, value: kind.value(in: stats))

            Text(MetricDetail.short(kind, stats: stats))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Card Chrome
struct DashboardCard<Accessory: View, Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .labelStyle(.titleAndIcon)
                Spacer(minLength: 8)
                accessory()
            }

            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }
}

extension View {
    func cardBackground() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(PulseSurface.card)
                    .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

/// Big rounded number with a smaller unit, Health-app style.
struct PrimaryValue: View {
    let value: String
    let unit: String
    var caption: String? = nil
    var tint: Color = .primary
    var numeric: Double = 0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: unit == "%" ? 1 : 4) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .contentTransition(.numericText(value: numeric))
            Text(unit)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            if let caption {
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
        .animation(.snappy, value: numeric)
    }
}

// MARK: - CPU Card
struct CPUCard: View {
    let stats: SystemStats
    let history: MetricHistory

    var body: some View {
        DashboardCard(title: "CPU", symbol: "cpu", tint: PulsePalette.cpu) {
            StatusBadge(
                title: stats.cpuSeverity.title,
                symbol: stats.cpuSeverity >= .high ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                tint: PulsePalette.severityTint(stats.cpuSeverity, fallback: .green),
                compact: true
            )
        } content: {
            PrimaryValue(
                value: "\(Int((stats.cpuUsage * 100).rounded()))",
                unit: "%",
                caption: "\(MachineInfo.coreCount) cores",
                numeric: stats.cpuUsage
            )

            MetricHistoryChart(history: history, metric: .cpu)
                .frame(height: 96)

            CoreStrip(cores: stats.cpuCoreUsage)
                .frame(height: 30)

            HStack(spacing: 16) {
                LegendItem(title: "User", value: PulseSharedSettings.percent(stats.cpuUser), color: PulsePalette.cpu)
                LegendItem(title: "System", value: PulseSharedSettings.percent(stats.cpuSystem), color: .teal)
                LegendItem(title: "Idle", value: PulseSharedSettings.percent(1 - stats.cpuUsage), color: Color.secondary.opacity(0.4))
            }
        }
    }
}

// MARK: - Memory Card
struct MemoryCard: View {
    let stats: SystemStats
    let history: MetricHistory

    private var pressureTitle: String {
        switch stats.memoryPressureLevel {
        case .normal?: return "Pressure Normal"
        case .warning?: return "Pressure High"
        case .critical?: return "Pressure Critical"
        case nil: return stats.memorySeverity.title
        }
    }

    var body: some View {
        DashboardCard(title: "Memory", symbol: "memorychip", tint: PulsePalette.memory) {
            StatusBadge(
                title: pressureTitle,
                symbol: stats.memorySeverity >= .high ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent",
                tint: PulsePalette.severityTint(stats.memorySeverity, fallback: .green),
                compact: true
            )
        } content: {
            PrimaryValue(
                value: String(format: stats.memoryUsed >= 10 ? "%.1f" : "%.2f", stats.memoryUsed),
                unit: "GB",
                caption: "of \(PulseSharedSettings.formatGigabytes(stats.memoryTotal))",
                numeric: stats.memoryUsed
            )

            MetricHistoryChart(history: history, metric: .memory)
                .frame(height: 96)

            SegmentedUsageBar(
                segments: [
                    UsageSegment(id: "app", value: stats.memoryApp, color: PulsePalette.memory),
                    UsageSegment(id: "wired", value: stats.memoryWired, color: .teal),
                    UsageSegment(id: "compressed", value: stats.memoryCompressed, color: .indigo),
                    UsageSegment(id: "cached", value: stats.memoryCached, color: Color.secondary.opacity(0.35))
                ],
                total: stats.memoryTotal,
                height: 10
            )
            .animation(.easeOut(duration: 0.35), value: stats.memoryUsed)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    appLegend
                    wiredLegend
                    compressedLegend
                    cachedLegend
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        appLegend
                        wiredLegend
                    }
                    GridRow {
                        compressedLegend
                        cachedLegend
                    }
                }
            }
        }
    }

    private var appLegend: some View {
        LegendItem(title: "App", value: PulseSharedSettings.formatGigabytes(stats.memoryApp), color: PulsePalette.memory)
    }

    private var wiredLegend: some View {
        LegendItem(title: "Wired", value: PulseSharedSettings.formatGigabytes(stats.memoryWired), color: .teal)
    }

    private var compressedLegend: some View {
        LegendItem(title: "Compressed", value: PulseSharedSettings.formatGigabytes(stats.memoryCompressed), color: .indigo)
    }

    private var cachedLegend: some View {
        LegendItem(title: "Cached", value: PulseSharedSettings.formatGigabytes(stats.memoryCached), color: Color.secondary.opacity(0.35))
    }
}

// MARK: - Network Card
struct NetworkCard: View {
    let stats: SystemStats
    let history: MetricHistory
    @AppStorage(PulseSettings.Keys.unitsMode, store: PulseSettings.defaults) private var unitsModeRaw = PulseSettings.UnitsMode.automatic.rawValue

    private var unitsMode: PulseSettings.UnitsMode {
        PulseSettings.UnitsMode(rawValue: unitsModeRaw) ?? .automatic
    }

    var body: some View {
        DashboardCard(title: "Network", symbol: "network", tint: PulsePalette.networkDown) {
            if stats.networkUp < 1 && stats.networkDown < 1 {
                StatusBadge(title: "Idle", symbol: "moon.zzz.fill", tint: .secondary, compact: true)
            }
        } content: {
            HStack(alignment: .top, spacing: 28) {
                rate(title: "Download", symbol: "arrow.down.circle.fill", value: stats.networkDown, tint: PulsePalette.networkDown)
                rate(title: "Upload", symbol: "arrow.up.circle.fill", value: stats.networkUp, tint: PulsePalette.networkUp)
            }

            MetricHistoryChart(history: history, metric: .network)
                .frame(height: 96)
        }
    }

    private func rate(title: String, symbol: String, value: Double, tint: Color) -> some View {
        let parts = PulseSharedSettings.formatSpeed(value, unitsMode: unitsMode).split(separator: " ", maxSplits: 1).map(String.init)
        return VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            PrimaryValue(value: parts.first ?? "0", unit: parts.count > 1 ? parts[1] : "", numeric: value)
        }
    }
}

// MARK: - Storage Card
struct StorageCard: View {
    let stats: SystemStats

    private var free: Double { max(stats.diskTotal - stats.diskUsed - stats.diskPurgeable, 0) }

    var body: some View {
        DashboardCard(title: "Storage", symbol: "internaldrive", tint: PulsePalette.disk) {
            Button("Manage…") {
                PulseActions.openStorageSettings()
            }
            .controlSize(.small)
            .focusEffectDisabled()
        } content: {
            PrimaryValue(
                value: storageNumber(stats.diskAvailable),
                unit: "GB",
                caption: "available of \(PulseSharedSettings.formatGigabytes(stats.diskTotal))",
                numeric: stats.diskAvailable
            )

            SegmentedUsageBar(
                segments: [
                    UsageSegment(id: "used", value: stats.diskUsed, color: PulsePalette.disk),
                    UsageSegment(id: "purgeable", value: stats.diskPurgeable, color: PulsePalette.disk.opacity(0.35))
                ],
                total: stats.diskTotal,
                height: 14
            )

            HStack(spacing: 14) {
                LegendItem(title: "Used", value: PulseSharedSettings.formatGigabytes(stats.diskUsed), color: PulsePalette.disk)
                if stats.diskPurgeable > 0.1 {
                    LegendItem(title: "Purgeable", value: PulseSharedSettings.formatGigabytes(stats.diskPurgeable), color: PulsePalette.disk.opacity(0.35))
                }
                LegendItem(title: "Free", value: PulseSharedSettings.formatGigabytes(free), color: Color.secondary.opacity(0.3))
            }

            Text(storageAdvice)
                .font(.system(size: 12))
                .foregroundStyle(stats.diskSeverity >= .high ? PulsePalette.severityTint(stats.diskSeverity, fallback: .secondary) : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func storageNumber(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private var storageAdvice: String {
        switch stats.diskSeverity {
        case .nominal, .moderate:
            return "Purgeable space is counted as available. macOS frees it automatically when needed."
        case .high:
            return "Storage is getting full. Review large files in Storage settings."
        case .critical:
            return "Your startup disk is almost full. Free up space to keep your Mac running smoothly."
        }
    }
}

// MARK: - Battery Card
struct BatteryCard: View {
    let stats: SystemStats

    private var tint: Color {
        PulsePalette.batteryTint(level: stats.batteryLevel, isCharging: stats.isCharging, hasBattery: stats.hasBattery)
    }

    var body: some View {
        DashboardCard(title: "Battery", symbol: "battery.75percent", tint: .green) {
            Button("Settings…") {
                PulseActions.openBatterySettings()
            }
            .controlSize(.small)
            .focusEffectDisabled()
        } content: {
            HStack(alignment: .center, spacing: 18) {
                BatteryMeter(level: stats.batteryLevel, isCharging: stats.isCharging, tint: tint)
                    .frame(width: 92, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    PrimaryValue(value: "\(stats.batteryLevel)", unit: "%", numeric: Double(stats.batteryLevel))
                    Text(BatteryStatusText.describe(stats))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(stats.isCharging ? .green : .secondary)
                }
            }

            VStack(spacing: 0) {
                DetailRow(title: "Power Source", value: BatteryStatusText.powerSource(stats))
                Divider()
                DetailRow(title: "Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
            }
        }
    }
}

/// A large battery outline with a proportional fill.
struct BatteryMeter: View {
    let level: Int
    let isCharging: Bool
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let capWidth = geometry.size.width * 0.06
            let bodyWidth = geometry.size.width - capWidth - 2
            HStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: geometry.size.height * 0.24, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 2)
                    RoundedRectangle(cornerRadius: geometry.size.height * 0.16, style: .continuous)
                        .fill(tint == .primary ? Color.primary.opacity(0.85) : tint)
                        .frame(width: max((bodyWidth - 8) * CGFloat(min(max(level, 0), 100)) / 100, 4))
                        .padding(4)
                    if isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: geometry.size.height * 0.45, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 1)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: bodyWidth)

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: capWidth, height: geometry.size.height * 0.36)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: level)
        .accessibilityHidden(true)
    }
}

// MARK: - System Card
struct SystemCard: View {
    let stats: SystemStats

    var body: some View {
        DashboardCard(title: "This Mac", symbol: "laptopcomputer", tint: .secondary) {
            EmptyView()
        } content: {
            VStack(spacing: 0) {
                DetailRow(title: "Chip", value: MachineInfo.chipName)
                Divider()
                DetailRow(title: "Memory", value: PulseSharedSettings.formatGigabytes(stats.memoryTotal))
                Divider()
                DetailRow(title: "Software", value: MachineInfo.osVersion)
                Divider()
                DetailRow(title: "Uptime", value: PulseSharedSettings.formatUptime(stats.uptime))
                Divider()
                HStack {
                    Text("Thermal State")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Circle()
                        .fill(stats.thermalLevel.tint)
                        .frame(width: 7, height: 7)
                    Text(stats.thermalLevel.title)
                }
                .font(.system(size: 13))
                .padding(.vertical, 7)
                if stats.swapUsed > 0.05 {
                    Divider()
                    DetailRow(title: "Swap Used", value: PulseSharedSettings.formatGigabytes(stats.swapUsed))
                }
            }
        }
    }
}

struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 13))
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Charts
/// Live history for one metric. The x-domain is fixed to the window so the
/// line enters from the right and scrolls, like Activity Monitor.
struct MetricHistoryChart: View {
    enum Metric { case cpu, memory, network }

    let history: MetricHistory
    let metric: Metric

    private var domain: ClosedRange<Int> {
        let upper = history.samples.last?.id ?? 0
        return (upper - history.capacity + 1)...upper
    }

    var body: some View {
        Chart {
            switch metric {
            case .cpu:
                usageMarks(\.cpu, tint: PulsePalette.cpu, label: "CPU")
            case .memory:
                usageMarks(\.memory, tint: PulsePalette.memory, label: "Memory")
            case .network:
                ForEach(history.samples) { sample in
                    AreaMark(x: .value("Time", sample.id), y: .value("Download", sample.networkDown))
                        .foregroundStyle(gradient(PulsePalette.networkDown))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.id), y: .value("Download", sample.networkDown), series: .value("Direction", "Download"))
                        .foregroundStyle(PulsePalette.networkDown)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.id), y: .value("Upload", sample.networkUp), series: .value("Direction", "Upload"))
                        .foregroundStyle(PulsePalette.networkUp)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...yUpperBound)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: yAxisValues) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(axisLabel(number))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    @ChartContentBuilder
    private func usageMarks(_ keyPath: KeyPath<MetricSample, Double>, tint: Color, label: String) -> some ChartContent {
        ForEach(history.samples) { sample in
            AreaMark(x: .value("Time", sample.id), y: .value(label, sample[keyPath: keyPath]))
                .foregroundStyle(gradient(tint))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", sample.id), y: .value(label, sample[keyPath: keyPath]))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
    }

    private func gradient(_ tint: Color) -> LinearGradient {
        LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom)
    }

    private var yUpperBound: Double {
        metric == .network ? history.networkCeiling : 1
    }

    private var yAxisValues: [Double] {
        metric == .network ? [0, yUpperBound / 2, yUpperBound] : [0, 0.5, 1]
    }

    private func axisLabel(_ value: Double) -> String {
        guard metric == .network else {
            return "\(Int((value * 100).rounded()))%"
        }
        if value <= 0 { return "0" }
        return PulseSharedSettings.formatSpeed(value, unitsMode: .automatic)
    }

    private var accessibilitySummary: String {
        switch metric {
        case .cpu: return "CPU history over the last \(history.samples.count) samples"
        case .memory: return "Memory history over the last \(history.samples.count) samples"
        case .network: return "Network history over the last \(history.samples.count) samples"
        }
    }
}

/// CPU and memory together, for compact surfaces like the menu bar.
struct UsageHistoryChart: View {
    let history: MetricHistory
    var showsAxis = true

    private var domain: ClosedRange<Int> {
        let upper = history.samples.last?.id ?? 0
        return (upper - history.capacity + 1)...upper
    }

    var body: some View {
        Chart {
            ForEach(history.samples) { sample in
                AreaMark(x: .value("Time", sample.id), y: .value("CPU", sample.cpu))
                    .foregroundStyle(LinearGradient(colors: [PulsePalette.cpu.opacity(0.3), PulsePalette.cpu.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", sample.id), y: .value("CPU", sample.cpu), series: .value("Metric", "CPU"))
                    .foregroundStyle(PulsePalette.cpu)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", sample.id), y: .value("Memory", sample.memory), series: .value("Metric", "Memory"))
                    .foregroundStyle(PulsePalette.memory)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(showsAxis ? .automatic : .hidden)
        .chartLegend(.hidden)
        .accessibilityLabel(Text("CPU and memory history"))
    }
}

// MARK: - Widget Gallery
struct WidgetGallery: View {
    let stats: SystemStats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Widgets")
                    .font(.system(size: 20, weight: .bold))
                Text("Right-click your desktop and choose Edit Widgets, then search for Pulse.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    preview("Small", width: 170, height: 170) { SmallWidgetView(stats: stats) }
                    preview("Medium", width: 364, height: 170) { MediumWidgetView(stats: stats) }
                    preview("Large", width: 364, height: 382) { LargeWidgetView(stats: stats) }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func preview<Content: View>(_ title: String, width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10) {
            content()
                .frame(width: width, height: height)
                .background(PulseSurface.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(title) widget preview"))
    }
}
