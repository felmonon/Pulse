import SwiftUI
import ServiceManagement
import WidgetKit
#if os(macOS)
import AppKit
#endif

@main
struct MacMonitorApp: App {
    @StateObject private var statsController: PulseStatsController
    @StateObject private var islandController: DynamicIslandController

    init() {
        let stats = PulseStatsController()
        _statsController = StateObject(wrappedValue: stats)
        _islandController = StateObject(wrappedValue: DynamicIslandController(statsController: stats))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(statsController)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 520, height: 620)

        Window("Settings", id: PulseSettings.settingsWindowID) {
            PulseSettingsView()
                .environmentObject(statsController)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 520, height: 560)
        .windowResizability(.contentSize)

        MenuBarExtra {
            PulseMenuBarMenu(statsController: statsController)
        } label: {
            PulseMenuBarLabel(statsController: statsController)
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - App Settings
enum PulseSettings {
    static let settingsWindowID = "pulse-settings"
    static let defaults = PulseSharedSettings.defaults
    static let defaultRefreshInterval = PulseSharedSettings.defaultRefreshInterval
    static let refreshIntervals = PulseSharedSettings.refreshIntervals
    typealias Keys = PulseSharedSettings.Keys
    typealias UnitsMode = PulseSharedSettings.UnitsMode

    static var storedRefreshInterval: TimeInterval { PulseSharedSettings.storedRefreshInterval }
    static func clampedRefreshInterval(_ value: TimeInterval) -> TimeInterval { PulseSharedSettings.clampedRefreshInterval(value) }
    static func intervalLabel(_ interval: TimeInterval) -> String { PulseSharedSettings.intervalLabel(interval) }
    static func percent(_ value: Double) -> String { PulseSharedSettings.percent(value) }
    static func formatSpeed(_ speed: Double, unitsMode: UnitsMode) -> String { PulseSharedSettings.formatSpeed(speed, unitsMode: unitsMode) }
}

// MARK: - Launch at Login
enum LaunchAtLoginService {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isOnOrPendingApproval: Bool {
        switch status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    static var isAvailable: Bool {
        status != .notFound
    }

    static var statusText: String {
        switch status {
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Requires approval in System Settings"
        case .notRegistered:
            return "Off"
        case .notFound:
            return "Unavailable for this build"
        @unknown default:
            return "Unknown"
        }
    }

    static func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            switch status {
            case .enabled, .requiresApproval:
                return
            case .notRegistered, .notFound:
                try SMAppService.mainApp.register()
            @unknown default:
                try SMAppService.mainApp.register()
            }
        } else {
            switch status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
            case .notRegistered, .notFound:
                return
            @unknown default:
                try SMAppService.mainApp.unregister()
            }
        }
    }
}

// MARK: - Shared App Stats
@MainActor
final class PulseStatsController: ObservableObject {
    @Published private(set) var stats: SystemStats

    private var timer: Timer?
    private var refreshInterval: TimeInterval = PulseSettings.storedRefreshInterval
    private var lastWidgetTimelineReload = Date.distantPast
    private let widgetTimelineReloadInterval: TimeInterval = 15

    init() {
        stats = .placeholder
        configureTimer(interval: refreshInterval)
        refresh(reloadWidgets: true)
    }

    deinit {
        timer?.invalidate()
    }

    func refresh(reloadWidgets: Bool = false) {
        stats = SystemMonitor.shared.getStats()
        reloadWidgetTimelineIfNeeded(force: reloadWidgets)
    }

    func updateRefreshInterval(_ newInterval: TimeInterval) {
        let clampedInterval = PulseSettings.clampedRefreshInterval(newInterval)
        guard clampedInterval != refreshInterval else {
            return
        }

        refreshInterval = clampedInterval
        configureTimer(interval: clampedInterval)
    }

    private func configureTimer(interval: TimeInterval) {
        timer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer.tolerance = min(max(interval * 0.1, 0.1), 2)
        self.timer = timer
    }

    private func reloadWidgetTimelineIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastWidgetTimelineReload) >= widgetTimelineReloadInterval else {
            return
        }

        lastWidgetTimelineReload = now
        WidgetCenter.shared.reloadTimelines(ofKind: "MacMonitorWidget")
    }
}

extension Notification.Name {
    /// Posted when the Dynamic Island enablement setting changes (from the
    /// Settings window or the menu-bar toggle) so the controller re-evaluates.
    static let pulseIslandSettingChanged = Notification.Name("pulseIslandSettingChanged")
}

