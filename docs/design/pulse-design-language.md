# Pulse Design Language — "Quiet Instrument"

Pulse should feel like a utility Apple shipped alongside Activity Monitor: calm,
precise, native. It earns attention only when something is actually wrong.
The previous redesign failed because it decorated: rainbow gradient rings,
per-metric colors, colored titles, tinted badges, alarm icons, dashboard
cards. This document replaces that direction completely.

## Principles

1. **Monochrome first, one accent.** Text and chrome use only the system label
   hierarchy (`.primary`, `.secondary`, `.tertiary`, `.quaternary`) and system
   fills. Data marks (chart lines, gauge arcs, bar fills) use exactly one color:
   `Color.accentColor` (system blue by default; follows the user's accent).
   No per-metric colors. No gradients on marks — the only allowed gradient is a
   faint area fill under a line chart (accent at ≤ 14% fading to 0).
2. **Color means something — and goes on the mark, never the number.**
   Orange and red appear only when a value is genuinely high, and only on that
   value's *mark* (its bar, ring, history line, or the status dot) via
   `PulseStyle.markTint(for:)`. Numbers always stay in the primary label color
   (this also keeps light-mode contrast honest). Words that must carry severity
   (e.g. "High" in a Memory pressure row) use `PulseStyle.textTint(for:)`, the
   contrast-safe text variants. Battery marks follow Apple's battery semantics
   via `batteryMarkTint`: green normally and while charging, red at ≤ 20% when
   discharging, yellow in Low Power Mode. Never color headings, icons,
   backgrounds or whole rows. No warning relies on color alone: `PulseStatus`
   names every condition (headline + `detail`), and VoiceOver labels say it.
3. **Typography is the hierarchy.** SF Pro (never `.rounded` except inside the
   notch island and widgets where Apple uses SF Pro Rounded sparingly — prefer
   default). Hero numbers are large and *light*:
   `PulseStyle.heroNumber` (52pt, weight .light, monospaced digits) with the
   unit in `.secondary` at a smaller size. Labels use system text styles
   (`.headline`, `.subheadline`, `.callout`, `.caption`). **Never** uppercase,
   letter-spaced captions. **Never** hard-code a dozen ad-hoc sizes — use the
   tokens in `PulseStyle`.
4. **Native structure over invented chrome.** Main window = `NavigationSplitView`
   with a source-list sidebar. Detail panes read like System Settings: a header,
   one chart, then grouped detail rows with hairline separators. Settings use
   grouped `Form`s. Menus look like the system Battery/Wi-Fi menus. Use system
   materials and the default window background — no custom page colors.
5. **No badges, pills, capsules, emoji-like icons or alarm octagons.** Status is
   a sentence: “Memory pressure is high.” in `.secondary`, optionally preceded by
   a 6pt dot in the warning color.
6. **Generous whitespace, few lines.** Prefer spacing to borders. Separators are
   hairlines (`Divider()`), never boxes around boxes. Tiles, where used, are a
   very soft fill (`PulseStyle.tileFill`), 12pt continuous corners, no stroke,
   no shadow.
7. **Icons are monochrome SF Symbols** in `.secondary`, hierarchical rendering,
   never filled colored circles behind them.
8. **Motion is subtle.** Hero and tile numbers change in place (no rolling
   digits at 1 Hz); compact numbers may roll. Gentle easing only, no bouncy
   springs, no pulsing symbols, and everything honors Reduce Motion.
9. **Accessibility is part of taste.** Every value has an accessibility label;
   contrast holds in light and dark; nothing relies on color alone (warnings
   also change the status sentence).

## Tokens (implemented in `Sources/PulseDesign.swift`)

- `PulseStyle.accent` — `Color.accentColor`
- `PulseStyle.warning` — `.orange`, `PulseStyle.critical` — `.red`
- `PulseStyle.track` — `Color.primary.opacity(0.08)` (gauge/bar tracks)
- `PulseStyle.tileFill` — `Color.primary.opacity(0.035)`
- `PulseStyle.grid` — `Color.primary.opacity(0.08)` (chart gridlines)
- Type: `heroNumber`, `heroUnit`, `tileNumber`, `tileUnit`, `rowValue`
- Spacing: 4 / 8 / 12 / 16 / 24 / 32; page padding 28; corner radius 12

## Reusable components (in `PulseDesign.swift`)

- `ValueText(value:unit:style:)` — number + secondary unit, monospaced digits,
  numeric content transition, optional severity tint on the number only.
- `LineHistoryChart` — Swift Charts line in accent (1.5pt), faint area fill,
  fixed sliding window (new samples enter on the right), light gridlines,
  optional trailing y-axis labels in `.tertiary`.
- `UsageBar` — thin capsule (6pt) with accent fill on a `track`.
- `SegmentedBar` — capsule split into segments using accent at 100% / 60% / 35%
  and `track` for the remainder (System Settings Storage style, monochrome).
- `CapacityGauge` — Apple Batteries-widget-style circular ring: thin track,
  accent arc, monochrome SF Symbol in the center.
- `DetailRow(title:value:)` — label in `.secondary`, value trailing in
  `.primary` monospaced digits, 9pt vertical padding; stack with `Divider()`.
- `StatusLine(status:)` — the one-sentence system status.

## Surfaces

### Main window
- `NavigationSplitView`; sidebar sections: Overview, CPU, Memory, Storage,
  Network, Battery (if present). Sidebar rows: monochrome symbol + title +
  trailing current value in `.secondary` monospaced digits (like Mail counts).
- Toolbar: Refresh (⌘R) and Activity Monitor; nothing else.
- **Overview**: status sentence at top (`.title3`, secondary), then an adaptive
  grid of tiles (min 220pt): label (`.subheadline`, secondary), `tileNumber`,
  one-line detail (`.caption`, secondary), and a 32pt sparkline at the bottom.
  Clicking a tile selects that sidebar section.
- **Detail pages** (CPU, Memory, Storage, Network, Battery): header with
  `heroNumber` + one-line caption; one `LineHistoryChart` (~200pt) when the
  metric has history; then a grouped section of `DetailRow`s; then at most one
  bordered action button aligned trailing ("Open Activity Monitor…",
  "Manage Storage…", "Battery Settings…").

### Menu bar panel
Modeled on the macOS Battery / Wi-Fi menus: ~300pt wide, plain rows on the
system material. Section header “Pulse” in `.headline` with the status sentence
under it. Rows: CPU, Memory, Storage, Network, Battery — title left, value right
(monospaced, `.secondary` unit), each with the same thin `UsageBar` (no
sparkline — the menu stays even and quiet). A plain toggle row for the Notch Island. Then menu-style
action rows (hover highlight like a real menu): Open Pulse, Activity Monitor,
Settings…, Quit Pulse.

### Notch island
Pure black, white text, no color except: accent on thin arcs/bars, and
warning/critical on a value that is high. Resting ears: left — a tiny thin
single-color ring (CPU) ; right — the busiest metric’s percent in SF Pro
semibold white. Charging activity: left `bolt.fill` in green, right level in
green — the only time green appears. Expanded: three or four quiet rows (label ·
thin bar · value) and a footer line with network and battery in `.secondary`
white. No concentric rainbow rings.

### Widgets
Apple Batteries widget language. Small: 2×2 `CapacityGauge`s (CPU, Memory,
Storage, Battery) with percent under each. Medium: four gauges in a row with
label + percent. Large: gauges row, then rows (Memory, Storage, Network,
Battery) with thin bars, then a CPU sparkline-free per-core strip in accent.
Background: system widget background. All marks `.widgetAccentable()`.

### Settings
Keep grouped forms and the three tabs. Section icons in System Settings style
are allowed (that *is* native). Remove anything decorative beyond that.

### App icon
Graphite squircle, a single luminous pulse/line trace, subtle grid — elegant,
one accent hue at most. No rainbow rings.

## Behavior rules (from the round-2 review)
- **Ambient surfaces feature only live metrics.** The resting notch island and
  the menu-bar text show CPU, or Memory when its pressure is worse
  (`PressureSummary.ambient`). Storage is a slow capacity: it speaks through
  the status sentence, panels and widgets, never as a standing takeover.
- **Severity has hysteresis.** Levels rise after ~3 sustained samples and fall
  after ~8–12 (`SeverityLatch`), so colors and sentences never flicker.
- **History is never repainted.** Lines keep the accent; the current severity
  is a point on the latest sample (`latestTint`).
- **Memory marks show occupancy and stay accent** (`markSeverity`); memory
  *pressure* is said in words ("High pressure", the status sentence).
- **No fake readings.** A cold first sample (since-boot CPU, zero network) is
  never charted; widgets measure a fresh half-second.
- **One mark.** The app icon, the menu-bar glyph and the island's ear ring are
  the same open gauge (270°, open at the bottom), in the accent.

## One vocabulary, one meaning
- Names: **CPU, Memory, Storage, Network, Battery** everywhere (never RAM,
  Disk, MEM). The notch feature is the **Notch Island**.
- Compact figures (sidebar, menu, notch, widgets, menu bar): **percent used**
  for CPU, Memory and Storage; battery percent; network shows the busier
  direction with its arrow. Detail pages may lead with absolute amounts (GB
  used, GB available) but their captions state the shared percent too.
- Formats: `PulseFormat` only — one decimal below 100 GB ("6.1 GB"), whole
  numbers above, round capacities ("8 GB"), battery time "2:15 remaining",
  uptime "1d 16h".
- Casing: sentence case for labels, rows, popup items and buttons, as in
  System Settings ("Thermal state", "Open at login", "Busiest metric"); keep
  feature names capitalized ("Low Power Mode", "Notch Island"). Ellipses only
  on controls that need further input.

## Anti-patterns (reject in review)
Rainbow or per-metric colors · gradient arcs/bars · colored section titles ·
tinted capsules/badges · uppercase tracked captions · big alarm icons ·
custom page backgrounds · cards with borders + shadows + fills · more than one
accent hue on screen (excluding legitimate warning/critical values and
battery green) · a colored number next to an uncolored mark (or vice versa) ·
a permanent alarm glyph in the menu bar · controls that do nothing · decorative
SF Symbols in colored circles · bouncy/pulsing animations · dense dashboards
with competing focal points.
