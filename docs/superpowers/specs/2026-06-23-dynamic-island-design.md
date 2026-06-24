# Pulse Dynamic Island — Design Spec

**Date:** 2026-06-23
**Status:** Draft (pending user review)
**Scope:** First iteration — island shell + Pulse's existing system stats

---

## 1. Goal

Add a **DynamicLake-style "Dynamic Island"** to Pulse: an always-on-top, animated pill anchored in the MacBook notch that surfaces Pulse's existing system metrics, collapses to a minimal resting state, and expands on click to show the full breakdown.

This is the foundation layer. Later iterations can add Now Playing, timers, AirPods, and transient alerts — those are explicitly **out of scope** for this spec.

## 2. Non-goals (this iteration)

- Now Playing / media controls
- Timers, AirPods, charging animations
- Album art, scrubbers, or any rich media content
- A floating fallback for non-notch Macs (the island simply does not appear)
- WidgetKit / Notification Center widget changes
- Any change to how stats are *collected* — the island only *reads* what `PulseStatsController` already produces

## 3. User-visible behavior

| Aspect | Decision |
|---|---|
| **Placement** | Inside the physical notch, expanding downward. **Notch Macs only** — on iMac / Mac mini / older MacBooks the feature is absent and Pulse otherwise works normally. |
| **Resting state** | A compact black pill showing **CPU% only** (e.g. `🟢 45%`). Matches the notch silhouette at rest. |
| **Expanded state** | On click, the pill grows downward into a rounded card showing CPU, RAM, Disk, Battery, Network (up/down), and Active Apps — the same metrics the menu bar and widgets already expose. |
| **Expand trigger** | **Click** the pill to expand. Click the pill again, or click anywhere outside it, to collapse. (No hover.) |
| **On/off control** | A new **"Dynamic Island"** toggle in the Settings window, plus a quick on/off **menu bar menu item**. When off, the panel is fully dismissed (not merely hidden). |
| **Fullscreen** | The island **hides** whenever a fullscreen app is frontmost on the menu-bar display, and returns when back on the desktop. |
| **Animation** | Spring expand/collapse (SwiftUI `.spring`, response ~0.35, damping ~0.8), consistent with Pulse's existing widget-preview animation. |

### Metrics shown (expanded)

All values come from the existing `SystemStats` model; **no new data sources are introduced.**

| Metric | Source field | Format |
|---|---|---|
| CPU | `cpuUsage` | `PulseSettings.percent(...)` |
| RAM | `memoryUsage` (and `memoryUsed`/`memoryTotal`) | percent + "x GB / y GB" |
| Disk | `diskAvailable` / `diskTotal` | "x GB free" |
| Battery | `batteryLevel`, `isCharging`, `hasBattery` | "78% ⚡" or "AC" when no battery |
| Network | `networkUp`, `networkDown` | `PulseSettings.formatSpeed(...)` in current units mode |
| Active Apps | `activeApps` | comma-joined, same prefix(4) logic as the menu |

## 4. Architecture

### 4.1 Approach chosen: dedicated borderless `NSPanel` hosting SwiftUI

A single `DynamicIslandPanel` (subclass of `NSPanel`) hosts a SwiftUI `DynamicIslandView` via `NSHostingView`. Only the *shell* is AppKit; all content is declarative SwiftUI, matching Pulse's existing style (which already mixes SwiftUI with `NSVisualEffectView`, `NSWorkspace`, `ServiceManagement`).

Rejected alternatives (see §9):
- A SwiftUI `Window` scene styled borderless — insufficient control over level, click-through, and space-ignoring behavior; ends up reaching into AppKit anyway.
- Rendering into the existing `MenuBarExtra` — can't produce free-floating, notch-anchored content.

### 4.2 Components (all new code)

```
Sources/
├── DynamicIslandPanel.swift      # NSPanel shell: window level, collection behavior, positioning, show/hide, fullscreen detection
├── DynamicIslandView.swift       # SwiftUI content: resting + expanded layouts, expand/collapse animation
└── (existing) MacMonitorApp.swift   # wiring: owns the panel lifecycle, settings toggle, menu item
```

Each unit has one clear purpose:

- **`DynamicIslandPanel`** — "a borderless, always-on-top window anchored at the notch that can show, hide, and animate its own size." Depends only on AppKit + a SwiftUI root view. Knows nothing about stats.
- **`DynamicIslandView`** — "renders Pulse stats into a collapsed or expanded island layout." Depends on `SystemStats` (read-only) and an expand/collapse flag. Knows nothing about windows.
- **Wiring in `MacMonitorApp`** — observes `islandEnabled` + notch presence; creates/tears down the panel; forwards the latest `SystemStats`.

### 4.3 Window configuration

