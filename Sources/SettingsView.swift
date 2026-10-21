import SwiftUI
import ServiceManagement
import WidgetKit

// MARK: - Settings
/// The standard macOS Settings window: toolbar tabs over grouped forms, the
/// same structure as System Settings panes. Nothing here is decorated; the
/// only picture is the Notch Island preview, drawn with the island's real
/// shape and contents.
struct SettingsView: View {
    /// Remembers the last tab, like Safari and Mail do. A tab that no longer
    /// exists falls back to General.
    @AppStorage("settings.selectedTab") private var selection = SettingsTab.general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            NotchIslandSettingsPane()
                .tabItem { Label("Notch Island", systemImage: "macbook") }
                .tag(SettingsTab.notch)
        }
        .frame(width: 500)
    }
}

private enum SettingsTab: String {
    case general, notch
}

private extension View {
    /// A grouped form that is exactly as tall as its content, so each tab
    /// sizes the window without empty space below the last section.
    func settingsPane() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Footers read as quiet captions under their group, never as warnings.
    func settingsFooter() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }

    /// Grouped forms dim a disabled control but not its label; dim the label
    /// too so a row that can't be changed reads that way as a whole.
    func dimmedWhenDisabled() -> some View {
        modifier(DisabledLabelDimming())
    }
}

private struct DisabledLabelDimming: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.45)
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
                Toggle(isOn: launchAtLoginBinding) {
                    Text("Open at login").dimmedWhenDisabled()
                }
                .disabled(!canOpenAtLogin)

                if launchAtLoginStatus == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    } label: {
                        Text("Waiting for approval")
                        Text("Allow Pulse in Login Items to finish turning this on.")
                    }
                }
            } footer: {
                Group {
                    if !canOpenAtLogin {
                        // A dimmed switch needs its reason and the remedy,
                        // not a description of what it would do.
                        Text("To open Pulse at login, move it to the Applications folder.")
                    } else if let launchAtLoginError {
                        Text("Open at login couldn’t be changed. \(launchAtLoginError)")
                    } else {
                        Text("Keeps the menu bar item, Notch Island and widgets up to date after you restart.")
                    }
                }
                .settingsFooter()
            }

            Section {
                Picker("Update frequency", selection: $refreshInterval) {
                    ForEach(PulseSettings.refreshIntervals, id: \.self) { interval in
                        Text(PulseSharedSettings.intervalDescription(interval)).tag(interval)
                    }
                }
            } footer: {
                Text("Faster updates are smoother but use slightly more energy.")
                    .settingsFooter()
            }

            Section {
                Picker("Show in menu bar", selection: $menuBarStyleRaw) {
                    ForEach(PulseSharedSettings.MenuBarStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
            }

            ShowInPulseSection()
        }
        .settingsPane()
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

    /// Login items can only be registered for a copy of Pulse that launchd
    /// can find, which in practice means one in the Applications folder.
    /// The switch and its footer read the same snapshot so they never
    /// disagree.
    private var canOpenAtLogin: Bool {
        launchAtLoginStatus != .notFound
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

// MARK: - Show in Pulse
/// Which optional metrics appear anywhere Pulse draws them. CPU and memory
/// are always shown, so they have no switch.
private struct ShowInPulseSection: View {
    @AppStorage(PulseSettings.Keys.showBattery, store: PulseSettings.defaults) private var showBattery = true
    @AppStorage(PulseSettings.Keys.showDisk, store: PulseSettings.defaults) private var showDisk = true
    @AppStorage(PulseSettings.Keys.showNetwork, store: PulseSettings.defaults) private var showNetwork = true
    @AppStorage(PulseSettings.Keys.unitsMode, store: PulseSettings.defaults) private var unitsModeRaw = PulseSettings.UnitsMode.automatic.rawValue

    var body: some View {
        Section {
            metricToggle("Battery", systemImage: "battery.75percent", isOn: $showBattery)
            metricToggle("Storage", systemImage: "internaldrive", isOn: $showDisk)
            metricToggle("Network", systemImage: "network", isOn: $showNetwork)

            Picker(selection: $unitsModeRaw) {
                ForEach(PulseSettings.UnitsMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            } label: {
                // Sits under Network and lines up with the titles above it.
                Text("Network speed")
                    .dimmedWhenDisabled()
                    .padding(.leading, SettingsIconTile.side + SettingsIconTile.spacing)
            }
            .pickerStyle(.segmented)
            .disabled(!showNetwork)
        } header: {
            Text("Show in Pulse")
        } footer: {
            Text("Applies to the Pulse window, menu bar, Notch Island and widgets. To add a widget, Control-click the desktop and choose Edit Widgets.")
                .settingsFooter()
        }
        .onChange(of: unitsModeRaw) { _, _ in reloadWidgets() }
        .onChange(of: showBattery) { _, _ in reloadWidgets() }
        .onChange(of: showDisk) { _, _ in reloadWidgets() }
        .onChange(of: showNetwork) { _, _ in reloadWidgets() }
    }

    private func metricToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: SettingsIconTile.spacing) {
                SettingsIconTile(systemImage: systemImage)
                Text(title)
            }
        }
    }

    private func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: "MacMonitorWidget")
    }
}