// MARK: - Dynamic Island Controller
/// Owns the `DynamicIslandPanel` lifecycle: creates/shows it when the user
/// enables the setting AND a notch is present; tears it down otherwise.
/// Observes screen-layout and active-space changes so the panel stays
/// anchored and hides under fullscreen apps.
@MainActor
final class DynamicIslandController: ObservableObject {
    @Published private(set) var notchPresent: Bool

    private let statsController: PulseStatsController
    private let presentation: DynamicIslandPresentation
    private var panel: DynamicIslandPanel?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private var settingObserver: NSObjectProtocol?

    private var isExpanded: Bool {
        presentation.isExpanded
    }

    init(statsController: PulseStatsController) {
        self.statsController = statsController
        self.presentation = DynamicIslandPresentation(notchHeight: DynamicIslandPanel.notchHeight)
        self.notchPresent = DynamicIslandPanel.notchIsPresent
        observeScreenChanges()
        observeActiveSpace()
        observeAppActivation()
        observeSettingChanges()
        applyVisibility()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        if let settingObserver { NotificationCenter.default.removeObserver(settingObserver) }
    }

    /// Re-evaluate notch + setting, then show or hide.
    func applyVisibility() {
        presentation.notchHeight = DynamicIslandPanel.notchHeight
        notchPresent = DynamicIslandPanel.notchIsPresent
        let enabled = PulseSharedSettings.defaults.bool(forKey: PulseSharedSettings.Keys.islandEnabled)

        if enabled && notchPresent {
            ensurePanelShown()
            refreshFullscreenHiding()
        } else {
            teardownPanel()
        }
    }

    private func ensurePanelShown() {
        if panel == nil {
            let rootView = DynamicIslandView(
                statsController: statsController,
                presentation: presentation,
                onToggle: { [weak self] in
                    guard let self else { return }
                    self.setExpanded(!self.isExpanded)
                }
            )
            let newPanel = DynamicIslandPanel(rootView: rootView)
            newPanel.onCollapse = { [weak self] in self?.setExpanded(false) }
            panel = newPanel
        }
        panel?.show(expanded: isExpanded)
    }

    /// Single mutation point for the published expand state. Animates the panel
    /// window frame to match.
    private func setExpanded(_ value: Bool) {
        guard isExpanded != value else { return }
        presentation.isExpanded = value
        panel?.setExpanded(value)
    }

    private func teardownPanel() {
        panel?.hide()
        panel = nil
        setExpanded(false)
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyVisibility() }
        }
    }

    private func observeActiveSpace() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFullscreenHiding() }
        }
    }

    private func observeAppActivation() {
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFullscreenHiding() }
        }
    }

    /// Re-evaluate when the user toggles the island from Settings or the menu.
    private func observeSettingChanges() {
        settingObserver = NotificationCenter.default.addObserver(
            forName: .pulseIslandSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyVisibility() }
        }
    }

    /// Hide the island when a fullscreen app covers the menu-bar screen;
    /// show it again otherwise. No-op unless enabled + a notch exists.
    private func refreshFullscreenHiding() {
        let enabled = PulseSharedSettings.defaults.bool(forKey: PulseSharedSettings.Keys.islandEnabled)
        guard enabled, notchPresent, panel != nil else { return }

        if DynamicIslandPanel.frontmostAppIsFullscreen() {
            setExpanded(false)
            panel?.hide()
        } else {
            panel?.show(expanded: isExpanded)
        }
    }
}

// MARK: - Menu Bar
struct PulseMenuBarLabel: View {
    @ObservedObject var statsController: PulseStatsController
    @AppStorage(PulseSettings.Keys.showDisk, store: PulseSettings.defaults) private var showDisk = true

    private var stats: SystemStats {
        statsController.stats
    }

    private var pressure: PressureSummary {
        PressureSummary.highest(for: stats, includesDisk: showDisk)
    }

    var body: some View {
        Label {
            Text("\(pressure.label) \(pressure.percentText)")
        } icon: {
            Image(systemName: "waveform.path.ecg")
        }
        .accessibilityLabel(Text("Pulse, \(pressure.label) \(pressure.percentText), \(pressure.severity.accessibilityDescription)"))
    }
}

