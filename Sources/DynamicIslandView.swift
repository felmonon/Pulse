import SwiftUI

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

// MARK: - Island Metrics
/// Layout constants for the island. The island is always black, so its
/// palette is fixed white at a few opacities rather than the adaptive label
/// colors used elsewhere. Numbers are always white; only marks (the ear
/// ring, row bars, status dot) carry severity color.
private enum IslandLayout {
    // Shape
    static let restingTopRadius: CGFloat = 7
    static let restingBottomRadius: CGFloat = 12
    static let expandedTopRadius: CGFloat = 12
    static let expandedBottomRadius: CGFloat = 32

    // Resting ears
    static let earInset: CGFloat = 8
    /// Gap kept between ear content and the cutout. The cutout is black like
    /// the island, so this edge is invisible; the outer inset is the one
    /// the eye measures.
    static let earClearance: CGFloat = 1
    static let earSpacing: CGFloat = 5
    /// Sized so the longest name ("Memory", ~44pt at 11pt) still fits
    /// beside it in the 64pt ear: 15 + 5 + 44.
    static let ringSide: CGFloat = 15
    static let ringStroke: CGFloat = 2.5
    static let earLabelSize: CGFloat = 11
    static let earValueSize: CGFloat = 12

    /// Width each resting ear offers its content: the ear beside the
    /// cutout, minus the outer shoulder and inset and the notch clearance.
    static var earContentWidth: CGFloat {
        DynamicIslandMath.compactEarWidth - restingTopRadius - earInset - earClearance
    }

    // Expanded
    static let sideInset: CGFloat = 24
    static let bottomInset: CGFloat = 24
    static let rowSpacing: CGFloat = 14
    static let rowHeight: CGFloat = 18
    static let labelColumn: CGFloat = 58
    static let valueColumn: CGFloat = 40
    /// The status line sits just below the notch band, under "Pulse".
    static let statusGap: CGFloat = 1
    static let statusSize: CGFloat = 11
    static let statusDot: CGFloat = 6

    // Ink
    static let primaryInk = Color.white
    static let labelInk = Color.white.opacity(0.6)
    static let quietInk = Color.white.opacity(0.55)
    static let earLabelInk = Color.white.opacity(0.5)
    static let activityLabelInk = Color.white.opacity(0.6)
    /// Ring and bar tracks: the shared 10% track nearly vanishes on pure black.
    static let track = Color.white.opacity(0.16)

    // Motion
    static let expand = Animation.timingCurve(0.2, 0.9, 0.2, 1.0, duration: 0.42)
    static let collapse = Animation.timingCurve(0.2, 0.9, 0.2, 1.0, duration: 0.34)
    /// With Reduce Motion: a short fade, no morph.
    static let reduced = Animation.easeOut(duration: 0.15)
}

// MARK: - Dynamic Island View
/// At rest the island is notch-height, with live content in the two ears
/// beside the cutout. Click to grow it downward into a quiet summary.
///
/// The controller is observed (not snapshotted) so the island updates live as
/// stats refresh.
struct DynamicIslandView: View {
    @ObservedObject var statsController: PulseStatsController
    @ObservedObject var presentation: DynamicIslandPresentation
    let onToggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(PulseSharedSettings.Keys.showBattery, store: PulseSharedSettings.defaults) private var showBattery = true
    @AppStorage(PulseSharedSettings.Keys.showDisk, store: PulseSharedSettings.defaults) private var showDisk = true
    @AppStorage(PulseSharedSettings.Keys.showNetwork, store: PulseSharedSettings.defaults) private var showNetwork = true
    @AppStorage(PulseSharedSettings.Keys.unitsMode, store: PulseSharedSettings.defaults) private var unitsModeRaw = PulseSharedSettings.UnitsMode.automatic.rawValue

    private var stats: SystemStats { statsController.stats }
    private var isExpanded: Bool { presentation.isExpanded }
    private var notchHeight: CGFloat { max(presentation.notchHeight, 1) }
    private var kinds: [MetricKind] { MetricKind.visible(includesDisk: showDisk) }

