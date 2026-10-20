import SwiftUI
import Charts

/// Transient, system-initiated states the island can show at rest, the way
/// the iPhone shows a charging activity when power connects.
enum IslandActivity: Equatable {
    case charging
}

@MainActor
final class DynamicIslandPresentation: ObservableObject {
    @Published var isExpanded = false
    @Published var notchHeight: CGFloat
    @Published var activity: IslandActivity?

    init(notchHeight: CGFloat) {
        self.notchHeight = notchHeight
    }
}

// MARK: - Island Shape
/// The silhouette of the MacBook notch: flush with the top of the screen,
/// with small concave shoulders at the top corners and rounded bottom
/// corners. Both radii animate so resting ↔ expanded morphs smoothly.
struct IslandShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(min(topCornerRadius, rect.width / 4, rect.height / 2), 0)
        let bottom = max(min(bottomCornerRadius, rect.height - top, (rect.width - top * 2) / 2), 0)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Dynamic Island View
/// At rest the island is notch-height, with live content in the two ears
/// beside the cutout. Click to grow it downward into a full summary.
///
/// The controller is observed (not snapshotted) so the island updates live as
/// stats refresh.
struct DynamicIslandView: View {
    @ObservedObject var statsController: PulseStatsController
    @ObservedObject var presentation: DynamicIslandPresentation
    let onToggle: () -> Void

    @AppStorage(PulseSharedSettings.Keys.showBattery, store: PulseSharedSettings.defaults) private var showBattery = true
    @AppStorage(PulseSharedSettings.Keys.showDisk, store: PulseSharedSettings.defaults) private var showDisk = true
    @AppStorage(PulseSharedSettings.Keys.showNetwork, store: PulseSharedSettings.defaults) private var showNetwork = true

    private var stats: SystemStats { statsController.stats }
    private var isExpanded: Bool { presentation.isExpanded }
    private var kinds: [MetricKind] { MetricKind.visible(includesDisk: showDisk) }

    private var pressure: PressureSummary {
        PressureSummary.highest(for: stats, includesDisk: showDisk)
    }

    private var status: PulseStatus {
        PulseStatus(stats: stats, includesDisk: showDisk)
    }

    private var shape: IslandShape {
        IslandShape(
            topCornerRadius: isExpanded ? 12 : 7,
            bottomCornerRadius: isExpanded ? 32 : 12
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(Color.black)

            if isExpanded {
                expandedContent
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).animation(.spring(response: 0.42, dampingFraction: 0.86).delay(0.06)),
                            removal: .opacity.animation(.easeOut(duration: 0.12))
                        )
                    )
            } else {
                compactContent
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(shape)
        .onTapGesture(perform: onToggle)
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: isExpanded)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Click to \(isExpanded ? "collapse" : "expand")."))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
    }

    // MARK: Compact (resting)

    private var compactContent: some View {
        HStack(spacing: 0) {
            leadingEar
                .frame(width: DynamicIslandMath.compactEarWidth, alignment: .center)
            Spacer(minLength: 0)
            trailingEar
                .frame(width: DynamicIslandMath.compactEarWidth, alignment: .center)
        }
        .padding(.horizontal, 4)
        .frame(height: max(presentation.notchHeight, 1))
        .id(presentation.activity)
        .transition(.blurReplace)
    }

    @ViewBuilder
    private var leadingEar: some View {
        switch presentation.activity {
        case .charging:
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.green)
                .symbolEffect(.pulse, options: .repeating)
        case nil:
            ConcentricRings(stats: stats, kinds: kinds, lineWidth: 3.2, gap: 1)
                .frame(width: ringSide, height: ringSide)
        }
    }

    @ViewBuilder
    private var trailingEar: some View {
        switch presentation.activity {
        case .charging:
            HStack(spacing: 4) {
                Text("\(stats.batteryLevel)%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                Image(systemName: "battery.100percent.bolt")
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.green, .white.opacity(0.5))
            }
        case nil:
            HStack(spacing: 3) {
                Image(systemName: pressure.severity >= .high ? "exclamationmark.triangle.fill" : pressure.kind.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(pressure.percentText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: pressure.progress))
            }
            .foregroundStyle(PulsePalette.severityTint(pressure.severity, fallback: pressure.kind.tint))
            .animation(.snappy, value: pressure.percentText)
        }
    }

    private var ringSide: CGFloat {
        min(max(presentation.notchHeight - 14, 14), 22)
    }

    // MARK: Expanded

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Pulse", systemImage: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Label(status.shortTitle, systemImage: status.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status.tint)
            }
            .labelStyle(.titleAndIcon)
            .frame(height: max(presentation.notchHeight, 1))
            .padding(.horizontal, 26)

            HStack(alignment: .center, spacing: 20) {
                ConcentricRings(stats: stats, kinds: kinds, lineWidth: 11, gap: 2)
                    .frame(width: 100, height: 100)

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(kinds) { kind in
                        metricRow(kind)
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 8)

            Spacer(minLength: 8)

            HStack(spacing: 14) {
                if showNetwork {
                    NetworkRates(up: stats.networkUp, down: stats.networkDown, fontSize: 11)
                }
                Spacer(minLength: 0)
                if showBattery {
                    HStack(spacing: 6) {
                        Text(BatteryStatusText.describe(stats))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                        BatteryGlyph(
                            level: stats.batteryLevel,
                            isCharging: stats.isCharging,
                            hasBattery: stats.hasBattery
                        )
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func metricRow(_ kind: MetricKind) -> some View {
        let severity = kind.severity(in: stats)
        return HStack(spacing: 10) {
            Text(kind.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 58, alignment: .leading)

            Text(PulseSharedSettings.percent(kind.value(in: stats)))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: kind.value(in: stats)))
                .foregroundStyle(PulsePalette.severityTint(severity, fallback: kind.tint))
                .frame(width: 46, alignment: .trailing)

            Group {
                switch kind {
                case .cpu:
                    IslandSparkline(values: statsController.history.samples.map(\.cpu), tint: kind.tint, capacity: statsController.history.capacity)
                case .memory:
                    IslandSparkline(values: statsController.history.samples.map(\.memory), tint: kind.tint, capacity: statsController.history.capacity)
                case .disk:
                    Text("\(PulseSharedSettings.formatGigabytes(stats.diskAvailable)) free")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: 150, height: 16, alignment: .leading)
        }
        .animation(.snappy, value: kind.value(in: stats))
    }

    // MARK: Accessibility

    private var accessibilityLabel: String {
        if presentation.activity == .charging {
            return "Pulse island. Charging, \(stats.batteryLevel) percent."
        }
        return isExpanded
            ? "Pulse island expanded. \(expandedContentSummary)"
            : "Pulse island. \(pressure.label) \(pressure.percentText), \(pressure.severity.title)."
    }

    private var expandedContentSummary: String {
        var values = kinds.map { "\($0.title) \(PulseSharedSettings.percent($0.value(in: stats)))" }
        if showBattery { values.append("battery \(stats.batteryLevel) percent, \(BatteryStatusText.describe(stats))") }
        if stats.isStale { values.append("stats need a refresh") }
        return values.joined(separator: ", ") + "."
    }
}

// MARK: - Island Sparkline
/// A minimal history line for the dark island; fills from the right so new
/// samples always land at the trailing edge.
struct IslandSparkline: View {
    let values: [Double]
    let tint: Color
    let capacity: Int

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(
                    x: .value("Sample", index + capacity - values.count),
                    y: .value("Usage", value)
                )
                .foregroundStyle(
                    LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Sample", index + capacity - values.count),
                    y: .value("Usage", value)
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...max(capacity - 1, 1))
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}
