import SwiftUI
import ServiceManagement
import WidgetKit
import Combine
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
        Window("Pulse", id: PulseSettings.mainWindowID) {
            DashboardView()
                .environmentObject(statsController)
        }
        .defaultSize(width: 980, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            PulseCommands(statsController: statsController)
        }

        Settings {
            SettingsView()
                .environmentObject(statsController)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(statsController)
        } label: {
            PulseMenuBarLabel(statsController: statsController)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App Settings
enum PulseSettings {
    static let mainWindowID = "pulse-main"
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
    /// Rolling samples behind the live charts in the window, menu bar and notch.
    @Published private(set) var history = MetricHistory()

    private var timer: Timer?
    private(set) var refreshInterval: TimeInterval = PulseSettings.storedRefreshInterval
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
        let sample = SystemMonitor.shared.getStats()
        stats = sample
        history.append(sample)
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
    private var powerSubscription: AnyCancellable?
    private var activityTask: Task<Void, Never>?

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
        observePowerSource()
        // This initializer runs inside SwiftUI's scene update (StateObject
        // creation). Showing the panel synchronously would render its hosting
        // view mid-update and trip AttributeGraph's "setting value during
        // update" precondition, so defer the first presentation one turn.
        DispatchQueue.main.async { [weak self] in
            self?.applyVisibility()
        }
    }

    /// Like the iPhone, briefly show a charging activity in the island when
    /// power is connected.
    private func observePowerSource() {
        powerSubscription = statsController.$stats
            .map(\.isPluggedIn)
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor in self?.showChargingActivity() }
            }
    }

    private func showChargingActivity() {
        let enabled = PulseSharedSettings.defaults.object(forKey: PulseSharedSettings.Keys.islandChargingActivity) as? Bool ?? true
        guard enabled, statsController.stats.hasBattery, panel != nil, !isExpanded else { return }

        activityTask?.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
            presentation.activity = .charging
        }
        activityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                self.presentation.activity = nil
            }
        }
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
        if value {
            activityTask?.cancel()
            presentation.activity = nil
        }
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

// MARK: - Commands
struct PulseCommands: Commands {
    let statsController: PulseStatsController

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Refresh Now") {
                statsController.refresh(reloadWidgets: true)
            }
            .keyboardShortcut("r")

            Divider()
        }
    }
}

// MARK: - Menu Bar Label
struct PulseMenuBarLabel: View {
    @ObservedObject var statsController: PulseStatsController
    @AppStorage(PulseSettings.Keys.showDisk, store: PulseSettings.defaults) private var showDisk = true
    @AppStorage(PulseSettings.Keys.menuBarStyle, store: PulseSettings.defaults) private var menuBarStyleRaw = PulseSharedSettings.MenuBarStyle.busiest.rawValue

    private var stats: SystemStats {
        statsController.stats
    }

    private var pressure: PressureSummary {
        PressureSummary.highest(for: stats, includesDisk: showDisk)
    }

    private var style: PulseSharedSettings.MenuBarStyle {
        PulseSharedSettings.MenuBarStyle(rawValue: menuBarStyleRaw) ?? .busiest
    }

    private var symbol: String {
        pressure.severity >= .high ? "exclamationmark.triangle.fill" : "waveform.path.ecg"
    }

    var body: some View {
        Group {
            switch style {
            case .iconOnly:
                Image(systemName: symbol)
            case .busiest:
                Label {
                    Text("\(pressure.label) \(pressure.percentText)")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: symbol)
                }
            case .cpuAndMemory:
                Label {
                    Text("CPU \(PulseSettings.percent(stats.cpuUsage))  RAM \(PulseSettings.percent(stats.memoryUsage))")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: symbol)
                }
            }
        }
        .accessibilityLabel(Text("Pulse, \(pressure.label) \(pressure.percentText), \(pressure.severity.accessibilityDescription)"))
    }
}

// MARK: - Shared Actions
enum PulseActions {
    static func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openStorageSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.settings.Storage")
    }

    static func openBatterySettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.Battery-Settings.extension")
    }

    private static func openSystemSettings(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}