    private var unitsMode: PulseSharedSettings.UnitsMode {
        PulseSharedSettings.UnitsMode(rawValue: unitsModeRaw) ?? .automatic
    }

    private var status: PulseStatus {
        PulseStatus(stats: stats, includesDisk: showDisk)
    }

    /// The metric the resting island speaks for: CPU, or Memory when memory
    /// pressure is the more severe of the two. Storage never takes over the
    /// ears; a slowly filling disk speaks through the expanded status line.
    private var featured: PressureSummary {
        PressureSummary.ambient(for: stats)
    }

    /// What the resting ears show. The charging activity only holds while
    /// the Mac is actually on power, and says "Charged" (no bolt) once the
    /// battery is full or the adapter is holding the charge.
    private var earMode: EarMode {
        guard presentation.activity == .charging, stats.hasBattery,
              stats.isCharging || stats.isPluggedIn else { return .metric }
        return stats.isCharging && stats.batteryLevel < 100 ? .charging : .charged
    }

    private var shape: IslandShape {
        IslandShape(
            topCornerRadius: isExpanded ? IslandLayout.expandedTopRadius : IslandLayout.restingTopRadius,
            bottomCornerRadius: isExpanded ? IslandLayout.expandedBottomRadius : IslandLayout.restingBottomRadius
        )
    }

    private var morph: Animation {
        if reduceMotion { return IslandLayout.reduced }
        return isExpanded ? IslandLayout.expand : IslandLayout.collapse
    }

    /// Content fades in once the shape has mostly settled; with Reduce
    /// Motion it simply fades, without waiting.
    private var contentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(reduceMotion ? IslandLayout.reduced : .easeOut(duration: 0.22).delay(0.12)),
            removal: .opacity.animation(.easeOut(duration: 0.1))
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(Color.black)

            if isExpanded {
                expandedContent
                    .transition(contentTransition)
            } else {
                compactContent
                    .transition(contentTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(shape)
        .onTapGesture(perform: onToggle)
        .animation(morph, value: isExpanded)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Click to \(isExpanded ? "collapse" : "expand")."))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
    }

    // MARK: Resting

    private var compactContent: some View {
        HStack(spacing: 0) {
            leadingEar
                .frame(width: IslandLayout.earContentWidth, alignment: .leading)
            Spacer(minLength: 0)
            trailingEar
                .frame(width: IslandLayout.earContentWidth, alignment: .trailing)
        }
        .id(earMode)
        .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
        .padding(.horizontal, IslandLayout.restingTopRadius + IslandLayout.earInset)
        .frame(height: notchHeight)
    }

    /// Ring and name, always both: the ring reads as part of the hardware,
    /// the word says which metric it is.
    @ViewBuilder
    private var leadingEar: some View {
        switch earMode {
        case .charging, .charged:
            Text(earMode == .charging ? "Charging" : "Charged")
                .font(.system(size: IslandLayout.earLabelSize, weight: .medium))
                .foregroundStyle(IslandLayout.activityLabelInk)
                .lineLimit(1)
                .fixedSize()
        case .metric:
            HStack(spacing: IslandLayout.earSpacing) {
                EarRing(
                    value: featured.progress,
                    tint: PulseStyle.markTint(for: featured.kind.markSeverity(in: stats))
                )
                .frame(width: IslandLayout.ringSide, height: IslandLayout.ringSide)

                Text(featured.kind.compactTitle)
                    .font(.system(size: IslandLayout.earLabelSize, weight: .medium))
                    .foregroundStyle(IslandLayout.earLabelInk)
                    .lineLimit(1)
            }
            .fixedSize()
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: featured.kind)
        }
    }

