import SwiftUI
import ServiceManagement
import WidgetKit

// MARK: - Settings
/// The standard macOS Settings window: toolbar tabs over grouped forms, the
/// same structure as System Settings panes.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }

            NotchSettingsPane()
                .tabItem { Label("Notch", systemImage: "macbook") }

            DisplaySettingsPane()
                .tabItem { Label("Widgets", systemImage: "square.grid.2x2") }
        }
        .frame(width: 500)
    }
}

// MARK: - General
private struct GeneralSettingsPane: View {
    @EnvironmentObject private var statsController: PulseStatsController

    @AppStorage(PulseSettings.Keys.launchAtLogin, store: PulseSettings.defaults) private var launchAtLoginPreference = false
    @AppStorage(PulseSettings.Keys.refreshInterval, store: PulseSettings.defaults) private var refreshInterval = PulseSettings.defaultRefreshInterval
    @AppStorage(PulseSettings.Keys.menuBarStyle, store: PulseSettings.defaults) private var menuBarStyleRaw = PulseSharedSettings.MenuBarStyle.busiest.rawValue

    @State private var launchAtLoginEnabled = LaunchAtLoginService.isOnOrPendingApproval
    @State private var launchAtLoginStatus = LaunchAtLoginService.status
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: launchAtLoginBinding)
                    .disabled(!LaunchAtLoginService.isAvailable)

                if launchAtLoginStatus == .requiresApproval {
                    HStack {
                        Text("Allow Pulse in Login Items to finish turning this on.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
            } footer: {
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .foregroundStyle(PulsePalette.critical)
                } else {
                    Text("Keeps the menu bar item, notch island and widgets up to date after you restart.")
                }
            }

            Section {
                Picker("Update stats", selection: $refreshInterval) {
                    ForEach(PulseSettings.refreshIntervals, id: \.self) { interval in
                        Text(PulseSharedSettings.intervalDescription(interval)).tag(interval)
                    }
                }

                Picker("Show in menu bar", selection: $menuBarStyleRaw) {
                    ForEach(PulseSharedSettings.MenuBarStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
            } footer: {
                Text("Faster updates are smoother but use slightly more energy.")
            }

            Section {
                LabeledContent("Version", value: appVersion)
            }
        }
        .formStyle(.grouped)
        .frame(height: 318)
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
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding {
            launchAtLoginEnabled
        } set: { newValue in
            updateLaunchAtLogin(newValue)
        }
    }

    private func syncLaunchAtLoginState() {
        launchAtLoginEnabled = LaunchAtLoginService.isOnOrPendingApproval
        launchAtLoginPreference = launchAtLoginEnabled
        launchAtLoginStatus = LaunchAtLoginService.status
        launchAtLoginError = nil
    }

    private func updateLaunchAtLogin(_ isEnabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(isEnabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLoginEnabled = LaunchAtLoginService.isOnOrPendingApproval
        launchAtLoginPreference = launchAtLoginEnabled
        launchAtLoginStatus = LaunchAtLoginService.status
    }
}

// MARK: - Notch
private struct NotchSettingsPane: View {
    @AppStorage(PulseSettings.Keys.islandEnabled, store: PulseSettings.defaults) private var islandEnabled = false
    @AppStorage(PulseSettings.Keys.islandChargingActivity, store: PulseSettings.defaults) private var chargingActivity = true

    private let notchPresent = DynamicIslandPanel.notchIsPresent

    var body: some View {
        Form {
            Section {
                NotchPreview(isEnabled: islandEnabled && notchPresent)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
            }

            Section {
                Toggle("Show Pulse around the notch", isOn: $islandEnabled)
                    .disabled(!notchPresent)
                Toggle("Show charging activity", isOn: $chargingActivity)
                    .disabled(!notchPresent || !islandEnabled)
            } footer: {
                Text(notchPresent
                     ? "Click the island to see details. It hides automatically when an app is full screen."
                     : "This Mac's built-in display doesn't have a notch.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 352)
        .onChange(of: islandEnabled) { _, _ in
            // The island controller observes this notification and re-evaluates
            // visibility against the (now-updated) setting + notch presence.
            NotificationCenter.default.post(name: .pulseIslandSettingChanged, object: nil)
        }
    }
}

/// A small illustration of the island at rest, drawn with the real shape and
/// components so it always matches what appears on screen.
private struct NotchPreview: View {
    let isEnabled: Bool

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.32, green: 0.38, blue: 0.62), Color(red: 0.62, green: 0.46, blue: 0.70)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(spacing: 0) {
                Group {
                    if isEnabled {
                        ConcentricRings(stats: .placeholder, kinds: MetricKind.allCases, lineWidth: 2.6, gap: 0.8)
                            .frame(width: 16, height: 16)
                    }
                }
                .frame(width: 46)

                Spacer(minLength: 0)

                Group {
                    if isEnabled {
                        Text("62%")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(PulsePalette.memory)
                    }
                }
                .frame(width: 46)
            }
            .frame(width: isEnabled ? 92 + 110 : 110, height: 26)
            .background(
                IslandShape(topCornerRadius: 5, bottomCornerRadius: 9)
                    .fill(Color.black)
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isEnabled)
        }
        .frame(width: 360, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Widgets & Display
private struct DisplaySettingsPane: View {
    @AppStorage(PulseSettings.Keys.unitsMode, store: PulseSettings.defaults) private var unitsModeRaw = PulseSettings.UnitsMode.automatic.rawValue
    @AppStorage(PulseSettings.Keys.showBattery, store: PulseSettings.defaults) private var showBattery = true
    @AppStorage(PulseSettings.Keys.showDisk, store: PulseSettings.defaults) private var showDisk = true
    @AppStorage(PulseSettings.Keys.showNetwork, store: PulseSettings.defaults) private var showNetwork = true
    @AppStorage(PulseSettings.Keys.showActiveApps, store: PulseSettings.defaults) private var showActiveApps = true

    var body: some View {
        Form {
            Section {
                metricToggle("Battery", systemImage: "battery.75percent", tint: .green, isOn: $showBattery)
                metricToggle("Storage", systemImage: "internaldrive", tint: PulsePalette.disk, isOn: $showDisk)
                metricToggle("Network", systemImage: "network", tint: PulsePalette.networkDown, isOn: $showNetwork)
                metricToggle("Running Apps", systemImage: "macwindow.on.rectangle", tint: .gray, isOn: $showActiveApps)
            } header: {
                Text("Show")
            } footer: {
                Text("Applies to widgets, the menu bar, the notch island and the Pulse window. CPU and memory are always shown.")
            }

            Section {
                Picker("Network speed", selection: $unitsModeRaw) {
                    ForEach(PulseSettings.UnitsMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(height: 392)
        .onChange(of: unitsModeRaw) { _, _ in reloadWidgets() }
        .onChange(of: showBattery) { _, _ in reloadWidgets() }
        .onChange(of: showDisk) { _, _ in reloadWidgets() }
        .onChange(of: showNetwork) { _, _ in reloadWidgets() }
        .onChange(of: showActiveApps) { _, _ in reloadWidgets() }
    }

    /// System Settings–style row: a white glyph on a colored rounded square.
    private func metricToggle(_ title: String, systemImage: String, tint: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
            }
        }
    }

    private func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: "MacMonitorWidget")
    }
}