struct PulseMenuBarMenu: View {
    @ObservedObject var statsController: PulseStatsController
    @AppStorage(PulseSettings.Keys.unitsMode, store: PulseSettings.defaults) private var unitsModeRaw = PulseSettings.UnitsMode.automatic.rawValue
    @AppStorage(PulseSettings.Keys.showBattery, store: PulseSettings.defaults) private var showBattery = true
    @AppStorage(PulseSettings.Keys.showDisk, store: PulseSettings.defaults) private var showDisk = true
    @AppStorage(PulseSettings.Keys.showNetwork, store: PulseSettings.defaults) private var showNetwork = true
    @AppStorage(PulseSettings.Keys.showActiveApps, store: PulseSettings.defaults) private var showActiveApps = true
    @AppStorage(PulseSettings.Keys.islandEnabled, store: PulseSettings.defaults) private var islandEnabled = false

    private var stats: SystemStats {
        statsController.stats
    }

    private var unitsMode: PulseSettings.UnitsMode {
        PulseSettings.UnitsMode(rawValue: unitsModeRaw) ?? .automatic
    }

    var body: some View {
        Text("CPU \(PulseSettings.percent(stats.cpuUsage))   RAM \(PulseSettings.percent(stats.memoryUsage))")
            .font(.headline)

        if showBattery {
            Text(batterySummary)
        }

        if showDisk {
            Text(String(format: "Disk %.0f GB free", stats.diskAvailable))
        }

        if showNetwork {
            Text("Network \(networkSummary)")
        }

        if showActiveApps, !stats.activeApps.isEmpty {
            Text("Active \(stats.activeApps.prefix(4).joined(separator: ", "))")
        }

        Divider()

        Toggle("Dynamic Island", isOn: $islandEnabled)
            .onChange(of: islandEnabled) { _, _ in
                NotificationCenter.default.post(name: .pulseIslandSettingChanged, object: nil)
            }

        Button {
            statsController.refresh(reloadWidgets: true)
        } label: {
            Label("Refresh Stats", systemImage: "arrow.clockwise")
        }

        OpenSettingsMenuItem()

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit Pulse", systemImage: "power")
        }
    }

    private var batterySummary: String {
        guard stats.hasBattery else {
            return "Battery AC"
        }

        let state = stats.isCharging ? "charging" : "remaining"
        return "Battery \(stats.batteryLevel)% \(state)"
    }

    private var networkSummary: String {
        let up = PulseSettings.formatSpeed(stats.networkUp, unitsMode: unitsMode)
        let down = PulseSettings.formatSpeed(stats.networkDown, unitsMode: unitsMode)
        return "Up \(up) Down \(down)"
    }
}

struct OpenSettingsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: PulseSettings.settingsWindowID)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } label: {
            Label("Open Settings", systemImage: "gearshape")
        }
    }
}

// MARK: - Settings Window
struct PulseSettingsView: View {
    @EnvironmentObject private var statsController: PulseStatsController

    @AppStorage(PulseSettings.Keys.launchAtLogin, store: PulseSettings.defaults) private var launchAtLoginPreference = false
    @AppStorage(PulseSettings.Keys.refreshInterval, store: PulseSettings.defaults) private var refreshInterval = PulseSettings.defaultRefreshInterval
    @AppStorage(PulseSettings.Keys.unitsMode, store: PulseSettings.defaults) private var unitsModeRaw = PulseSettings.UnitsMode.automatic.rawValue
    @AppStorage(PulseSettings.Keys.showBattery, store: PulseSettings.defaults) private var showBattery = true
    @AppStorage(PulseSettings.Keys.showDisk, store: PulseSettings.defaults) private var showDisk = true
    @AppStorage(PulseSettings.Keys.showNetwork, store: PulseSettings.defaults) private var showNetwork = true
    @AppStorage(PulseSettings.Keys.showActiveApps, store: PulseSettings.defaults) private var showActiveApps = true
    @AppStorage(PulseSettings.Keys.islandEnabled, store: PulseSettings.defaults) private var islandEnabled = false

    @State private var launchAtLoginEnabled = LaunchAtLoginService.isOnOrPendingApproval
    @State private var launchAtLoginStatusText = LaunchAtLoginService.statusText
    @State private var launchAtLoginError: String?