- **Style mask:** `.borderless` (no title bar, no shadow from the system — we draw our own).
- **Level:** `.statusBar` (keeps it above the menu bar and most things). Note: still subject to fullscreen-space rules, which is why we explicitly hide in fullscreen (§4.6).
- **Collection behavior:** `[.canJoinAllSpaces, .stationary, .ignoresCycle]` — visible on every space, doesn't move with spaces, excluded from window cycling.
- **Panel flags:** `.nonactivatingPanel` so clicking the island doesn't steal focus from the user's app; plus `handles its own mouse events`.
- **Background:** opaque black (`#000000`) rounded rectangle, matching the notch; **no** `NSVisualEffectView` blur (the real Dynamic Island is solid black, not translucent).
- **Click regions (three, no ambiguity):**
  1. **Pill pixels** (inside the rounded black shape) → consumed by the island; toggles expand/collapse.
  2. **Corner pixels** (inside the panel's rectangular frame but outside the rounded corners — the four little transparent triangles) → pass-through to apps beneath, so menu-bar items beside the notch stay clickable. Achieved with `NSPanel`'s `ignoresMouseEvents = false` plus a SwiftUI hit-test shape equal to the `RoundedRectangle` (the `Color.clear` background around it doesn't capture hits).
  3. **Outside the panel frame entirely** → captured by a global `NSEvent` monitor and collapses the island if expanded (see §4.5).

### 4.4 Notch detection & positioning

- **Detection:** a notch is present when `NSScreen.main?.auxiliaryTopLeftArea` is non-nil (Apple's documented signal that the menu bar sits beside a notch) **and** `safeAreaInsets.top` is greater than the standard menu bar height (~24–25pt). If either fails, the island is treated as **unavailable** and the panel is never created.
- **Position:** horizontally centered on the menu-bar display; vertically pinned so the resting pill's top edge aligns with `y = 0` of the screen (top of the notch) and it grows **downward**. Recomputed on screen/layout changes and on `NSApplication.didChangeScreenParameters`.
- **Size:** two fixed frames — a small `restingSize` and a larger `expandedSize` — animated between with SwiftUI `spring`. The `NSWindow` frame is resized to match the SwiftUI content's intrinsic size each animation step (driven by observing the hosted view's size, or by setting the frame from the known target sizes).

### 4.5 Expand/collapse interaction

- The `DynamicIslandView` root is a `Button`-wrapped `Color.clear`-background rounded rectangle so the whole pill is clickable.
- An `@State var isExpanded: Bool` toggles between the two layouts; the surrounding frame animates with `.spring(response: 0.35, dampingFraction: 0.8)`.
- **Collapse triggers:** (a) click the pill while expanded, (b) a `leftMouseDown` event **outside the panel's frame** (observed via a global `NSEvent.addGlobalMonitorForEvents(.leftMouseDown)` — global, not local, because the event is outside the app's windows) sets `isExpanded = false`.
- When collapsed, the panel's frame shrinks to `restingSize`; clicks in region 2 (corner pixels) keep passing through. The pill itself remains the only hit area (region 1).

### 4.6 Fullscreen hiding

- Subscribe to `NSWorkspace.shared.notificationCenter` for `activeSpaceDidChange`.
- **Primary heuristic for "frontmost app is fullscreen":** the frontmost application owns a window whose entry in `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` has `kCGWindowLayer == 0` (normal layer), `kCGWindowAlpha > 0`, and a bounds that **fully covers** the menu-bar display's `NSScreen.frame`. If such a window exists, treat as fullscreen → hide.
- A window with `styleMask.contains(.fullScreen)` reported via `didEnterFullScreenNotification`/`didExitFullScreenNotification` is used as a *secondary signal* to react faster when the user enters/leaves a known fullscreen window; the `CGWindowList` cover test remains authoritative on each `activeSpaceDidChange`.
- When fullscreen is detected on the menu-bar display: `panel.orderOut(nil)` (hide). When it ends: `panel.orderFront(nil)` if the island is enabled and a notch is present.
- This is intentionally conservative; the safe failure mode is a false-positive "hide" (no island over a fullscreen app), not covering a fullscreen video.

### 4.7 Settings & menu integration

- New `@AppStorage` key: `settings.islandEnabled` (Bool, default `false`) in the shared `PulseSharedSettings.Keys`, stored in the existing app-group defaults so it's consistent across the app and (future) widget.
- **Settings window:** a new `GroupBox` "Dynamic Island" with a single `Toggle`, placed in the existing `PulseSettingsView` between the "Startup" and "Display" sections. A one-line status text shows "Notch detected" / "No notch on this Mac — island unavailable" so the user understands why it may not appear.
- **Menu bar menu:** a new `Toggle("Dynamic Island", isOn: …)` item immediately above the existing "Refresh Stats" action.
- The toggle is disabled (greyed, not checkable) when no notch is detected.

### 4.8 Data flow

```
SystemMonitor.shared.getStatsAndCache()
        │
        ▼
PulseStatsController (@Published stats)   ── existing, unchanged
        │
        ├──► MenuBarExtra label/menu       ── existing
        ├──► WidgetKit timeline           ── existing
        └──► DynamicIslandView            ── NEW (reads stats via @EnvironmentObject)
                    │
                    ▼
            DynamicIslandPanel (NSPanel shell)
```

`PulseStatsController` already refreshes on its timer and publishes `stats`; the island view observes it like the menu bar does. **No new polling, no new IOKit calls, no cache changes.**

## 5. Error handling & edge cases

| Case | Behavior |
|---|---|
| No notch present | Panel never created; toggle disabled in UI with explanatory status text. No error. |
| External display connected/disconnected | Re-evaluate notch on `didChangeScreenParameters`; the menu-bar display (`NSScreen.screens.first`) governs. Island stays anchored to that screen. |
| `islandEnabled` toggled off at runtime | `panel.orderOut` + release; `isExpanded` resets to false. |
| Stats are stale (`SystemStats.isStale`) | Show metrics as-is but with the same "Stale" affordance Pulse already uses elsewhere (small clock badge), inside the expanded view. |
| Expand clicked while app beneath would receive the click | `.nonactivatingPanel` ensures Pulse doesn't steal focus; click is consumed by the panel only over the pill rect. |
| Multiple displays in fullscreen simultaneously | Govern by the menu-bar display only; other displays' fullscreen state is ignored. |
| App quit | `deinit`/`applicationWillTerminate` calls `panel.orderOut`; ARC releases it. |

## 6. Testing

Following Pulse's existing pattern (`Tests/MacMonitorWidgetTests/SystemStatsMathTests.swift` extracts pure math for unit testing):

- **Unit-testable, pure-Swift logic** (in a `DynamicIsland` enum, mirroring `SystemStatsMath`):
  - `notchPresence(from auxiliaryTopLeftArea: safeAreaTop:) -> Bool` — the detection predicate.
  - `restingFrame` / `expandedFrame` given a screen's notch rect — pure functions of geometry.
  - The "is frontmost app fullscreen on this display?" decision, factored to take screen + window info structs so it's testable without a live AppKit context.
  - Metric formatting reuse (assert `DynamicIslandView` uses the same `PulseSettings.percent`/`formatSpeed` already covered).
- **Manual UI verification checklist** (documented in the spec, executed at implementation time): build on a notch Mac, confirm resting pill, click expands, outside click collapses, Settings toggle on/off, menu item on/off, fullscreen app hides it, disable when no notch (test by toggling the detection function to false).

UI/animation specifics are not unit-tested; they're verified manually per Pulse's current practice (no snapshot tests exist today).

## 7. Files changed

| File | Change |
|---|---|
| `Sources/DynamicIslandPanel.swift` | **NEW** — NSPanel shell, positioning, fullscreen detection. |
| `Sources/DynamicIslandView.swift` | **NEW** — SwiftUI resting + expanded layouts. |
| `Sources/SystemStats.swift` | Add `Keys.islandEnabled` to `PulseSharedSettings`; add `DynamicIslandMath` enum for the testable predicates. |
| `Sources/MacMonitorApp.swift` | Own panel lifecycle (create/orderOut on enable + notch presence), wire into `PulseStatsController`; add Settings `GroupBox` + menu `Toggle`; observe screen changes. |
| `Tests/MacMonitorWidgetTests/SystemStatsMathTests.swift` (or a new `DynamicIslandMathTests.swift`) | Tests for notch detection + frame math + fullscreen predicate. |
| `Pulse.xcodeproj` | Add the two new Swift files to the `MacMonitorApp` target (they are app-only, **not** the SPM library target — same as `MacMonitorApp.swift` is excluded from the package today). |
| `.gitignore` | Add `.superpowers/`. (Done.) |

The SPM `Package.swift` excludes app-only files already; the new files follow `MacMonitorApp.swift`'s precedent and must be added to the Xcode target, not the package.

## 8. Open questions / risks

- **Window level vs. Stage Manager / Spaces edge cases:** `.statusBar` level + `canJoinAllSpaces` covers the common cases; Stage Manager interactions are lightly tested. Conservative fullscreen-hiding mitigates the worst cases. Acceptable for v1.
- **Precise notch geometry** (matching exact notch width/height across 14" vs 16"): v1 derives height from `safeAreaInsets.top` and uses a resting pill of **~150pt wide × `safeAreaInsets.top` tall** (so the resting pill exactly fills the notch vertically and is comfortably narrower than the notch horizontally), and an expanded pill of **~240pt wide × ~150pt tall**. Per-model pixel-perfect sizing is later polish.
- **Click-outside-to-collapse monitor** must be removed on panel teardown to avoid leaks; covered in `DynamicIslandPanel` lifecycle.

## 9. Rejected alternatives

- **SwiftUI borderless `Window` scene:** gives no reliable control over window level, click-through, or ignoring Spaces; you end up in AppKit's `NSWindow` regardless. Rejected.
- **`MenuBarExtra`-based island:** `.menu` can't float free content; `.window` anchors a dropdown *below* the menu bar, not in the notch. Rejected.
- **Non-notch floating fallback:** explicitly out of scope per user decision; keeps v1 focused and the code simpler.

---

*This spec covers only the island shell + existing Pulse stats. Now Playing, timers, AirPods, and alerts are future iterations, each with their own spec.*
