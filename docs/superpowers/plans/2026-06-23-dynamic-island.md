# Pulse Dynamic Island Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a DynamicLake-style "Dynamic Island" — an always-on-top, notch-anchored black pill that shows Pulse's existing CPU% at rest and expands on click to the full system breakdown.

**Architecture:** One borderless `NSPanel` (`DynamicIslandPanel`) hosts a SwiftUI view (`DynamicIslandView`) via `NSHostingView`. The panel is created/dismissed by `MacMonitorApp` based on a new `islandEnabled` setting + notch presence. All content reads the existing `SystemStats`; no new data sources. The pure logic (notch detection, frame math, fullscreen predicate) lives in a testable `DynamicIslandMath` enum.

**Tech Stack:** Swift 5, SwiftUI, AppKit (`NSPanel`, `NSHostingView`, `NSWorkspace`, `CGWindowListCopyWindowInfo`), IOKit (already used). macOS 14.0+ deployment target. Xcode 16.4.

**Spec:** `docs/superpowers/specs/2026-06-23-dynamic-island-design.md`

---

## Build-system context (read before Task 1)

This project uses a hand-written `Pulse.xcodeproj` with **no file-system-synchronized groups** (Xcode 15-style). New `.swift` files are **not** picked up automatically. Every new app source file requires edits to `Pulse.xcodeproj/project.pbxproj` in **four** places:

1. **PBXBuildFile section** — add `<BUILDFILE_ID> /* Filename.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FILEREF_ID>; };`
2. **PBXFileReference section** — add `<FILEREF_ID> /* Filename.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Filename.swift; sourceTree = "<group>"; };`
3. **PBXGroup `Sources` (id `A7000002`)** — add `A2000XXX /* Filename.swift */,` to children
4. **PBXSourcesBuildPhase `MacMonitorApp` (id `AA000002`)** — add `<BUILDFILE_ID> /* Filename.swift in Sources */,` to files

Use IDs that don't collide with existing ones. The existing IDs use `A1/A2/A3/A4/A5/A6/A7/A8/A9/AA/AB/AC` prefixes. **For new files, use a clearly-unique prefix `D1` (buildfile) and `D2` (fileref), with a per-file numeric suffix** — e.g. `D1000010`, `D2000010`. The exact values don't matter, only that they're internally consistent and unique.

**Tests** run via SwiftPM (`swift test`), not Xcode. New test files added under `Tests/MacMonitorWidgetTests/` are auto-discovered by SPM — no project edits needed.

**Verify the build at any time with:**
```bash
xcodebuild -project Pulse.xcodeproj -scheme MacMonitorApp -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3
```
Expect `** BUILD SUCCEEDED **`.

**Run tests with:**
```bash
swift test 2>&1 | tail -20
```

---

## File map

| File | Responsibility | New/Modified |
|---|---|---|
| `Sources/SystemStats.swift` | Add `islandEnabled` settings key; add `DynamicIslandMath` enum (pure logic) | Modified |
| `Sources/DynamicIslandView.swift` | SwiftUI resting + expanded layouts, expand/collapse animation | **New** |
| `Sources/DynamicIslandPanel.swift` | `NSPanel` shell: level, collection behavior, positioning, show/hide, fullscreen detection, click-outside monitor | **New** |
| `Sources/MacMonitorApp.swift` | Own panel lifecycle; add Settings `GroupBox` + menu `Toggle`; observe screen changes | Modified |
| `Tests/MacMonitorWidgetTests/DynamicIslandMathTests.swift` | Unit tests for `DynamicIslandMath` | **New** |
| `Pulse.xcodeproj/project.pbxproj` | Wire the 2 new app files into the `MacMonitorApp` target | Modified |
| `Package.swift` | Add the 2 new app files to the `exclude` list | Modified |

The new app files are **app-only** (like `MacMonitorApp.swift`, which is already excluded from the SPM library target). `DynamicIslandMath` lives in `SystemStats.swift` so the test target (which compiles `SystemStats.swift`) can reach it.

---

## Task 1: Testable math — notch detection

