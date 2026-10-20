import SwiftUI
import Charts
import AppKit

// MARK: - Menu Bar Panel
/// The menu-bar window, laid out like a Control Center module stack: status
/// up top, rings and live history, compact tiles, then actions.
struct MenuBarPanel: View {
    @EnvironmentObject private var statsController: PulseStatsController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @AppStorage(PulseSettings.Keys.showBattery, store: PulseSettings.defaults) private var showBattery = true
    @AppStorage(PulseSettings.Keys.showDisk, store: PulseSettings.defaults) private var showDisk = true
    @AppStorage(PulseSettings.Keys.showNetwork, store: PulseSettings.defaults) private var showNetwork = true
    @AppStorage(PulseSettings.Keys.islandEnabled, store: PulseSettings.defaults) private var islandEnabled = false

    private var stats: SystemStats { statsController.stats }
    private var kinds: [MetricKind] { MetricKind.visible(includesDisk: showDisk) }
    private var status: PulseStatus { PulseStatus(stats: stats, includesDisk: showDisk) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, 4)

            ringsModule

            historyModule

            if showNetwork || showBattery {
                HStack(spacing: 10) {
                    if showNetwork { networkTile }
                    if showBattery { powerTile }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if DynamicIslandPanel.notchIsPresent {
                islandToggle
            }

            Divider()
                .padding(.horizontal, 4)

            VStack(spacing: 1) {
                PanelActionRow(title: "Open Pulse", symbol: "macwindow") {
                    NSApp.activate()
                    openWindow(id: PulseSettings.mainWindowID)
                }
                PanelActionRow(title: "Activity Monitor", symbol: "chart.bar.xaxis") {
                    PulseActions.openActivityMonitor()
                }
                PanelActionRow(title: "Settings…", symbol: "gearshape") {
                    NSApp.activate()
                    openSettings()
                }
                PanelActionRow(title: "Quit Pulse", symbol: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pulse")
                    .font(.system(size: 13, weight: .bold))
                Label(status.headline, systemImage: status.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(status.severity >= .high || status.isHot ? status.tint : .secondary)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                statsController.refresh(reloadWidgets: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Refresh Now")
            .accessibilityLabel(Text("Refresh Now"))
        }
    }

    // MARK: Modules

    private var ringsModule: some View {
        HStack(spacing: 16) {
            ConcentricRings(stats: stats, kinds: kinds, lineWidth: 9.5, gap: 1.5)
                .frame(width: 80, height: 80)
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: stats.cpuUsage)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(kinds) { kind in
                    let severity = kind.severity(in: stats)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(kind.ring.start)
                            .frame(width: 7, height: 7)
                        Text(kind.title)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        if severity >= .high {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(PulsePalette.severityTint(severity, fallback: kind.tint))
                        }
                        Text(PulseSharedSettings.percent(kind.value(in: stats)))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: kind.value(in: stats)))
                            .foregroundStyle(PulsePalette.severityTint(severity, fallback: .primary))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityElement(children: .combine)
                }
            }
            .animation(.snappy, value: stats.timestamp)
        }
        .moduleStyle()
    }

    private var historyModule: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                LegendItem(title: "CPU", color: PulsePalette.cpu)
                LegendItem(title: "Memory", color: PulsePalette.memory)
            }

            UsageHistoryChart(history: statsController.history, showsAxis: false)
                .frame(height: 52)
        }
        .moduleStyle()
    }

    private var networkTile: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Network", systemImage: "network")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            NetworkRateStack(up: stats.networkUp, down: stats.networkDown)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .moduleStyle()
    }

    private var powerTile: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(stats.hasBattery ? "Battery" : "Power", systemImage: stats.hasBattery ? "battery.75percent" : "powerplug")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(stats.hasBattery ? "\(stats.batteryLevel)%" : "AC")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(PulsePalette.batteryTint(level: stats.batteryLevel, isCharging: stats.isCharging, hasBattery: stats.hasBattery))
                if stats.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
            Text(stats.hasBattery ? BatteryStatusText.describe(stats) : "Up \(PulseSharedSettings.formatUptime(stats.uptime))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .moduleStyle()
    }

    private var islandToggle: some View {
        HStack(spacing: 10) {
            Image(systemName: "capsule.tophalf.filled")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(islandEnabled ? .white : .secondary)
                .frame(width: 26, height: 26)
                .background(islandEnabled ? Color.accentColor : Color.primary.opacity(0.08), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("Notch Island")
                    .font(.system(size: 12, weight: .medium))
                Text("Live stats around the notch")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Toggle("Notch Island", isOn: $islandEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .moduleStyle(padding: 8)
        .onChange(of: islandEnabled) { _, _ in
            NotificationCenter.default.post(name: .pulseIslandSettingChanged, object: nil)
        }
    }
}

// MARK: - Network Rate Stack
struct NetworkRateStack: View {
    let up: Double
    let down: Double
    @AppStorage(PulseSharedSettings.Keys.unitsMode, store: PulseSharedSettings.defaults) private var unitsModeRaw = PulseSharedSettings.UnitsMode.automatic.rawValue

    private var unitsMode: PulseSharedSettings.UnitsMode {
        PulseSharedSettings.UnitsMode(rawValue: unitsModeRaw) ?? .automatic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(symbol: "arrow.down.circle.fill", value: down, tint: PulsePalette.networkDown)
            row(symbol: "arrow.up.circle.fill", value: up, tint: PulsePalette.networkUp)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Download \(PulseSharedSettings.formatSpeed(down, unitsMode: unitsMode)), upload \(PulseSharedSettings.formatSpeed(up, unitsMode: unitsMode))"))
    }

    private func row(symbol: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .font(.system(size: 12))
            Text(PulseSharedSettings.formatSpeed(value, unitsMode: unitsMode))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Panel Action Row
/// A menu-style row with the system hover highlight.
struct PanelActionRow: View {
    let title: String
    let symbol: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isHovering ? .white : .secondary)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isHovering ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Module Style
extension View {
    /// The rounded, softly filled tile used for Control Center–style modules.
    func moduleStyle(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}
