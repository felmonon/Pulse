import SwiftUI

@MainActor
final class DynamicIslandPresentation: ObservableObject {
    @Published var isExpanded = false
    @Published var notchHeight: CGFloat

    init(notchHeight: CGFloat) {
        self.notchHeight = notchHeight
    }
}

// MARK: - Dynamic Island View
/// Renders the Dynamic Island content: a compact resting pill (CPU%) that
/// expands on click to the full system breakdown. All values come from the
/// existing `PulseStatsController` model — this view introduces no new data.
///
/// The controller is observed (not snapshotted) so the island updates live as
/// stats refresh.
struct DynamicIslandView: View {
    @ObservedObject var statsController: PulseStatsController
    @ObservedObject var presentation: DynamicIslandPresentation
    let onToggle: () -> Void

    @AppStorage(PulseSharedSettings.Keys.unitsMode, store: PulseSharedSettings.defaults) private var unitsModeRaw = PulseSharedSettings.UnitsMode.automatic.rawValue
    @AppStorage(PulseSharedSettings.Keys.showBattery, store: PulseSharedSettings.defaults) private var showBattery = true
    @AppStorage(PulseSharedSettings.Keys.showDisk, store: PulseSharedSettings.defaults) private var showDisk = true
    @AppStorage(PulseSharedSettings.Keys.showNetwork, store: PulseSharedSettings.defaults) private var showNetwork = true
    @AppStorage(PulseSharedSettings.Keys.showActiveApps, store: PulseSharedSettings.defaults) private var showActiveApps = true

    private var stats: SystemStats { statsController.stats }
    private var isExpanded: Bool { presentation.isExpanded }

    private var pressure: PressureSummary {
        PressureSummary.highest(for: stats, includesDisk: showDisk)
    }

    private var unitsMode: PulseSharedSettings.UnitsMode {
        PulseSharedSettings.UnitsMode(rawValue: unitsModeRaw) ?? .automatic
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black)

            content
        }
        .onTapGesture(perform: onToggle)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Click to \(isExpanded ? "collapse" : "expand")."))
        .accessibilityAddTraits(.isButton)
    }

    private var cornerRadius: CGFloat { isExpanded ? 20 : 12 }

    private var content: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: max(presentation.notchHeight, 1))
                .allowsHitTesting(false)

            if isExpanded {
                expandedContent
            } else {
                restingContent
            }
        }
    }

    private var restingContent: some View {
        HStack(spacing: 7) {
            Image(systemName: pressure.severity >= .high ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(pressureColor)

            Text("\(pressure.label) \(pressure.percentText)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()

            if pressure.severity >= .high {
                Text(pressureStatus)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(pressureColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.ramBlue)

                Text("Pulse")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                Text("\(pressure.label) \(pressure.percentText) \(pressureStatus)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(pressureColor)
                    .monospacedDigit()
            }

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)

            metricRow(icon: "cpu", label: "CPU", value: PulseSharedSettings.percent(stats.cpuUsage), color: AppColors.cpuGreen)
            metricRow(icon: "memorychip", label: "RAM", value: ramValue, color: AppColors.ramBlue)

            if showDisk {
                metricRow(icon: "internaldrive", label: "Disk", value: diskValue, color: AppColors.diskAmber)
            }

            if showBattery {
                metricRow(icon: batteryIcon, label: "Battery", value: batteryValue, color: batteryColor)
            }

            if showNetwork {
                metricRow(icon: "network", label: "Network", value: networkValue, color: AppColors.networkBlue)
            }

            if showActiveApps, !stats.activeApps.isEmpty {
                metricRow(
                    icon: "macwindow.on.rectangle",
                    label: "Apps",
                    value: stats.activeApps.prefix(2).joined(separator: ", "),
                    color: .white.opacity(0.72)
                )
            }

            if stats.isStale {
                HStack(spacing: 3) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 9))
                    Text("Stats need a refresh")
                        .font(.system(size: 10))
                }
                .foregroundStyle(AppColors.diskAmber)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func metricRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 13)

            Text(label)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.white.opacity(0.62))

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: - Formatted values (reuse existing PulseSharedSettings helpers)

    private var ramValue: String {
        "\(PulseSharedSettings.percent(stats.memoryUsage)) · \(PulseSharedSettings.formatGigabytes(stats.memoryUsed))"
    }

    private var diskValue: String {
        "\(PulseSharedSettings.formatGigabytes(stats.diskAvailable)) free"
    }

    private var batteryValue: String {
        guard stats.hasBattery else { return "AC" }
        return "\(stats.batteryLevel)%\(stats.isCharging ? " charging" : "")"
    }

    private var batteryIcon: String {
        guard stats.hasBattery else { return "powerplug" }
        return stats.isCharging ? "battery.100.bolt" : "battery.100"
    }

    private var batteryColor: Color {
        guard stats.hasBattery else { return .secondary }
        if stats.batteryLevel <= 20 { return AppColors.critical }
        if stats.batteryLevel < 50 { return AppColors.diskAmber }
        return AppColors.batteryGreen
    }

    private var networkValue: String {
        "Down \(PulseSharedSettings.formatSpeed(stats.networkDown, unitsMode: unitsMode))  Up \(PulseSharedSettings.formatSpeed(stats.networkUp, unitsMode: unitsMode))"
    }

    private var pressureColor: Color {
        switch pressure.severity {
        case .nominal:
            return AppColors.cpuGreen
        case .moderate:
            return pressure.color
        case .high:
            return AppColors.diskAmber
        case .critical:
            return AppColors.critical
        }
    }

    private var pressureStatus: String {
        switch pressure.severity {
        case .nominal:
            return "OK"
        case .moderate:
            return "Normal"
        case .high:
            return "High"
        case .critical:
            return "Critical"
        }
    }

    private var accessibilityLabel: String {
        isExpanded
            ? "Pulse island expanded. \(expandedContentSummary)"
            : "Pulse island. \(pressure.label) \(pressure.percentText), \(pressureStatus)."
    }

    private var expandedContentSummary: String {
        var values = [
            "CPU \(PulseSharedSettings.percent(stats.cpuUsage))",
            "RAM \(PulseSharedSettings.percent(stats.memoryUsage))"
        ]
        if showDisk { values.append("disk \(diskValue)") }
        if showBattery { values.append("battery \(batteryValue)") }
        if showNetwork { values.append("network \(networkValue)") }
        if showActiveApps, !stats.activeApps.isEmpty {
            values.append("active apps \(stats.activeApps.prefix(2).joined(separator: ", "))")
        }
        if stats.isStale { values.append("stats need a refresh") }
        return values.joined(separator: ", ") + "."
    }
}
