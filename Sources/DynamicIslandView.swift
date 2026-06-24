import SwiftUI

// MARK: - Dynamic Island View
/// Renders the Dynamic Island content: a compact resting pill (CPU%) that
/// expands on click to the full system breakdown. All values come from the
/// existing `PulseStatsController` model — this view introduces no new data.
///
/// The controller is observed (not snapshotted) so the island updates live as
/// stats refresh.
struct DynamicIslandView: View {
    @ObservedObject var statsController: PulseStatsController
    @Binding var isExpanded: Bool

    @AppStorage(PulseSharedSettings.Keys.unitsMode, store: PulseSharedSettings.defaults) private var unitsModeRaw = PulseSharedSettings.UnitsMode.automatic.rawValue

    private var stats: SystemStats { statsController.stats }

    private var unitsMode: PulseSharedSettings.UnitsMode {
        PulseSharedSettings.UnitsMode(rawValue: unitsModeRaw) ?? .automatic
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black)

            content
        }
        // The whole pill toggles on tap.
        .onTapGesture {
            isExpanded.toggle()
        }
        .frame(width: isExpanded ? DynamicIslandMath.expandedWidth : DynamicIslandMath.restingWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Click to \(isExpanded ? "collapse" : "expand")."))
    }

    private var cornerRadius: CGFloat { isExpanded ? 26 : 0 }

    @ViewBuilder
    private var content: some View {
        if isExpanded {
            expandedContent
        } else {
            restingContent
        }
    }

    private var restingContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AppColors.cpuGreen)
            Text(PulseSharedSettings.percent(stats.cpuUsage))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            metricRow(icon: "cpu", label: "CPU", value: PulseSharedSettings.percent(stats.cpuUsage), color: AppColors.cpuGreen)
            metricRow(icon: "memorychip", label: "RAM", value: ramValue, color: AppColors.ramBlue)
            metricRow(icon: "internaldrive", label: "Disk", value: diskValue, color: AppColors.diskAmber)
            metricRow(icon: batteryIcon, label: "Battery", value: batteryValue, color: batteryColor)
            metricRow(icon: "network", label: "Network", value: networkValue, color: AppColors.networkBlue)
            if !stats.activeApps.isEmpty {
                metricRow(icon: "macwindow.on.rectangle", label: "Apps", value: stats.activeApps.prefix(3).joined(separator: ", "), color: .white.opacity(0.6))
            }
            if stats.isStale {
                HStack(spacing: 3) {
                    Image(systemName: "clock.badge.exclamationmark").font(.system(size: 8))
                    Text("Stale").font(.system(size: 9))
                }
                .foregroundStyle(AppColors.diskAmber)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: DynamicIslandMath.expandedWidth, alignment: .leading)
    }

    private func metricRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 8, weight: .medium)).foregroundStyle(color)
            Text(label).font(.system(size: 9, weight: .regular)).foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 9, weight: .regular, design: .rounded))
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
        return "\(stats.batteryLevel)%\(stats.isCharging ? " ⚡" : "")"
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
        "↓\(PulseSharedSettings.formatSpeed(stats.networkDown, unitsMode: unitsMode)) ↑\(PulseSharedSettings.formatSpeed(stats.networkUp, unitsMode: unitsMode))"
    }

    private var accessibilityLabel: String {
        isExpanded
            ? "Pulse island expanded. \(expandedContentSummary)"
            : "Pulse island. CPU \(PulseSharedSettings.percent(stats.cpuUsage))."
    }

    private var expandedContentSummary: String {
        "CPU \(PulseSharedSettings.percent(stats.cpuUsage)), RAM \(PulseSharedSettings.percent(stats.memoryUsage)), disk \(diskValue), battery \(batteryValue), network \(networkValue)."
    }
}