**Files:**
- Modify: `Sources/SystemStats.swift` (add `DynamicIslandMath` enum at end of file)
- Test: `Tests/MacMonitorWidgetTests/DynamicIslandMathTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MacMonitorWidgetTests/DynamicIslandMathTests.swift`:

```swift
import XCTest
@testable import MacMonitorWidget

final class DynamicIslandMathTests: XCTestCase {
    // MARK: - Notch presence

    func testNotchPresentWhenAuxiliaryAreaExistsAndSafeAreaExceedsMenuBar() {
        XCTAssertTrue(DynamicIslandMath.notchPresent(safeAreaTopInset: 32, auxiliaryTopLeftArea: .zero))
    }

    func testNotchAbsentWhenAuxiliaryAreaIsNil() {
        XCTAssertFalse(DynamicIslandMath.notchPresent(safeAreaTopInset: 32, auxiliaryTopLeftArea: nil))
    }

    func testNotchAbsentWhenSafeAreaDoesNotExceedMenuBar() {
        // 24pt or less is a standard menu bar with no notch
        XCTAssertFalse(DynamicIslandMath.notchPresent(safeAreaTopInset: 24, auxiliaryTopLeftArea: .zero))
        XCTAssertFalse(DynamicIslandMath.notchPresent(safeAreaTopInset: 0, auxiliaryTopLeftArea: .zero))
    }

    func testNotchAbsentForNonFiniteInset() {
        XCTAssertFalse(DynamicIslandMath.notchPresent(safeAreaTopInset: .nan, auxiliaryTopLeftArea: .zero))
        XCTAssertFalse(DynamicIslandMath.notchPresent(safeAreaTopInset: .infinity, auxiliaryTopLeftArea: .zero))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DynamicIslandMathTests 2>&1 | tail -20`
Expected: compile error — `DynamicIslandMath` does not exist.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/SystemStats.swift` (after the `SystemMonitor` class, end of file):

```swift
// MARK: - Dynamic Island Math
/// Pure, testable predicates for the Dynamic Island. Kept separate from any
/// AppKit context so they compile in the test target (which links
/// `SystemStats.swift` via the SPM library target).
enum DynamicIslandMath {
    /// The standard menu-bar height in points, with no notch. A safe-area top
    /// inset greater than this implies the menu bar sits beside a notch.
    static let menuBarOnlyHeight: CGFloat = 24