    @ViewBuilder
    private var trailingEar: some View {
        switch earMode {
        case .charging:
            // A bolt, never a battery glyph: a full battery beside "14%"
            // would contradict the number. Small enough to always fit.
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                batteryLevel
            }
            .fixedSize()
            .foregroundStyle(PulseStyle.batteryMarkTint(stats))
        case .charged:
            batteryLevel
                .foregroundStyle(PulseStyle.batteryMarkTint(stats))
        case .metric:
            Text(featured.percentText)
                .font(.system(size: IslandLayout.earValueSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(IslandLayout.primaryInk)
                .lineLimit(1)
                .contentTransition(reduceMotion ? .identity : .numericText(value: featured.progress))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: featured.percentText)
        }
    }

    private var batteryLevel: some View {
        Text("\(stats.batteryLevel)%")
            .font(.system(size: IslandLayout.earValueSize, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: Expanded

    /// "Pulse" in the leading ear, beside the cutout; the status on its own
    /// line just below the notch band, left-aligned under the title, like
    /// the menu's header. The trailing ear stays empty and quiet.
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pulse")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandLayout.primaryInk)
                .lineLimit(1)
                .frame(height: notchHeight)

            StatusPhrase(text: status.shortHeadline, dot: status.attentionTint)
                .padding(.top, IslandLayout.statusGap)

            // Equal spacers center the rows between the status line and
            // the footer whether two or three are shown.
            Spacer(minLength: 12)

            VStack(spacing: IslandLayout.rowSpacing) {
                ForEach(kinds) { kind in
                    metricRow(kind)
                }
            }

            Spacer(minLength: 12)

            if showNetwork || showsBatteryFooter {
                footer
            }
        }
        .padding(.horizontal, IslandLayout.expandedTopRadius + IslandLayout.sideInset)
        .padding(.bottom, IslandLayout.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func metricRow(_ kind: MetricKind) -> some View {
        let value = kind.value(in: stats)
        return HStack(spacing: 14) {
            Text(kind.title)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(IslandLayout.labelInk)
                .frame(width: IslandLayout.labelColumn, alignment: .leading)

            UsageBar(
                value: value,
                tint: PulseStyle.markTint(for: kind.markSeverity(in: stats)),
                height: 4,
                track: IslandLayout.track
            )

            Text(PulseFormat.percentText(value))
                .font(.system(size: 12, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(IslandLayout.primaryInk)
                .contentTransition(reduceMotion ? .identity : .numericText(value: value))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: value)
                .frame(width: IslandLayout.valueColumn, alignment: .trailing)
        }
        .frame(height: IslandLayout.rowHeight)
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerLine(showsBatteryGlyph: true)
            footerLine(showsBatteryGlyph: false)
        }
    }

    private func footerLine(showsBatteryGlyph: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if showNetwork {
                rate(symbol: "arrow.down", bytesPerSecond: stats.networkDown)
                rate(symbol: "arrow.up", bytesPerSecond: stats.networkUp)
                    .padding(.leading, 14)
            }
            Spacer(minLength: 12)
            if showsBatteryFooter {
                battery(showsGlyph: showsBatteryGlyph)
            }
        }
        .font(.system(size: 11, weight: .regular))
        .lineLimit(1)
    }

    /// An arrow and a speed: the number white, arrow and unit quiet.
    private func rate(symbol: String, bytesPerSecond: Double) -> some View {
        let parts = PulseFormat.speed(bytesPerSecond, unitsMode: unitsMode)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(IslandLayout.quietInk)
            (Text(parts.number)
                .foregroundStyle(IslandLayout.primaryInk)
            + Text(parts.unit.isEmpty ? "" : " " + parts.unit)
                .foregroundStyle(IslandLayout.quietInk))
                .monospacedDigit()
        }
        .fixedSize()
    }

    /// Macs without a battery have nothing to report here.
    private var showsBatteryFooter: Bool {
        showBattery && stats.hasBattery
    }

    /// Battery-menu phrasing in quiet ink ("3:23 remaining"), then the level
    /// in white on the rows' value column.
    private func battery(showsGlyph: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if showsGlyph {
                Image(systemName: batterySymbol)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(batteryGlyphTint)
                    .padding(.trailing, 5)
            }
            Text(BatteryStatusText.describe(stats))
                .foregroundStyle(IslandLayout.quietInk)
                .monospacedDigit()
            Text("\(stats.batteryLevel)%")
                .foregroundStyle(IslandLayout.primaryInk)
                .monospacedDigit()
                .frame(minWidth: IslandLayout.valueColumn, alignment: .trailing)
        }
        .fixedSize()
    }