    private var metricColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 18),
            GridItem(.flexible(), spacing: 18)
        ]
    }

    var body: some View {
        ZStack {
            PulseWindowBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    settingsSection {
                        SettingsSectionLabel(title: "Startup", systemImage: "power")
                    } content: {
                        settingsToggleRow(
                            "Launch at Login",
                            detail: launchAtLoginError ?? launchAtLoginStatusText,
                            systemImage: "arrow.clockwise.circle",
                            isOn: launchAtLoginBinding,
                            isEnabled: LaunchAtLoginService.isAvailable,
                            detailColor: launchAtLoginError == nil ? .secondary : AppColors.critical
                        )
                    }

                    Divider()

                    settingsSection {
                        SettingsSectionLabel(title: "Notch Monitor", systemImage: "macbook")
                    } content: {
                        settingsToggleRow(
                            "Show at the notch",
                            detail: islandStatusText,
                            systemImage: "rectangle.topthird.inset.filled",
                            isOn: $islandEnabled,
                            isEnabled: DynamicIslandPanel.notchIsPresent
                        )
                    }

                    Divider()

                    settingsSection {
                        SettingsSectionLabel(title: "Display", systemImage: "slider.horizontal.3")
                    } content: {
                        VStack(alignment: .leading, spacing: 12) {
                            settingsControlRow("Refresh Interval") {
                                Picker("Refresh Interval", selection: $refreshInterval) {
                                    ForEach(PulseSettings.refreshIntervals, id: \.self) { interval in
                                        Text(PulseSettings.intervalLabel(interval)).tag(interval)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 120)
                            }

                            settingsControlRow("Units") {
                                Picker("Units", selection: $unitsModeRaw) {
                                    ForEach(PulseSettings.UnitsMode.allCases) { mode in
                                        Text(mode.title).tag(mode.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 180)
                            }
                        }
                    }

                    Divider()

                    settingsSection {
                        SettingsSectionLabel(title: "Visible Metrics", systemImage: "menubar.rectangle")
                    } content: {
                        LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 10) {
                            metricToggle("Battery", systemImage: "battery.100", isOn: $showBattery)
                            metricToggle("Storage", systemImage: "internaldrive", isOn: $showDisk)
                            metricToggle("Network", systemImage: "network", isOn: $showNetwork)
                            metricToggle("Active Apps", systemImage: "macwindow.on.rectangle", isOn: $showActiveApps)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(28)
                .frame(maxWidth: 520, alignment: .topLeading)
            }
        }
        .scrollIndicators(.hidden)
        .frame(
            minWidth: 480,
            idealWidth: 520,
            maxWidth: 620,
            minHeight: 600,
            idealHeight: 620,
            maxHeight: 720
        )
        .onAppear {
            syncLaunchAtLoginState()
            statsController.updateRefreshInterval(refreshInterval)
        }
        .onChange(of: refreshInterval) { _, newValue in
            let clampedInterval = PulseSettings.clampedRefreshInterval(newValue)
            if clampedInterval != newValue {
                refreshInterval = clampedInterval
            }
            statsController.updateRefreshInterval(clampedInterval)
        }
        .onChange(of: unitsModeRaw) { _, _ in reloadWidgetsForSettingsChange() }
        .onChange(of: showBattery) { _, _ in reloadWidgetsForSettingsChange() }
        .onChange(of: showDisk) { _, _ in reloadWidgetsForSettingsChange() }
        .onChange(of: showNetwork) { _, _ in reloadWidgetsForSettingsChange() }
        .onChange(of: showActiveApps) { _, _ in reloadWidgetsForSettingsChange() }
        .onChange(of: islandEnabled) { _, _ in
            // The island controller observes this notification and re-evaluates
            // visibility against the (now-updated) setting + notch presence.
            NotificationCenter.default.post(name: .pulseIslandSettingChanged, object: nil)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppColors.ramBlue.opacity(0.16))
                    .frame(width: 34, height: 34)

                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColors.ramBlue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Pulse Settings")
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)

                Text("Preferences")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    private func settingsSection<Header: View, Content: View>(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsToggleRow(
        _ title: String,
        detail: String,
        systemImage: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        detailColor: Color = .secondary
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isEnabled ? AppColors.ramBlue : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary)

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!isEnabled)
        }
    }

    private func metricToggle(
        _ title: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .frame(minHeight: 24)
    }

    private func settingsControlRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                control()
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                control()
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding {
            launchAtLoginEnabled
        } set: { newValue in
            updateLaunchAtLogin(newValue)
        }
    }

    private var islandStatusText: String {
        DynamicIslandPanel.notchIsPresent ? "Available on this Mac" : "Unavailable on this Mac"
    }

    private func syncLaunchAtLoginState() {
        launchAtLoginEnabled = LaunchAtLoginService.isOnOrPendingApproval
        launchAtLoginPreference = launchAtLoginEnabled
        launchAtLoginStatusText = LaunchAtLoginService.statusText
        launchAtLoginError = nil
    }

    private func updateLaunchAtLogin(_ isEnabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(isEnabled)
            launchAtLoginEnabled = LaunchAtLoginService.isOnOrPendingApproval
            launchAtLoginPreference = launchAtLoginEnabled
            launchAtLoginStatusText = LaunchAtLoginService.statusText
            launchAtLoginError = nil
        } catch {
            launchAtLoginEnabled = LaunchAtLoginService.isOnOrPendingApproval
            launchAtLoginPreference = launchAtLoginEnabled
            launchAtLoginStatusText = LaunchAtLoginService.statusText
            launchAtLoginError = error.localizedDescription
        }
    }

    private func reloadWidgetsForSettingsChange() {
        WidgetCenter.shared.reloadTimelines(ofKind: "MacMonitorWidget")
    }
}

