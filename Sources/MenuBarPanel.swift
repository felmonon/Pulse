import SwiftUI
import AppKit

// MARK: - Menu Bar Panel
/// The menu-bar window, modeled on the system Battery and Wi-Fi menus: a
/// header with the status sentence, a few plain rows of live values, then
/// menu-style actions. No tiles, no per-metric color: every bar is the accent
/// until its value is genuinely high, and every number stays primary.
struct MenuBarPanel: View {
    @EnvironmentObject private var statsController: PulseStatsController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @AppStorage(PulseSettings.Keys.showBattery, store: PulseSettings.defaults) private var showBattery = true
    @AppStorage(PulseSettings.Keys.showDisk, store: PulseSettings.defaults) private var showDisk = true
    @AppStorage(PulseSettings.Keys.showNetwork, store: PulseSettings.defaults) private var showNetwork = true
    @AppStorage(PulseSettings.Keys.islandEnabled, store: PulseSettings.defaults) private var islandEnabled = false
    @AppStorage(PulseSettings.Keys.unitsMode, store: PulseSettings.defaults) private var unitsModeRaw = PulseSettings.UnitsMode.automatic.rawValue

    private var stats: SystemStats { statsController.stats }
    private var status: PulseStatus {
        PulseStatus(stats: stats, includesDisk: showDisk, includesBattery: showBattery)
    }
    private var unitsMode: PulseSettings.UnitsMode { PulseSettings.UnitsMode(rawValue: unitsModeRaw) ?? .automatic }
    private var showsBatteryRow: Bool { showBattery && stats.hasBattery }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, PanelLayout.edge)
                .padding(.top, 12)
                .padding(.bottom, 10)

            PanelSeparator()

            VStack(alignment: .leading, spacing: PanelLayout.rowSpacing) {
                ForEach(MetricKind.visible(includesDisk: showDisk)) { kind in
                    metricRow(kind)
                }
            }
            .padding(.horizontal, PanelLayout.edge)
            .padding(.vertical, PanelLayout.sectionPadding)

            if showNetwork || showsBatteryRow {
                PanelSeparator()

                VStack(alignment: .leading, spacing: 8) {
                    if showNetwork { networkRow }
                    if showsBatteryRow { batteryRow }
                }
                .padding(.horizontal, PanelLayout.edge)
                .padding(.vertical, PanelLayout.sectionPadding)
            }

            if DynamicIslandPanel.notchIsPresent {
                PanelSeparator()
                islandRow
                    .padding(.horizontal, PanelLayout.edge)
                    .padding(.vertical, 6)
            }

            PanelSeparator()

            VStack(alignment: .leading, spacing: 0) {
                PanelMenuItem(title: "Open Pulse") {
                    NSApp.activate()
                    openWindow(id: PulseSettings.mainWindowID)
                }
                PanelMenuItem(title: "Open Activity Monitor") {
                    PulseActions.openActivityMonitor()
                }
                PanelMenuItem(title: "Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                PanelSeparator()
                PanelMenuItem(title: "Quit Pulse") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.bottom, PanelLayout.itemInset)
        }
        .frame(width: PanelLayout.width)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Pulse")
                .font(.headline)
            // Names every condition in words (headline + detail), so the
            // orange and red bars below never carry a warning alone. Callout
            // matches StatusLine's detail line, so the two sentences read as
            // one paragraph rather than a smaller headline over larger text.
            StatusLine(status: status, font: .callout, showsDetail: true)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Metrics

    /// CPU, Memory and Storage share one rhythm: title and percent, then a
    /// thin bar. Severity colors the bar; the number stays primary.
    private func metricRow(_ kind: MetricKind) -> some View {
        let value = kind.value(in: stats)
        let severity = kind.severity(in: stats)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(kind.title)
                Spacer(minLength: 8)
                // Memory's bar shows occupancy, so its pressure is said in
                // words beside the value rather than by coloring the bar.
                if kind == .memory, severity >= .high, let tint = PulseStyle.textTint(for: severity) {
                    Text(severity >= .critical ? "Critical pressure" : "High pressure")
                        .font(.callout)
                        .foregroundStyle(tint)
                }
                ValueText(PulseFormat.percent(value), size: .compact, numeric: value)
            }
            UsageBar(value: value, tint: PulseStyle.markTint(for: kind.markSeverity(in: stats)), height: 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(kind.title))
        .accessibilityValue(Text(accessibilityValue(kind, percent: value, severity: severity)))
    }

    private func accessibilityValue(_ kind: MetricKind, percent value: Double, severity: LoadSeverity) -> String {
        let percent = PulseFormat.percentText(value)
        return severity >= .high ? "\(percent), \(kind.spokenSeverity(severity))" : percent
    }

    // MARK: Network and Battery

    private var networkRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Network")
            Spacer(minLength: 8)
            rate(symbol: "arrow.down", value: stats.networkDown)
            rate(symbol: "arrow.up", value: stats.networkUp)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Network"))
        .accessibilityValue(Text("Download \(speedText(stats.networkDown)), upload \(speedText(stats.networkUp))"))
    }

    private func rate(symbol: String, value: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ValueText(PulseFormat.speed(value, unitsMode: unitsMode), size: .compact, numeric: value)
        }
    }

    private func speedText(_ value: Double) -> String {
        let parts = PulseFormat.speed(value, unitsMode: unitsMode)
        return parts.unit.isEmpty ? parts.number : "\(parts.number) \(parts.unit)"
    }

    /// Battery-menu phrasing: "3:23 remaining  82%". A low battery is named by
    /// the status line above, so the number stays primary here too.
    private var batteryRow: some View {
        let level = stats.batteryLevel
        let detail = BatteryStatusText.describe(stats)

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Battery")
            Spacer(minLength: 8)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            ValueText(("\(level)", "%"), size: .compact, numeric: Double(level))
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery"))
        .accessibilityValue(Text("\(level) percent, \(detail)"))
    }

    // MARK: Notch Island

    private var islandRow: some View {
        HStack {
            Text("Notch Island")
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Toggle("Notch Island", isOn: $islandEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .onChange(of: islandEnabled) { _, _ in
            NotificationCenter.default.post(name: .pulseIslandSettingChanged, object: nil)
        }
    }
}

// MARK: - Layout
private enum PanelLayout {
    static let width: CGFloat = 300
    /// Leading edge of every label, shared by info rows and menu items.
    static let edge: CGFloat = 14
    /// Inset of the menu-item highlight from the panel edge.
    static let itemInset: CGFloat = 5
    static let itemHeight: CGFloat = 24
    static let sectionPadding: CGFloat = 10
    static let rowSpacing: CGFloat = 12
}

// MARK: - Separator
/// A menu separator: a hairline aligned to the label column.
private struct PanelSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, PanelLayout.edge)
            .padding(.vertical, 5)
    }
}

// MARK: - Menu Item
/// A row that behaves like an NSMenu item: full width, text only, accent
/// highlight with white text while the pointer is over it.
private struct PanelMenuItem: View {
    let title: String
    let action: () -> Void

    @State private var isHighlighted = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: PanelLayout.itemHeight, alignment: .leading)
                .padding(.horizontal, PanelLayout.edge - PanelLayout.itemInset)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHighlighted ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, PanelLayout.itemInset)
        .onHover { isHighlighted = $0 }
    }
}