    /// A level-matched battery normally; a bolt while charging, since the
    /// only bolt symbol is a full battery and would contradict a low level.
    private var batterySymbol: String {
        stats.isCharging ? "bolt.fill" : BatteryStatusText.symbol(stats)
    }

    /// The battery glyph is a mark with Apple's battery semantics, shown in
    /// color only when something is off (red when low and discharging,
    /// yellow in Low Power Mode); quiet otherwise, since green belongs to
    /// the charging activity.
    private var batteryGlyphTint: Color {
        let needsAttention = ProcessInfo.processInfo.isLowPowerModeEnabled
            || BatteryStatusText.severity(stats) >= .high
        guard stats.hasBattery, !stats.isCharging, needsAttention else {
            return IslandLayout.quietInk
        }
        return PulseStyle.batteryMarkTint(stats)
    }

    // MARK: Accessibility

    private var accessibilityLabel: String {
        if isExpanded {
            return "Pulse island expanded. \(expandedContentSummary)"
        }
        switch earMode {
        case .charging:
            return "Pulse island. Charging, \(stats.batteryLevel) percent."
        case .charged:
            return "Pulse island. Charged, \(stats.batteryLevel) percent."
        case .metric:
            return "Pulse island. \(featured.kind.title) \(featured.percentText), \(featured.kind.spokenSeverity(featured.severity))."
        }
    }

    private var expandedContentSummary: String {
        let status = self.status
        var values = [String(status.headline.dropLast())]
        if let detail = status.detail { values.append(String(detail.dropLast())) }
        values += kinds.map { "\($0.title) \(PulseFormat.percentText($0.value(in: stats)))" }
        if showNetwork {
            values.append("download \(PulseSharedSettings.formatSpeed(stats.networkDown, unitsMode: unitsMode)), upload \(PulseSharedSettings.formatSpeed(stats.networkUp, unitsMode: unitsMode))")
        }
        if showBattery, stats.hasBattery {
            values.append("battery \(stats.batteryLevel) percent, \(BatteryStatusText.describe(stats))")
        }
        if stats.isStale { values.append("stats need a refresh") }
        return values.joined(separator: ". ") + "."
    }
}

// MARK: - Ear Mode
/// The resting ears' content: the featured metric, or the charging activity.
private enum EarMode: Hashable {
    case metric
    case charging
    case charged
}

// MARK: - Status Phrase
/// The expanded island's status, one line: a 6pt dot in the worst
/// condition's mark color when something needs attention, then the phrase
/// in quiet ink. The words are never tinted and never a repeated value.
private struct StatusPhrase: View {
    let text: String
    let dot: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: IslandLayout.statusDot, height: IslandLayout.statusDot)
                    // Center the dot on the capitals, not the baseline.
                    .alignmentGuide(.firstTextBaseline) {
                        $0[VerticalAlignment.center] + IslandLayout.statusSize * 0.35
                    }
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: IslandLayout.statusSize, weight: .regular))
        .foregroundStyle(IslandLayout.quietInk)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Ear Ring
/// The resting island's single thin ring: an arc in the metric's mark color
/// (accent, or orange/red when high) on a faint white track, small enough to
/// sit in the menu bar beside the notch.
private struct EarRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let value: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(IslandLayout.track, lineWidth: IslandLayout.ringStroke)
            Circle()
                .trim(from: 0, to: SystemStatsMath.unitInterval(value))
                .stroke(tint, style: StrokeStyle(lineWidth: IslandLayout.ringStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(IslandLayout.ringStroke / 2)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: value)
        .accessibilityHidden(true)
    }
}