/// System Settings–style row icon: a white glyph on a neutral gray tile.
private struct SettingsIconTile: View {
    static let side: CGFloat = 20
    static let spacing: CGFloat = 10

    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: Self.side, height: Self.side)
            .background(Color(nsColor: .systemGray).gradient,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Notch Island
private struct NotchIslandSettingsPane: View {
    @AppStorage(PulseSettings.Keys.islandEnabled, store: PulseSettings.defaults) private var islandEnabled = false
    @AppStorage(PulseSettings.Keys.islandChargingActivity, store: PulseSettings.defaults) private var chargingActivity = true

    private let notchPresent = DynamicIslandPanel.notchIsPresent

    var body: some View {
        Form {
            Section {
                SettingsNotchIslandPreview(isOn: islandEnabled && notchPresent)
            }

            Section {
                Toggle(isOn: $islandEnabled) {
                    Text("Show Notch Island").dimmedWhenDisabled()
                }
                .disabled(!notchPresent)
                Toggle(isOn: $chargingActivity) {
                    Text("Show charging activity").dimmedWhenDisabled()
                    Text("Briefly shows the battery level when you connect power.").dimmedWhenDisabled()
                }
                .disabled(!notchPresent || !islandEnabled)
            } footer: {
                Text(notchPresent
                     ? "Click the Notch Island to see details. It hides automatically when an app is full screen."
                     : "This Mac’s built-in display doesn’t have a notch.")
                    .settingsFooter()
            }
        }
        .settingsPane()
        .onChange(of: islandEnabled) { _, _ in
            // The island controller observes this notification and re-evaluates
            // visibility against the (now-updated) setting + notch presence.
            NotificationCenter.default.post(name: .pulseIslandSettingChanged, object: nil)
        }
    }
}

/// The top edge of the display with the Notch Island at rest, drawn at its
/// real size: a CPU ring and label in the left ear, the percentage in the
/// right. When the feature is off the island stays in place, dimmed, so the
/// preview always shows what the switch controls.
struct SettingsNotchIslandPreview: View {
    let isOn: Bool
    @Environment(\.colorScheme) private var colorScheme

    // The resting island's geometry: notch-height, with one
    // `compactEarWidth` ear either side of a standard notch, so the preview
    // grows and shrinks with the real island.
    private let islandSize = CGSize(
        width: DynamicIslandMath.restingWidth(notchWidth: DynamicIslandMath.fallbackNotchWidth),
        height: 32
    )
    private let topRadius: CGFloat = 7
    private let bottomRadius: CGFloat = 12
    private let earInset: CGFloat = 8
    private let earClearance: CGFloat = 1
    private let earSpacing: CGFloat = 5
    private let ringSide: CGFloat = 16
    private let ringStroke: CGFloat = 2.5
    private let sampleCPU = 0.23

    /// What each ear offers its content, as on the island: the ear minus
    /// the outer shoulder and inset, and a hair of clearance at the notch.
    private var earContentWidth: CGFloat {
        DynamicIslandMath.compactEarWidth - topRadius - earInset - earClearance
    }

    var body: some View {
        island
            .opacity(isOn ? 1 : 0.35)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .frame(height: 72)
            .background(backdrop)
            // An inset well inside the form row, like System Settings'
            // wallpaper and display previews.
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(.easeInOut(duration: 0.25), value: isOn)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(isOn
                                     ? "Preview of the Notch Island: CPU at 23 percent beside the notch."
                                     : "Preview of the Notch Island, which is turned off."))
    }

    private var island: some View {
        HStack(spacing: 0) {
            HStack(spacing: earSpacing) {
                ring
                Text("CPU")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(width: earContentWidth, alignment: .leading)
            Spacer(minLength: 0)
            Text("23%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .frame(width: earContentWidth, alignment: .trailing)
        }
        .padding(.horizontal, topRadius + earInset)
        .frame(width: islandSize.width, height: islandSize.height)
        .background(
            IslandShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
                .fill(Color.black)
        )
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: ringStroke)
            Circle()
                .trim(from: 0, to: sampleCPU)
                .stroke(PulseStyle.accent, style: StrokeStyle(lineWidth: ringStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(ringStroke / 2)
        .frame(width: ringSide, height: ringSide)
    }

    /// A flat, neutral screen edge: no wallpaper hue to compete with the island.
    private var backdrop: Color {
        colorScheme == .dark ? Color(white: 0.24) : Color(white: 0.86)
    }
}