    /// Returns true when the screen has a physical notch.
    ///
    /// Notch presence is inferred two ways, matching Apple's guidance:
    /// 1. `auxiliaryTopLeftArea` (the menu-bar area to the left of the notch)
    ///    is non-nil only on notched screens.
    /// 2. The safe-area top inset exceeds a plain menu bar (~24pt).
    static func notchPresent(safeAreaTopInset: CGFloat, auxiliaryTopLeftArea: NSRect?) -> Bool {
        guard auxiliaryTopLeftArea != nil else { return false }
        guard safeAreaTopInset.isFinite else { return false }
        return safeAreaTopInset > menuBarOnlyHeight
    }
}
```

**Note:** `NSRect` and `CGFloat` are from Foundation/AppKit, which `SystemStats.swift` already imports (it uses AppKit for `NSWorkspace`). The SPM target already compiles `SystemStats.swift`, so this works in both the app and tests.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DynamicIslandMathTests 2>&1 | tail -20`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SystemStats.swift Tests/MacMonitorWidgetTests/DynamicIslandMathTests.swift
git commit -m "Add Dynamic Island notch-detection predicate with tests"
```

---

## Task 2: Testable math — island frames

**Files:**
- Modify: `Sources/SystemStats.swift` (extend `DynamicIslandMath`)
- Test: `Tests/MacMonitorWidgetTests/DynamicIslandMathTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/MacMonitorWidgetTests/DynamicIslandMathTests.swift`, inside the class:

```swift
    // MARK: - Island frames

    func testRestingFrameFillsNotchHeightAndCentersHorizontally() {
        // Screen 1728pt wide (a 14" MacBook at default scaling), notch 32pt tall.
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let frame = DynamicIslandMath.restingFrame(screen: screen, notchHeight: 32)

        XCTAssertEqual(frame.height, 32, accuracy: 0.01)
        XCTAssertEqual(frame.width, 150, accuracy: 0.01)
        // Horizontally centered: midX == screen midX
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.01)
        // Top edge at the top of the screen (y in screen coords; AppKit origin
        // is bottom-left, so "top" is screen.maxY)
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.01)
    }

    func testExpandedFrameGrowsDownwardFromSameTopEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let resting = DynamicIslandMath.restingFrame(screen: screen, notchHeight: 32)
        let expanded = DynamicIslandMath.expandedFrame(screen: screen, notchHeight: 32)

        // Same horizontal center
        XCTAssertEqual(expanded.midX, resting.midX, accuracy: 0.01)
        // Same top edge (grows downward = top edge fixed, bottom edge drops)
        XCTAssertEqual(expanded.maxY, resting.maxY, accuracy: 0.01)
        XCTAssertGreaterThan(expanded.height, resting.height)
        XCTAssertGreaterThan(expanded.width, resting.width)
    }

    func testRestingWidthIsNarrowerThanTypicalNotch() {
        // A 14" notch is ~200pt; the pill must be narrower so it sits inside.
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let frame = DynamicIslandMath.restingFrame(screen: screen, notchHeight: 32)
        XCTAssertLessThan(frame.width, 200)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DynamicIslandMathTests 2>&1 | tail -20`
Expected: compile error — `restingFrame`/`expandedFrame` do not exist.

- [ ] **Step 3: Write minimal implementation**

Add to the `DynamicIslandMath` enum in `Sources/SystemStats.swift`:

```swift
    /// Pill dimensions. The resting pill exactly fills the notch vertically
    /// and is comfortably narrower than the physical notch. The expanded pill
    /// grows downward into a rounded card.
    static let restingWidth: CGFloat = 150
    static let expandedWidth: CGFloat = 240
    static let expandedHeight: CGFloat = 150

    /// The resting pill frame: fills `notchHeight` vertically, centered on the
    /// screen, pinned to the top edge. Uses AppKit screen coordinates
    /// (origin bottom-left).
    static func restingFrame(screen: CGRect, notchHeight: CGFloat) -> CGRect {
        let height = max(notchHeight, 1)
        let width = restingWidth
        let x = screen.midX - width / 2
        let y = screen.maxY - height  // top edge at screen top
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The expanded pill frame: same center and top edge as the resting frame,
    /// taller and wider, so the expand animation reads as "growing downward".
    static func expandedFrame(screen: CGRect, notchHeight: CGFloat) -> CGRect {
        let width = expandedWidth
        let height = expandedHeight
        let x = screen.midX - width / 2
        let y = screen.maxY - height  // top edge aligns with resting top edge
        return CGRect(x: x, y: y, width: width, height: height)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DynamicIslandMathTests 2>&1 | tail -20`
Expected: all DynamicIslandMath tests pass (7 total now).

- [ ] **Step 5: Commit**

```bash
git add Sources/SystemStats.swift Tests/MacMonitorWidgetTests/DynamicIslandMathTests.swift
git commit -m "Add Dynamic Island frame math with tests"
```

---

## Task 3: Testable math — fullscreen predicate

**Files:**
- Modify: `Sources/SystemStats.swift` (extend `DynamicIslandMath`)
- Test: `Tests/MacMonitorWidgetTests/DynamicIslandMathTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/MacMonitorWidgetTests/DynamicIslandMathTests.swift`:

```swift
    // MARK: - Fullscreen detection

    func testFullscreenWhenWindowCoversScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let covering = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        XCTAssertTrue(DynamicIslandMath.isFullscreen(window: covering, screen: screen))
    }

    func testNotFullscreenWhenWindowIsSmallerThanScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let smaller = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertFalse(DynamicIslandMath.isFullscreen(window: smaller, screen: screen))
    }

    func testNotFullscreenWhenWindowCoversWrongScreen() {
        let screen = CGRect(x: 1728, y: 0, width: 1920, height: 1080) // external display
        let coveringMain = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        XCTAssertFalse(DynamicIslandMath.isFullscreen(window: coveringMain, screen: screen))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DynamicIslandMathTests 2>&1 | tail -20`
Expected: compile error — `isFullscreen` does not exist.

- [ ] **Step 3: Write minimal implementation**

Add to `DynamicIslandMath` in `Sources/SystemStats.swift`:

```swift
    /// Returns true when `window` fully covers `screen`, the heuristic for
    /// "a fullscreen app is frontmost on this display". A small inset is
    /// tolerated so a fullscreen window reported a few points short of the
    /// screen edge still counts.
    static func isFullscreen(window: CGRect, screen: CGRect) -> Bool {
        let tolerance: CGFloat = 4
        return window.minX <= screen.minX + tolerance
            && window.minY <= screen.minY + tolerance
            && window.maxX >= screen.maxX - tolerance
            && window.maxY >= screen.maxY - tolerance
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DynamicIslandMathTests 2>&1 | tail -20`
Expected: all 10 DynamicIslandMath tests pass.

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `swift test 2>&1 | tail -20`
Expected: all tests pass (`Executed N tests, with 0 failures`).

- [ ] **Step 6: Commit**

```bash
git add Sources/SystemStats.swift Tests/MacMonitorWidgetTests/DynamicIslandMathTests.swift
git commit -m "Add Dynamic Island fullscreen-cover predicate with tests"
```

---

## Task 4: Settings key for island enablement

**Files:**
- Modify: `Sources/SystemStats.swift` (add to `PulseSharedSettings.Keys`)

- [ ] **Step 1: Add the key**

In `Sources/SystemStats.swift`, find the `enum Keys` inside `PulseSharedSettings` (around line 98) and add the new key:

```swift
    enum Keys {
        static let launchAtLogin = "settings.launchAtLogin"
        static let refreshInterval = "settings.refreshInterval"
        static let unitsMode = "settings.unitsMode"
        static let showBattery = "settings.showBattery"
        static let showDisk = "settings.showDisk"
        static let showNetwork = "settings.showNetwork"
        static let showActiveApps = "settings.showActiveApps"
        static let islandEnabled = "settings.islandEnabled"   // NEW
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: build succeeds (no test needed — it's a string constant).

- [ ] **Step 3: Commit**

```bash
git add Sources/SystemStats.swift
git commit -m "Add Dynamic Island enablement settings key"
```

---

## Task 5: SwiftUI island view (resting + expanded)

**Files:**
- Create: `Sources/DynamicIslandView.swift`
- Modify: `Pulse.xcodeproj/project.pbxproj` (4 edits), `Package.swift` (exclude)

This is a larger task. Build the view first, wire it into the project second.

- [ ] **Step 1: Create the view file**

Create `Sources/DynamicIslandView.swift`:

```swift
import SwiftUI

// MARK: - Dynamic Island View
/// Renders the Dynamic Island content: a compact resting pill (CPU%) that
/// expands on click to the full system breakdown. All values come from the
/// existing `SystemStats` model — this view introduces no new data.
struct DynamicIslandView: View {
    let stats: SystemStats
    @Binding var isExpanded: Bool

    @AppStorage(PulseSharedSettings.Keys.unitsMode, store: PulseSharedSettings.defaults) private var unitsModeRaw = PulseSharedSettings.UnitsMode.automatic.rawValue

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
```

- [ ] **Step 2: Add the file to the Xcode project (4 edits to project.pbxproj)**

Using IDs `D1000010` (buildfile) and `D2000010` (fileref):

Edit `Pulse.xcodeproj/project.pbxproj`:

**(a) PBXBuildFile section** — after line 17 (`A1000008`), add:
```
		D1000010 /* DynamicIslandView.swift in Sources */ = {isa = PBXBuildFile; fileRef = D2000010; };
```

**(b) PBXFileReference section** — after line 53 (`A2000005`), add:
```
		D2000010 /* DynamicIslandView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DynamicIslandView.swift; sourceTree = "<group>"; };
```

**(c) PBXGroup Sources (`A7000002`)** — after line 93 (`A2000005`), add:
```
				D2000010 /* DynamicIslandView.swift */,
```

**(d) PBXSourcesBuildPhase MacMonitorApp (`AA000002`)** — after line 231 (`A1000005`), add:
```
				D1000010 /* DynamicIslandView.swift in Sources */,
```

- [ ] **Step 3: Exclude the file from the SPM library target**

In `Package.swift`, add `"DynamicIslandView.swift"` to the `exclude` list. The list currently ends with `"WidgetViews.swift"`; add after it:

```swift
            exclude: [
                "Assets.xcassets",
                "Info.plist",
                "MacMonitorApp.entitlements",
                "MacMonitorApp.swift",
                "MacMonitorWidget.swift",
                "MacMonitorWidgetExtension.entitlements",
                "WidgetViews.swift",
                "DynamicIslandView.swift"   // NEW
            ]
```

- [ ] **Step 4: Verify the Xcode app build compiles**

Run: `xcodebuild -project Pulse.xcodeproj -scheme MacMonitorApp -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Verify SPM tests still compile (the file is excluded from the lib)**

Run: `swift build 2>&1 | tail -5`
Expected: succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/DynamicIslandView.swift Pulse.xcodeproj/project.pbxproj Package.swift
git commit -m "Add Dynamic Island SwiftUI view (resting + expanded)"
```

---

## Task 6: NSPanel shell — show/hide + notch anchoring

**Files:**
- Create: `Sources/DynamicIslandPanel.swift`
- Modify: `Pulse.xcodeproj/project.pbxproj` (4 edits), `Package.swift` (exclude)

- [ ] **Step 1: Create the panel file**

Create `Sources/DynamicIslandPanel.swift`:

```swift
import SwiftUI
import AppKit

// MARK: - Dynamic Island Panel
/// A borderless, always-on-top `NSPanel` that anchors in the MacBook notch and
/// hosts the SwiftUI `DynamicIslandView`. The panel owns:
///   - window level / collection behavior (above everything, all spaces),
///   - notch detection + frame positioning,
///   - show / hide,
///   - the click-outside-to-collapse monitor.
///
/// It does NOT know about stats — it receives a root view from its owner.
final class DynamicIslandPanel: NSPanel {
    private var globalClickMonitor: Any?

    init(rootView: some View) {
        // .nonactivatingPanel: clicking the island never steals app focus.
        super.init(
            contentRect: DynamicIslandMath.restingFrame(screen: NSScreen.main?.frame ?? .zero, notchHeight: DynamicIslandPanel.notchHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovable = false
        self.ignoresMouseEvents = false
        self.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Notch geometry

    /// True when the menu-bar screen has a physical notch.
    static var notchIsPresent: Bool {
        guard let screen = menuBarScreen else { return false }
        return DynamicIslandMath.notchPresent(
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea
        )
    }

    /// The notch height on the menu-bar screen, or nil if there's no notch.
    static var notchHeight: CGFloat {
        menuBarScreen?.safeAreaInsets.top ?? 32
    }

    /// The screen that hosts the menu bar (first in `NSScreen.screens`).
    static var menuBarScreen: NSScreen? {
        NSScreen.screens.first
    }

    // MARK: - Show / hide

    func show() {
        positionAtNotch()
        orderFront(nil)
        startClickMonitor()
    }

    func hide() {
        orderOut(nil)
        stopClickMonitor()
    }

    /// Re-anchor to the notch — call on screen-layout changes.
    func positionAtNotch() {
        guard let screen = DynamicIslandPanel.menuBarScreen else { return }
        let frame = DynamicIslandMath.restingFrame(screen: screen.frame, notchHeight: DynamicIslandPanel.notchHeight)
        setFrame(frame, display: true)
    }

    // MARK: - Click-outside-to-collapse

    /// Collapse callback invoked when a click lands outside the panel frame.
    var onCollapse: (() -> Void)?

    private func startClickMonitor() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents([.leftMouseDown]) { [weak self] _ in
            guard let self else { return }
            self.onCollapse?()
        }
    }

    private func stopClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    deinit {
        stopClickMonitor()
    }
}
```

- [ ] **Step 2: Add the file to the Xcode project (4 edits)**

Using IDs `D1000011` (buildfile) and `D2000011` (fileref), repeat the same 4-edit pattern as Task 5 Step 2 but with `DynamicIslandPanel.swift`:

**(a) PBXBuildFile section** — add after the `D1000010` line:
```
		D1000011 /* DynamicIslandPanel.swift in Sources */ = {isa = PBXBuildFile; fileRef = D2000011; };
```

**(b) PBXFileReference section** — add after the `D2000010` line:
```
		D2000011 /* DynamicIslandPanel.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DynamicIslandPanel.swift; sourceTree = "<group>"; };
```

**(c) PBXGroup Sources (`A7000002`)** — add after the `D2000010` line:
```
				D2000011 /* DynamicIslandPanel.swift */,
```

**(d) PBXSourcesBuildPhase MacMonitorApp (`AA000002`)** — add after the `D1000010` line:
```
				D1000011 /* DynamicIslandPanel.swift in Sources */,
```

- [ ] **Step 3: Exclude from SPM**

In `Package.swift`, add `"DynamicIslandPanel.swift"` to the `exclude` list (after `"DynamicIslandView.swift"`).

- [ ] **Step 4: Verify the build compiles**

Run: `xcodebuild -project Pulse.xcodeproj -scheme MacMonitorApp -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/DynamicIslandPanel.swift Pulse.xcodeproj/project.pbxproj Package.swift
git commit -m "Add Dynamic Island NSPanel shell with notch anchoring"
```

---

## Task 7: Wire the panel into the app + menu toggle

**Files:**
- Modify: `Sources/MacMonitorApp.swift`

- [ ] **Step 1: Add an island controller to `MacMonitorApp`**

In `Sources/MacMonitorApp.swift`, add a new `@StateObject` to the app and a coordinator. First, add the import at top (AppKit is already conditionally imported). Then modify the `@main` struct:

Replace:
```swift
@main
struct MacMonitorApp: App {
    @StateObject private var statsController = PulseStatsController()

    var body: some Scene {
```
with:
```swift
@main
struct MacMonitorApp: App {
    @StateObject private var statsController = PulseStatsController()
    @StateObject private var islandController = DynamicIslandController(statsController: statsController)

    var body: some Scene {
```

- [ ] **Step 2: Add the `DynamicIslandController` class**

Add this class in `Sources/MacMonitorApp.swift` (e.g. after the `PulseStatsController` class):

```swift
// MARK: - Dynamic Island Controller
/// Owns the `DynamicIslandPanel` lifecycle: creates/shows it when the user
/// enables the setting AND a notch is present; tears it down otherwise.
/// Observes screen-layout changes so the panel stays anchored.
@MainActor
final class DynamicIslandController: ObservableObject {
    @Published private(set) var isExpanded = false
    @Published private(set) var notchPresent: Bool

    private let statsController: PulseStatsController
    private var panel: DynamicIslandPanel?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    init(statsController: PulseStatsController) {
        self.statsController = statsController
        self.notchPresent = DynamicIslandPanel.notchIsPresent
        observeScreenChanges()
        applyVisibility()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }

    /// Re-evaluate notch + setting, then show or hide.
    func applyVisibility() {
        notchPresent = DynamicIslandPanel.notchIsPresent
        let enabled = PulseSharedSettings.defaults.bool(forKey: PulseSharedSettings.Keys.islandEnabled)

        if enabled && notchPresent {
            ensurePanelShown()
        } else {
            teardownPanel()
        }
    }

    private func ensurePanelShown() {
        if panel == nil {
            let rootView = DynamicIslandView(
                stats: statsController.stats,
                isExpanded: Binding(
                    get: { [weak self] in self?.isExpanded ?? false },
                    set: { [weak self] newValue in self?.setExpanded(newValue) }
                )
            )
            let newPanel = DynamicIslandPanel(rootView: rootView)
            newPanel.onCollapse = { [weak self] in self?.setExpanded(false) }
            panel = newPanel
        }
        panel?.show()
    }

    /// Single mutation point for the published expand state.
    private func setExpanded(_ value: Bool) {
        guard isExpanded != value else { return }
        isExpanded = value
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
}
```

- [ ] **Step 3: Add the menu-bar toggle item**

In the `PulseMenuBarMenu` struct, add a stored property and menu item. Add the `@AppStorage` near the existing ones (around line 190):

```swift
    @AppStorage(PulseSettings.Keys.islandEnabled, store: PulseSettings.defaults) private var islandEnabled = false
```

Then in `PulseMenuBarMenu.body`, add the toggle **above** the "Refresh Stats" button (after the metrics block, before `Divider()`). Find:

```swift
        Divider()

        Button {
            statsController.refresh(reloadWidgets: true)
        } label: {
            Label("Refresh Stats", systemImage: "arrow.clockwise")
        }
```

Replace with:

```swift
        Divider()

        Toggle("Dynamic Island", isOn: $islandEnabled)

        Button {
            statsController.refresh(reloadWidgets: true)
        } label: {
            Label("Refresh Stats", systemImage: "arrow.clockwise")
        }
```

- [ ] **Step 4: Verify the build compiles**

Run: `xcodebuild -project Pulse.xcodeproj -scheme MacMonitorApp -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacMonitorApp.swift
git commit -m "Wire Dynamic Island panel into app with menu toggle"
```

---

## Task 8: Settings window GroupBox + re-evaluate on toggle

**Files:**
- Modify: `Sources/MacMonitorApp.swift`

- [ ] **Step 1: Add the Dynamic Island GroupBox to Settings**

In `PulseSettingsView`, add an `@AppStorage` for the island setting and a status row. First, add the stored property near the others (around line 278):

```swift
    @AppStorage(PulseSettings.Keys.islandEnabled, store: PulseSettings.defaults) private var islandEnabled = false
```

Then add a new `GroupBox` in `body`, **between** the "Startup" GroupBox and the "Display" GroupBox. Find the end of the Startup GroupBox:

```swift
                    } label: {
                        SettingsSectionLabel(title: "Startup", systemImage: "power")
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            settingsControlRow("Refresh Interval") {
```

Insert a new GroupBox between them:

```swift
                    } label: {
                        SettingsSectionLabel(title: "Startup", systemImage: "power")
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Dynamic Island", isOn: $islandEnabled)
                            settingsStatusRow(islandStatusText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        SettingsSectionLabel(title: "Dynamic Island", systemImage: "rectangle.dashed")
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            settingsControlRow("Refresh Interval") {
```

- [ ] **Step 2: Add the status text computed property**

In `PulseSettingsView`, add this computed property (e.g. near `batterySummary`-style helpers, before the closing brace of the struct):

```swift
    private var islandStatusText: String {
        DynamicIslandPanel.notchIsPresent ? "Notch detected" : "No notch on this Mac — island unavailable"
    }
```

- [ ] **Step 3: Reload the island visibility when the toggle changes**

In `PulseSettingsView.body`, add an `.onChange` for `islandEnabled` alongside the existing ones (near line 365). Add:

```swift
        .onChange(of: islandEnabled) { _, _ in
            // The menu toggle and controller react via @AppStorage; force a
            // re-evaluation by posting the screen-parameters notification.
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
```

**Why a notification instead of calling the controller directly:** the Settings view doesn't own the `islandController`. The `@AppStorage` change is already observed; posting `didChangeScreenParametersNotification` triggers `applyVisibility()` on the controller, which re-reads the (now-updated) setting. This keeps the wiring decoupled.

- [ ] **Step 4: Verify the build compiles**

Run: `xcodebuild -project Pulse.xcodeproj -scheme MacMonitorApp -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacMonitorApp.swift
git commit -m "Add Dynamic Island settings section with notch status"
```

---

## Task 9: Fullscreen hiding

**Files:**
- Modify: `Sources/DynamicIslandPanel.swift`, `Sources/MacMonitorApp.swift`

- [ ] **Step 1: Add fullscreen detection to the panel**

In `Sources/DynamicIslandPanel.swift`, add a method to `DynamicIslandPanel` that checks the CGWindowList:

```swift
    /// True when a normal-layer window fully covers the menu-bar screen —
    /// i.e. a fullscreen app is frontmost on that display.
    static func frontmostAppCoversMenuBarScreen() -> Bool {
        guard let screen = menuBarScreen else { return false }
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for info in windowInfo {
            // kCGWindowLayer == 0 means a normal app window (not menu/overlay).
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            // Skip fully transparent windows.
            guard let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let w = boundsDict["Width"] as? CGFloat,
                  let h = boundsDict["Height"] as? CGFloat else { continue }

            let windowRect = CGRect(x: x, y: y, width: w, height: h)
            if DynamicIslandMath.isFullscreen(window: windowRect, screen: screen.frame) {
                return true
            }
        }
        return false
    }
```

- [ ] **Step 2: Subscribe to space changes in the controller**

In `DynamicIslandController` (in `Sources/MacMonitorApp.swift`), add a workspace observer. Add a property (alongside `screenObserver`):

```swift
    private var spaceObserver: NSObjectProtocol?
```

In `init`, call `observeActiveSpace()` right after the existing `observeScreenChanges()` call:

```swift
    init(statsController: PulseStatsController) {
        self.statsController = statsController
        self.notchPresent = DynamicIslandPanel.notchIsPresent
        observeScreenChanges()
        observeActiveSpace()      // NEW
        applyVisibility()
    }
```

Add the method:

```swift
    private func observeActiveSpace() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFullscreenHiding() }
        }
    }

    private func refreshFullscreenHiding() {
        // Only relevant while enabled + a notch exists.
        let enabled = PulseSharedSettings.defaults.bool(forKey: PulseSharedSettings.Keys.islandEnabled)
        guard enabled, notchPresent else { return }

        if DynamicIslandPanel.frontmostAppCoversMenuBarScreen() {
            panel?.hide()
        } else {
            panel?.show()
        }
    }
```

And in `deinit`, also remove the space observer (the `spaceObserver` property was added in Step 2):

```swift
    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }
```

- [ ] **Step 3: Verify the build compiles**

Run: `xcodebuild -project Pulse.xcodeproj -scheme MacMonitorApp -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Sources/DynamicIslandPanel.swift Sources/MacMonitorApp.swift
git commit -m "Hide Dynamic Island when a fullscreen app covers the menu-bar screen"
```

---

## Task 10: Full build + manual verification

**Files:** none (verification only)

- [ ] **Step 1: Full clean build**

Run:
```bash
xcodebuild -project Pulse.xcodeproj -scheme MacMonitorApp -configuration Debug -destination 'platform=macOS' clean build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Run the full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: all tests pass, including the 10 new `DynamicIslandMathTests`.

- [ ] **Step 3: Launch and manually verify**

Run:
```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "MacMonitorApp.app" -path "*/Debug/*" | head -1)
pkill -x MacMonitorApp 2>/dev/null; sleep 1
open "$APP"
```

Manual checklist (requires a **notch MacBook**; on a non-notch Mac the island correctly does not appear — that itself is item 1):

1. **Notch detection:** On a notch Mac, Settings → Dynamic Island shows "Notch detected". On a non-notch Mac it shows "No notch on this Mac — island unavailable" and the toggle does nothing visible.
2. **Resting pill:** Toggle on. A black pill appears in the notch showing `🟢 CPU%`.
3. **Expand:** Click the pill. It springs open to a card with CPU/RAM/Disk/Battery/Network/Apps.
4. **Collapse:** Click the pill again → collapses. Or click elsewhere on screen → collapses.
5. **Menu toggle:** Menu bar item → "Dynamic Island" toggles sync with the Settings toggle.
6. **Fullscreen:** Enter a fullscreen app on the menu-bar display → island disappears. Exit → island returns.
7. **Screen change:** Plug/unplug an external display — island stays anchored to the menu-bar screen, no crash.

- [ ] **Step 4: Commit any fixups discovered during verification**

If manual testing surfaced fixes, commit them:
```bash
git add -A
git commit -m "Fix issues found in Dynamic Island manual verification"
```

---

## Done criteria

- [ ] `swift test` passes with 10 new `DynamicIslandMathTests` and all existing tests green.
- [ ] `xcodebuild` Debug build succeeds.
- [ ] App launches; on a notch Mac the island appears, expands on click, collapses on outside click, hides in fullscreen, and toggles via Settings + menu.
- [ ] On a non-notch Mac the island never appears and the toggle is correctly inert.
- [ ] All 10 tasks committed as separate, focused commits.
```