struct SettingsSectionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Stable Window Surface
struct PulseWindowBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @EnvironmentObject private var statsController: PulseStatsController
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PulseSettings.Keys.showDisk, store: PulseSettings.defaults) private var showDisk = true
    @State private var selectedSize: WidgetSize = .medium

    enum WidgetSize: String, CaseIterable {
        case small = "Small"
        case medium = "Medium"
        case large = "Large"
    }

    var body: some View {
        ZStack {
            PulseWindowBackground()
                .ignoresSafeArea()

            VStack(spacing: 18) {
                titleBar

                controlsRow

                Spacer(minLength: 0)

                widgetPreview

                Spacer(minLength: 0)

                bottomBar
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 480, minHeight: 600)
        .onAppear {
            statsController.refresh()
        }
    }

    // MARK: - Title Bar
    private var titleBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppColors.ramBlue.opacity(0.16))
                    .frame(width: 40, height: 40)

                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(AppColors.ramBlue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Pulse")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("System Monitor")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                statsController.refresh(reloadWidgets: true)
            } label: {
                Label("Refresh Stats", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help("Refresh")
            .accessibilityHint(Text("Refreshes the current system metrics and widget timeline."))

            Button {
                openWindow(id: PulseSettings.settingsWindowID)
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help("Settings")
            .accessibilityHint(Text("Opens Pulse settings."))
        }
    }

    // MARK: - Size Picker
    private var controlsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Widget Preview")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                statusStrip
            }

            HStack(spacing: 12) {
                Text("Size")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)

                sizePicker

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sizePicker: some View {
        Picker("Widget Size", selection: $selectedSize) {
            ForEach(WidgetSize.allCases, id: \.self) { size in
                Text(size.rawValue).tag(size)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
        .accessibilityLabel(Text("Widget Size"))
    }

    private var statusStrip: some View {
        let pressure = PressureSummary.highest(for: statsController.stats, includesDisk: showDisk)

        return HStack(spacing: 8) {
            MetricPill(
                title: pressure.label,
                value: pressure.percentText,
                color: AppColors.severityColor(pressure.severity, fallback: pressure.color)
            )
        }
    }

    // MARK: - Widget Preview
    private var widgetPreview: some View {
        sizedWidgetPreview
            .id(selectedSize)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var previewSize: CGSize {
        switch selectedSize {
        case .small:
            return CGSize(width: 170, height: 170)
        case .medium:
            return CGSize(width: 360, height: 170)
        case .large:
            return CGSize(width: 360, height: 380)
        }
    }

    @ViewBuilder
    private var selectedWidgetView: some View {
        switch selectedSize {
        case .small:
            SmallWidgetView(stats: statsController.stats)
        case .medium:
            MediumWidgetView(stats: statsController.stats)
        case .large:
            LargeWidgetView(stats: statsController.stats)
        }
    }

    private var sizedWidgetPreview: some View {
        let size = previewSize

        return selectedWidgetView
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 8)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.75)
            )
            .animation(.easeInOut(duration: 0.18), value: selectedSize)
    }

    private var bottomBar: some View {
        HStack {
            Label("Refresh every \(PulseSettings.intervalLabel(PulseSettings.storedRefreshInterval))", systemImage: "clock")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer()

            if statsController.stats.isStale {
                Label("Stale", systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(AppColors.diskAmber)
            } else {
                Label("Live", systemImage: "circle.fill")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MetricPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)

            Text(title)
                .foregroundStyle(.secondary)

            Text(value)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .regular, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(AppColors.capsuleFill)
        )
    }
}
