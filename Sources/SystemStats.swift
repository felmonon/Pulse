import Foundation
import IOKit
import IOKit.ps
import AppKit
import Darwin

// MARK: - Load Severity
enum MemoryPressureLevel: Int, Codable {
    case normal = 1
    case warning = 2
    case critical = 4
}

/// Mirrors `ProcessInfo.ThermalState` in a Codable form the widget can share.
enum ThermalLevel: Int, Codable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var title: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        }
    }
}

/// Coarse classification of how loaded a metric is, used to tint rings and
/// give the widget a glanceable "is something under pressure?" signal.
enum LoadSeverity: Int, Comparable, Codable {
    case nominal = 0
    case moderate = 1
    case high = 2
    case critical = 3

    /// Maps a 0...1 utilization to a severity band.
    /// Thresholds: <50% nominal, <75% moderate, <90% high, otherwise critical.
    static func from(usage: Double) -> LoadSeverity {
        cpu(usage: usage)
    }

    static func cpu(usage: Double) -> LoadSeverity {
        let clamped = SystemStatsMath.unitInterval(usage)
        switch clamped {
        case ..<0.50: return .nominal
        case ..<0.75: return .moderate
        case ..<0.90: return .high
        default: return .critical
        }
    }

    /// RAM occupancy is not the same as memory pressure. Prefer the kernel's
    /// pressure signal and use conservative occupancy bands only as a fallback.
    static func memory(usage: Double, pressureLevel: MemoryPressureLevel?) -> LoadSeverity {
        switch pressureLevel {
        case .normal: return .nominal
        case .warning: return .high
        case .critical: return .critical
        case nil:
            let clamped = SystemStatsMath.unitInterval(usage)
            switch clamped {
            case ..<0.75: return .nominal
            case ..<0.85: return .moderate
            case ..<0.95: return .high
            default: return .critical
            }
        }
    }

    /// Storage stays usable at much higher occupancy than CPU or RAM.
    static func disk(usage: Double) -> LoadSeverity {
        let clamped = SystemStatsMath.unitInterval(usage)
        switch clamped {
        case ..<0.80: return .nominal
        case ..<0.90: return .moderate
        case ..<0.95: return .high
        default: return .critical
        }
    }

    static func < (lhs: LoadSeverity, rhs: LoadSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - System Statistics Model
struct SystemStats: Codable {
    var cpuUsage: Double
    var memoryUsage: Double
    var memoryUsed: Double // GB
    var memoryTotal: Double // GB
    var memoryPressureLevel: MemoryPressureLevel? = nil
    var diskUsage: Double
    var diskUsed: Double // GB
    var diskTotal: Double // GB
    var diskAvailable: Double // GB
    var diskPurgeable: Double // GB
    var batteryLevel: Int
    var isCharging: Bool
    var hasBattery: Bool
    var networkUp: Double // KB/s
    var networkDown: Double // KB/s
    var activeApps: [String]
    var timestamp: Date

    // Activity Monitor–style detail. Defaulted so older call sites and the
    // placeholder keep compiling without spelling every field out.
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cpuCoreUsage: [Double] = []
    var memoryApp: Double = 0 // GB
    var memoryWired: Double = 0 // GB
    var memoryCompressed: Double = 0 // GB
    var memoryCached: Double = 0 // GB
    var swapUsed: Double = 0 // GB
    var isPluggedIn: Bool = false
    var batteryMinutesRemaining: Int? = nil
    var thermalLevel: ThermalLevel = .nominal
    var uptime: TimeInterval = 0
    /// False for a process's first reading, which has no previous counters:
    /// its CPU is the since-boot average and its network rate is zero. Such a
    /// sample is shown only until a real delta exists and is never charted.
    var isWarmSample: Bool = true
    /// Severities after hysteresis (see `SystemStatsMath.SeverityLatch`).
    /// When set, every surface reads these so colors and wording change
    /// together and never flicker on a single noisy sample.
    var latchedCPUSeverity: LoadSeverity? = nil
    var latchedMemorySeverity: LoadSeverity? = nil
    var latchedDiskSeverity: LoadSeverity? = nil

    var isStale: Bool {
        Date().timeIntervalSince(timestamp) > 120
    }

    var cpuSeverity: LoadSeverity {
        latchedCPUSeverity ?? .cpu(usage: cpuUsage)
    }

    var memorySeverity: LoadSeverity {
        latchedMemorySeverity ?? .memory(usage: memoryUsage, pressureLevel: memoryPressureLevel)
    }

    var diskSeverity: LoadSeverity {
        latchedDiskSeverity ?? .disk(usage: diskUsage)
    }

    /// Raw, per-sample severities (input to the latches).
    var rawCPUSeverity: LoadSeverity { .cpu(usage: cpuUsage) }
    var rawMemorySeverity: LoadSeverity { .memory(usage: memoryUsage, pressureLevel: memoryPressureLevel) }
    var rawDiskSeverity: LoadSeverity { .disk(usage: diskUsage) }

    static var placeholder: SystemStats {
        SystemStats(
            cpuUsage: 0.45,
            memoryUsage: 0.62,
            memoryUsed: 10.2,
            memoryTotal: 16.0,
            memoryPressureLevel: .normal,
            diskUsage: 0.58,
            diskUsed: 234.5,
            diskTotal: 512.0,
            diskAvailable: 277.5,
            diskPurgeable: 0,
            batteryLevel: 78,
            isCharging: true,
            hasBattery: true,
            networkUp: 125.4,
            networkDown: 892.1,
            activeApps: ["Safari", "Xcode", "Slack"],
            timestamp: Date(),
            cpuUser: 0.31,
            cpuSystem: 0.14,
            cpuCoreUsage: [0.72, 0.64, 0.58, 0.41, 0.33, 0.28, 0.22, 0.18, 0.12, 0.09],
            memoryApp: 6.4,
            memoryWired: 2.3,
            memoryCompressed: 1.5,
            memoryCached: 3.9,
            swapUsed: 0,
            isPluggedIn: true,
            batteryMinutesRemaining: 48,
            thermalLevel: .nominal,
            uptime: 273_600
        )
    }
}

// MARK: - Shared Defaults
enum PulseSharedDefaults {
    static let appGroupID = "group.com.macmonitor.widget.shared"
    static let legacySuiteName = "com.macmonitor.widget.shared"
    private static let settingKeys = [
        "settings.launchAtLogin",
        "settings.refreshInterval",
        "settings.unitsMode",
        "settings.showBattery",
        "settings.showDisk",
        "settings.showNetwork",
        "settings.islandEnabled",
        "settings.islandChargingActivity",
        "settings.menuBarStyle"
    ]

    static let defaults: UserDefaults = {
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ), let groupDefaults = UserDefaults(suiteName: appGroupID) {
            let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
            let probeURL = containerURL.appendingPathComponent(".pulse-access-\(bundleID)")

            do {
                try Data().write(to: probeURL, options: .atomic)
                try? FileManager.default.removeItem(at: probeURL)
                copyMissingSettings(from: .standard, to: groupDefaults)
                copyMissingSettings(
                    from: UserDefaults(suiteName: legacySuiteName),
                    to: groupDefaults
                )
                return groupDefaults
            } catch {
                // The installed profile may not authorize App Groups yet.
            }
        }

        let localDefaults = UserDefaults.standard
        copyMissingSettings(
            from: UserDefaults(suiteName: legacySuiteName),
            to: localDefaults
        )
        return localDefaults
    }()

    private static func copyMissingSettings(
        from source: UserDefaults?,
        to destination: UserDefaults
    ) {
        guard let source else { return }

        for key in settingKeys where destination.object(forKey: key) == nil {
            if let value = source.object(forKey: key) {
                destination.set(value, forKey: key)
            }
        }
    }
}

// MARK: - Shared Display Settings
enum PulseSharedSettings {
    static let defaults = PulseSharedDefaults.defaults
    static let defaultRefreshInterval: TimeInterval = 1
    static let refreshIntervals: [TimeInterval] = [1, 5, 15, 30, 60]

    enum Keys {
        static let launchAtLogin = "settings.launchAtLogin"
        static let refreshInterval = "settings.refreshInterval"
        static let unitsMode = "settings.unitsMode"
        static let showBattery = "settings.showBattery"
        static let showDisk = "settings.showDisk"
        static let showNetwork = "settings.showNetwork"
        static let islandEnabled = "settings.islandEnabled"
        static let islandChargingActivity = "settings.islandChargingActivity"
        static let menuBarStyle = "settings.menuBarStyle"
    }

    /// What the menu-bar item shows next to its glyph.
    enum MenuBarStyle: String, CaseIterable, Identifiable {
        case iconOnly = "icon"
        case busiest = "busiest"
        case cpuAndMemory = "cpuMemory"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .iconOnly: return "Icon only"
            case .busiest: return "Busiest metric"
            case .cpuAndMemory: return "CPU and memory"
            }
        }
    }

    enum UnitsMode: String, CaseIterable, Identifiable {
        case automatic = "auto"
        case kilobytesPerSecond = "kbps"
        case megabytesPerSecond = "mbps"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: return "Auto"
            case .kilobytesPerSecond: return "KB/s"
            case .megabytesPerSecond: return "MB/s"
            }
        }
    }

    static var storedRefreshInterval: TimeInterval {
        let value = defaults.object(forKey: Keys.refreshInterval) as? TimeInterval
        return clampedRefreshInterval(value ?? defaultRefreshInterval)
    }

    static func clampedRefreshInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultRefreshInterval }
        return min(max(value, 1), 60)
    }

    static func intervalLabel(_ interval: TimeInterval) -> String {
        String(format: "%.0fs", interval)
    }

    /// Settings-style phrasing: "Every second", "Every 5 seconds".
    static func intervalDescription(_ interval: TimeInterval) -> String {
        let seconds = Int(clampedRefreshInterval(interval).rounded())
        switch seconds {
        case 1: return "Every second"
        case 60: return "Every minute"
        default: return "Every \(seconds) seconds"
        }
    }

    /// Compact uptime like "3d 4h", "5h 12m" or "8m".
    static func formatUptime(_ uptime: TimeInterval) -> String {
        guard uptime.isFinite, uptime > 0 else { return "—" }
        let totalMinutes = Int(uptime / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Battery-menu phrasing: "2:05".
    static func formatBatteryTime(minutes: Int) -> String {
        let clamped = max(minutes, 0)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((SystemStatsMath.unitInterval(value) * 100).rounded()))%"
    }

    /// Formats a gibibyte (GiB) value as a compact, human-readable string.
    /// Used everywhere storage/memory appears so the unit is always GB and
    /// the precision scales sensibly with magnitude (234 GB, not 234.5 GB).
    static func formatGigabytes(_ value: Double) -> String {
        guard value.isFinite else { return "0.0 GB" }
        let clamped = max(value, 0)
        if clamped >= 100 {
            return String(format: "%.0f GB", clamped)
        }
        // One decimal keeps live values steady in the last digit and matches
        // across the window, menu, notch and widgets.
        return String(format: "%.1f GB", clamped)
    }

    static func formatSpeed(_ speed: Double, unitsMode: UnitsMode) -> String {
        let speed = SystemStatsMath.sanitizeSpeed(speed)
        switch unitsMode {
        case .automatic:
            // Switch before a value would need four KB digits ("1006 KB/s"),
            // so every rate is at most "999 KB/s" or "9.9 MB/s" wide.
            if speed >= 999.5 {
                return formatMegabytes(speed / 1024)
            }
            return String(format: "%.0f KB/s", speed)
        case .kilobytesPerSecond:
            return "\(groupedInteger(speed)) KB/s"
        case .megabytesPerSecond:
            return formatMegabytes(speed / 1024)
        }
    }

    private static let groupingFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        return formatter
    }()

    private static func groupedInteger(_ value: Double) -> String {
        groupingFormatter.string(from: NSNumber(value: value.rounded())) ?? String(format: "%.0f", value)
    }

    private static func formatMegabytes(_ value: Double) -> String {
        if value >= 10 {
            return String(format: "%.0f MB/s", value)
        }

        return String(format: "%.1f MB/s", value)
    }
}

// MARK: - Testable Math
enum SystemStatsMath {
    struct CPUCounters: Equatable {
        let used: UInt64
        let total: UInt64
    }

    struct NetworkInterfaceCounters: Equatable {
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    struct NetworkCounters: Equatable {
        let interfaces: [String: NetworkInterfaceCounters]
        let date: Date
    }

    struct DiskUsage: Equatable {
        let percentage: Double
        let usedBytes: Double
        let totalBytes: Double
        let availableBytes: Double
        let purgeableBytes: Double
    }

    /// Raw scheduler ticks for one logical core.
    struct CPUCoreTicks: Equatable {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        var used: UInt64 { user + system + nice }
        var total: UInt64 { used + idle }
    }

    /// Utilization split the way Activity Monitor reports it.
    struct CPUBreakdown: Equatable {
        let total: Double
        let user: Double
        let system: Double
        let cores: [Double]
    }

    /// Memory split the way Activity Monitor reports it. "Used" is App +
    /// Wired + Compressed; cached files are reclaimable and not counted.
    struct MemoryBreakdown: Equatable {
        let totalBytes: Double
        let usedBytes: Double
        let appBytes: Double
        let wiredBytes: Double
        let compressedBytes: Double
        let cachedBytes: Double

        var usage: Double {
            totalBytes > 0 ? SystemStatsMath.unitInterval(usedBytes / totalBytes) : 0
        }

        static let empty = MemoryBreakdown(
            totalBytes: 0,
            usedBytes: 0,
            appBytes: 0,
            wiredBytes: 0,
            compressedBytes: 0,
            cachedBytes: 0
        )
    }

    static func cpuUsage(previous: CPUCounters?, current: CPUCounters) -> Double {
        guard current.total > 0 else {
            return 0
        }

        guard let previous,
              current.total >= previous.total,
              current.used >= previous.used else {
            return clamp(Double(current.used) / Double(current.total))
        }

        let totalDelta = current.total - previous.total
        guard totalDelta > 0 else {
            return 0
        }

        let usedDelta = current.used - previous.used
        return clamp(Double(usedDelta) / Double(totalDelta))
    }

    /// Clamps utilization-like values to 0...1 and treats non-finite samples as
    /// empty so display code can safely convert them to percentages.
    static func unitInterval(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// APFS can reclaim purgeable space on demand. Treat that capacity as
    /// available so Pulse agrees with macOS Storage instead of reporting only
    /// the container's immediately unallocated bytes.
    static func diskUsage(
        totalBytes: Double,
        freeBytes: Double,
        importantAvailableBytes: Double
    ) -> DiskUsage {
        guard totalBytes.isFinite, totalBytes > 0 else {
            return DiskUsage(
                percentage: 0,
                usedBytes: 0,
                totalBytes: 0,
                availableBytes: 0,
                purgeableBytes: 0
            )
        }

        let hardFree = freeBytes.isFinite
            ? min(max(freeBytes, 0), totalBytes)
            : 0
        let importantAvailable = importantAvailableBytes.isFinite
            ? min(max(importantAvailableBytes, 0), totalBytes)
            : hardFree
        let available = max(hardFree, importantAvailable)
        let used = totalBytes - available

        return DiskUsage(
            percentage: unitInterval(used / totalBytes),
            usedBytes: used,
            totalBytes: totalBytes,
            availableBytes: available,
            purgeableBytes: available - hardFree
        )
    }

    static func networkSpeed(
        previous: NetworkCounters?,
        current: NetworkCounters,
        minimumInterval: TimeInterval = 0.2
    ) -> (up: Double, down: Double) {
        guard let previous else {
            return (0, 0)
        }

        let timeDiff = current.date.timeIntervalSince(previous.date)
        guard timeDiff > minimumInterval else {
            return (0, 0)
        }

        var bytesInDelta: UInt64 = 0
        var bytesOutDelta: UInt64 = 0

        for (name, currentCounters) in current.interfaces {
            guard let previousCounters = previous.interfaces[name],
                  currentCounters.bytesIn >= previousCounters.bytesIn,
                  currentCounters.bytesOut >= previousCounters.bytesOut else {
                continue
            }

            bytesInDelta += currentCounters.bytesIn - previousCounters.bytesIn
            bytesOutDelta += currentCounters.bytesOut - previousCounters.bytesOut
        }

        return (
            up: Double(bytesOutDelta) / timeDiff / 1024,
            down: Double(bytesInDelta) / timeDiff / 1024
        )
    }

    /// Exponential moving average for smoothing a noisy series (e.g. CPU %).
    /// `previous` is nil on the first sample, in which case the current value
    /// seeds the series. `alpha` in 0...1 is the weight given to the new
    /// sample; smaller = smoother but more lag. Never returns NaN.
    static func smoothed(previous: Double?, current: Double, alpha: Double) -> Double {
        let a = min(max(alpha, 0), 1)
        guard let previous, previous.isFinite else {
            return current.isFinite ? current : 0
        }
        guard current.isFinite else {
            return previous
        }
        return previous + (current - previous) * a
    }

    /// Normalizes a raw network speed (KB/s) so transient spikes from sampling
    /// jitter, interface resets, or absurd values can't break the display.
    static func sanitizeSpeed(_ speed: Double) -> Double {
        let maxDisplayableSpeed: Double = 10_000_000
        guard speed.isFinite, speed > 0 else { return 0 }
        return min(speed, maxDisplayableSpeed)
    }

    /// Per-core and user/system utilization from two tick samples. A core
    /// whose counters went backwards (or a changed core count) falls back to
    /// its cumulative ticks, matching `cpuUsage(previous:current:)`.
    static func cpuBreakdown(previous: [CPUCoreTicks]?, current: [CPUCoreTicks]) -> CPUBreakdown {
        let comparable = previous.map { $0.count == current.count } ?? false
        var userDelta: UInt64 = 0
        var systemDelta: UInt64 = 0
        var totalDelta: UInt64 = 0
        var cores: [Double] = []
        cores.reserveCapacity(current.count)

        for (index, core) in current.enumerated() {
            var delta = core
            if comparable, let earlier = previous?[index],
               core.user >= earlier.user,
               core.system >= earlier.system,
               core.idle >= earlier.idle,
               core.nice >= earlier.nice {
                delta = CPUCoreTicks(
                    user: core.user - earlier.user,
                    system: core.system - earlier.system,
                    idle: core.idle - earlier.idle,
                    nice: core.nice - earlier.nice
                )
            }

            userDelta += delta.user + delta.nice
            systemDelta += delta.system
            totalDelta += delta.total
            cores.append(delta.total > 0 ? unitInterval(Double(delta.used) / Double(delta.total)) : 0)
        }

        guard totalDelta > 0 else {
            return CPUBreakdown(total: 0, user: 0, system: 0, cores: cores)
        }

        let user = unitInterval(Double(userDelta) / Double(totalDelta))
        let system = unitInterval(Double(systemDelta) / Double(totalDelta))
        return CPUBreakdown(total: unitInterval(user + system), user: user, system: system, cores: cores)
    }

    static func memoryBreakdown(
        totalBytes: Double,
        pageSize: Double,
        internalPages: UInt64,
        purgeablePages: UInt64,
        externalPages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64
    ) -> MemoryBreakdown {
        guard totalBytes.isFinite, totalBytes > 0, pageSize.isFinite, pageSize > 0 else {
            return .empty
        }

        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let app = Double(appPages) * pageSize
        let wired = Double(wiredPages) * pageSize
        let compressed = Double(compressorPages) * pageSize
        let used = min(app + wired + compressed, totalBytes)
        let cached = min(Double(externalPages + purgeablePages) * pageSize, totalBytes - used)

        return MemoryBreakdown(
            totalBytes: totalBytes,
            usedBytes: used,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: max(cached, 0)
        )
    }

    /// IOKit reports -1 while it is still estimating; only surface a time
    /// when the relevant estimate is real.
    static func batteryMinutes(
        isCharging: Bool,
        isPluggedIn: Bool,
        timeToEmpty: Int?,
        timeToFull: Int?
    ) -> Int? {
        if isCharging {
            guard let timeToFull, timeToFull > 0 else { return nil }
            return timeToFull
        }
        guard !isPluggedIn, let timeToEmpty, timeToEmpty > 0 else { return nil }
        return timeToEmpty
    }

    private static func clamp(_ value: Double) -> Double {
        unitInterval(value)
    }

    /// Hysteresis for severities sampled every second. A higher level takes
    /// effect only after it has held for `enterSamples` consecutive samples;
    /// a lower one only after `exitSamples`. One noisy sample never changes a
    /// color or a sentence.
    struct SeverityLatch: Equatable {
        let enterSamples: Int
        let exitSamples: Int
        private(set) var current: LoadSeverity = .nominal
        private var candidate: LoadSeverity = .nominal
        private var streak = 0
        private var primed = false

        init(enterSamples: Int, exitSamples: Int) {
            self.enterSamples = max(enterSamples, 1)
            self.exitSamples = max(exitSamples, 1)
        }

        mutating func update(_ raw: LoadSeverity) -> LoadSeverity {
            // The very first reading is adopted directly, so a Mac that is
            // already under load (or a full disk) reads correctly at launch.
            guard primed else {
                primed = true
                current = raw
                candidate = raw
                return current
            }
            guard raw != current else {
                streak = 0
                candidate = current
                return current
            }
            if raw == candidate {
                streak += 1
            } else {
                candidate = raw
                streak = 1
            }
            let needed = raw > current ? enterSamples : exitSamples
            if streak >= needed {
                current = raw
                streak = 0
            }
            return current
        }
    }
}

// MARK: - Metric History
/// A rolling window of recent samples that drives the live charts. Samples
/// carry a monotonically increasing id so charts can plot by position.
struct MetricSample: Identifiable, Equatable {
    let id: Int
    let cpu: Double
    let memory: Double
    let networkUp: Double
    let networkDown: Double
}

struct MetricHistory: Equatable {
    let capacity: Int
    private(set) var samples: [MetricSample] = []
    private var nextID = 0

    init(capacity: Int = 90) {
        self.capacity = max(capacity, 2)
    }

    mutating func append(cpu: Double, memory: Double, networkUp: Double, networkDown: Double) {
        samples.append(
            MetricSample(
                id: nextID,
                cpu: SystemStatsMath.unitInterval(cpu),
                memory: SystemStatsMath.unitInterval(memory),
                networkUp: SystemStatsMath.sanitizeSpeed(networkUp),
                networkDown: SystemStatsMath.sanitizeSpeed(networkDown)
            )
        )
        nextID += 1
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// Drop every sample, e.g. when the sampling cadence changes so the
    /// chart's time span stays honest.
    mutating func removeAll() {
        samples.removeAll()
    }

    mutating func append(_ stats: SystemStats) {
        append(
            cpu: stats.cpuUsage,
            memory: stats.memoryUsage,
            networkUp: stats.networkUp,
            networkDown: stats.networkDown
        )
    }

    /// A deterministic, realistic-looking window for previews and screenshots.
    static func preview(capacity: Int = 90) -> MetricHistory {
        var history = MetricHistory(capacity: capacity)
        for step in 0..<capacity {
            let t = Double(step)
            let cpu = 0.22 + 0.10 * sin(t / 7) + 0.06 * sin(t / 2.3) + (step % 23 == 0 ? 0.25 : 0)
            let memory = 0.71 + 0.03 * sin(t / 19)
            let down = max(40 + 900 * pow(max(sin(t / 9), 0), 6) + 30 * sin(t / 1.7), 0)
            let up = max(12 + 60 * pow(max(sin(t / 13 + 1), 0), 4), 0)
            history.append(cpu: cpu, memory: memory, networkUp: up, networkDown: down)
        }
        return history
    }

    /// Highest combined network speed in the window, floored so a quiet link
    /// still draws a flat line rather than a scaled-up noise floor.
    var networkCeiling: Double {
        let peak = samples.map { max($0.networkUp, $0.networkDown) }.max() ?? 0
        return max(peak * 1.15, 64)
    }
}

// MARK: - Static Machine Info
enum MachineInfo {
    static let chipName: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else {
            return "Apple silicon"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return "Apple silicon"
        }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Apple silicon" : name
    }()

    static let coreCount = ProcessInfo.processInfo.activeProcessorCount

    /// Logical CPU counts per cluster on Apple silicon (perflevel0 is the
    /// performance cluster, perflevel1 efficiency). Nil when unavailable or
    /// when they don't add up to the core count.
    static let coreClusters: (performance: Int, efficiency: Int)? = {
        func count(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
            return Int(value)
        }
        guard let performance = count("hw.perflevel0.logicalcpu"),
              let efficiency = count("hw.perflevel1.logicalcpu"),
              performance + efficiency == ProcessInfo.processInfo.activeProcessorCount else {
            return nil
        }
        return (performance, efficiency)
    }()

    static let osVersion: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.patchVersion > 0
            ? "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "macOS \(version.majorVersion).\(version.minorVersion)"
    }()
}

// MARK: - System Monitor
class SystemMonitor {
    static let shared = SystemMonitor()

    private let samplingLock = NSLock()
    private var previousCPUTicks: [SystemStatsMath.CPUCoreTicks]?
    private var previousNetworkCounters: SystemStatsMath.NetworkCounters?

    // EMA-smoothed display values. Raw CPU deltas between two samples are
    // jumpy; smoothing with a light alpha keeps the ring from flickering
    // every tick while still tracking real changes quickly.
    private static let cpuSmoothingAlpha: Double = 0.4
    private static let networkSmoothingAlpha: Double = 0.5
    private var smoothedCPU: Double?
    private var smoothedCPUUser: Double?
    private var smoothedCPUSystem: Double?
    private var smoothedCores: [Double] = []
    private var smoothedNetworkUp: Double?
    private var smoothedNetworkDown: Double?

    /// Forget counters and smoothing so the next reading starts fresh. Used
    /// by short-lived processes (the widget extension) whose last baseline may
    /// be minutes old.
    func resetBaseline() {
        samplingLock.lock()
        defer { samplingLock.unlock() }
        previousCPUTicks = nil
        previousNetworkCounters = nil
        smoothedCPU = nil
        smoothedCPUUser = nil
        smoothedCPUSystem = nil
        smoothedCores = []
        smoothedNetworkUp = nil
        smoothedNetworkDown = nil
    }

    /// A reading over a short, fresh interval: primes the counters, waits,
    /// then samples, so CPU and network reflect the last half-second rather
    /// than the since-boot average or a stale baseline.
    func freshStats(interval: TimeInterval = 0.5, completion: @escaping (SystemStats) -> Void) {
        resetBaseline()
        _ = getStats()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval) {
            completion(self.getStats())
        }
    }

    func getStats() -> SystemStats {
        samplingLock.lock()
        defer { samplingLock.unlock() }

        // A process's first reading has no previous counters: CPU would be the
        // since-boot average and network zero. Flag it and keep it out of the
        // smoothing so it never biases the readings that follow.
        let isWarm = previousCPUTicks != nil && previousNetworkCounters != nil

        // Keep every field in this snapshot on the same serialized sample.
        let memory = getMemoryUsage()
        let disk = getDiskUsage()
        let battery = getBatteryLevel()
        let network = getNetworkSpeed()

        let breakdown = getCPUBreakdown()
        guard isWarm else {
            return makeStats(
                cpu: breakdown.total, cpuUser: breakdown.user, cpuSystem: breakdown.system,
                cores: breakdown.cores, netUp: 0, netDown: 0,
                memory: memory, disk: disk, battery: battery, isWarm: false
            )
        }
        let alpha = SystemMonitor.cpuSmoothingAlpha
        let cpu = SystemStatsMath.smoothed(previous: smoothedCPU, current: breakdown.total, alpha: alpha)
        let cpuUser = SystemStatsMath.smoothed(previous: smoothedCPUUser, current: breakdown.user, alpha: alpha)
        let cpuSystem = SystemStatsMath.smoothed(previous: smoothedCPUSystem, current: breakdown.system, alpha: alpha)
        smoothedCPU = cpu
        smoothedCPUUser = cpuUser
        smoothedCPUSystem = cpuSystem

        if smoothedCores.count == breakdown.cores.count {
            smoothedCores = zip(smoothedCores, breakdown.cores).map {
                SystemStatsMath.smoothed(previous: $0, current: $1, alpha: alpha)
            }
        } else {
            smoothedCores = breakdown.cores
        }

        let netUp = SystemStatsMath.smoothed(
            previous: smoothedNetworkUp,
            current: SystemStatsMath.sanitizeSpeed(network.up),
            alpha: SystemMonitor.networkSmoothingAlpha
        )
        let netDown = SystemStatsMath.smoothed(
            previous: smoothedNetworkDown,
            current: SystemStatsMath.sanitizeSpeed(network.down),
            alpha: SystemMonitor.networkSmoothingAlpha
        )
        smoothedNetworkUp = netUp
        smoothedNetworkDown = netDown

        return makeStats(
            cpu: cpu, cpuUser: cpuUser, cpuSystem: cpuSystem,
            cores: smoothedCores, netUp: netUp, netDown: netDown,
            memory: memory, disk: disk, battery: battery, isWarm: true
        )
    }

    private func makeStats(
        cpu: Double, cpuUser: Double, cpuSystem: Double, cores: [Double],
        netUp: Double, netDown: Double,
        memory: (breakdown: SystemStatsMath.MemoryBreakdown, swapBytes: Double, pressureLevel: MemoryPressureLevel?),
        disk: (percentage: Double, used: Double, total: Double, available: Double, purgeable: Double),
        battery: (level: Int, isCharging: Bool, hasBattery: Bool, isPluggedIn: Bool, minutesRemaining: Int?),
        isWarm: Bool
    ) -> SystemStats {
        let gigabyte = 1_073_741_824.0

        return SystemStats(
            cpuUsage: cpu,
            memoryUsage: memory.breakdown.usage,
            memoryUsed: memory.breakdown.usedBytes / gigabyte,
            memoryTotal: memory.breakdown.totalBytes / gigabyte,
            memoryPressureLevel: memory.pressureLevel,
            diskUsage: disk.percentage,
            diskUsed: disk.used,
            diskTotal: disk.total,
            diskAvailable: disk.available,
            diskPurgeable: disk.purgeable,
            batteryLevel: battery.level,
            isCharging: battery.isCharging,
            hasBattery: battery.hasBattery,
            networkUp: netUp,
            networkDown: netDown,
            activeApps: getActiveApps(),
            timestamp: Date(),
            cpuUser: cpuUser,
            cpuSystem: cpuSystem,
            cpuCoreUsage: cores,
            memoryApp: memory.breakdown.appBytes / gigabyte,
            memoryWired: memory.breakdown.wiredBytes / gigabyte,
            memoryCompressed: memory.breakdown.compressedBytes / gigabyte,
            memoryCached: memory.breakdown.cachedBytes / gigabyte,
            swapUsed: memory.swapBytes / gigabyte,
            isPluggedIn: battery.isPluggedIn,
            batteryMinutesRemaining: battery.minutesRemaining,
            thermalLevel: ThermalLevel(ProcessInfo.processInfo.thermalState),
            uptime: ProcessInfo.processInfo.systemUptime,
            isWarmSample: isWarm
        )
    }

    // MARK: - CPU Usage
    private func getCPUBreakdown() -> SystemStatsMath.CPUBreakdown {
        guard let current = getCPUTicks(), !current.isEmpty else {
            return SystemStatsMath.CPUBreakdown(total: 0, user: 0, system: 0, cores: [])
        }

        defer {
            previousCPUTicks = current
        }

        return SystemStatsMath.cpuBreakdown(previous: previousCPUTicks, current: current)
    }

    private func getCPUTicks() -> [SystemStatsMath.CPUCoreTicks]? {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let err = host_processor_info(mach_host_self(),
                                       PROCESSOR_CPU_LOAD_INFO,
                                       &numCPUs,
                                       &cpuInfo,
                                       &numCpuInfo)

        guard err == KERN_SUCCESS, let info = cpuInfo, numCPUs > 0 else {
            return nil
        }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        var cores: [SystemStatsMath.CPUCoreTicks] = []
        cores.reserveCapacity(Int(numCPUs))

        // Ticks are unsigned counters stored in signed slots; reinterpret the
        // bits so a long-running Mac never reads a wrapped counter as zero.
        func ticks(_ value: integer_t) -> UInt64 {
            UInt64(UInt32(bitPattern: value))
        }

        for i in 0..<Int(numCPUs) {
            let offset = Int(CPU_STATE_MAX) * i
            cores.append(
                SystemStatsMath.CPUCoreTicks(
                    user: ticks(info[offset + Int(CPU_STATE_USER)]),
                    system: ticks(info[offset + Int(CPU_STATE_SYSTEM)]),
                    idle: ticks(info[offset + Int(CPU_STATE_IDLE)]),
                    nice: ticks(info[offset + Int(CPU_STATE_NICE)])
                )
            )
        }

        return cores
    }

    // MARK: - Memory Usage
    private func getMemoryUsage() -> (
        breakdown: SystemStatsMath.MemoryBreakdown,
        swapBytes: Double,
        pressureLevel: MemoryPressureLevel?
    ) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return (.empty, getSwapUsedBytes(), getMemoryPressureLevel())
        }

        let breakdown = SystemStatsMath.memoryBreakdown(
            totalBytes: Double(ProcessInfo.processInfo.physicalMemory),
            pageSize: Double(vm_kernel_page_size),
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            externalPages: UInt64(stats.external_page_count),
            wiredPages: UInt64(stats.wire_count),
            compressorPages: UInt64(stats.compressor_page_count)
        )

        return (breakdown, getSwapUsedBytes(), getMemoryPressureLevel())
    }

    private func getSwapUsedBytes() -> Double {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return 0
        }
        return Double(usage.xsu_used)
    }

    private func getMemoryPressureLevel() -> MemoryPressureLevel? {
        var rawLevel: Int32 = 0
        var size = MemoryLayout<Int32>.size

        guard sysctlbyname(
            "kern.memorystatus_vm_pressure_level",
            &rawLevel,
            &size,
            nil,
            0
        ) == 0 else {
            return nil
        }

        return MemoryPressureLevel(rawValue: Int(rawLevel))
    }

    // MARK: - Disk Usage
    private func getDiskUsage() -> (percentage: Double, used: Double, total: Double, available: Double, purgeable: Double) {
        do {
            let fileURL = URL(fileURLWithPath: "/")
            let values = try fileURL.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])

            if let total = values.volumeTotalCapacity {
                let freeBytes = Double(values.volumeAvailableCapacity ?? 0)
                let importantAvailableBytes = values.volumeAvailableCapacityForImportantUsage.map(Double.init) ?? freeBytes
                let usage = SystemStatsMath.diskUsage(
                    totalBytes: Double(total),
                    freeBytes: freeBytes,
                    importantAvailableBytes: importantAvailableBytes
                )
                let bytesPerGigabyte = 1_000_000_000.0
                return (
                    usage.percentage,
                    usage.usedBytes / bytesPerGigabyte,
                    usage.totalBytes / bytesPerGigabyte,
                    usage.availableBytes / bytesPerGigabyte,
                    usage.purgeableBytes / bytesPerGigabyte
                )
            }
        } catch {}

        return (0, 0, 0, 0, 0)
    }

    // MARK: - Battery
    private func getBatteryLevel() -> (
        level: Int,
        isCharging: Bool,
        hasBattery: Bool,
        isPluggedIn: Bool,
        minutesRemaining: Int?
    ) {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

        for source in sources {
            if let info = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                if let capacity = info[kIOPSCurrentCapacityKey] as? Int,
                   let isCharging = info[kIOPSIsChargingKey] as? Bool {
                    let isPluggedIn = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                    let minutes = SystemStatsMath.batteryMinutes(
                        isCharging: isCharging,
                        isPluggedIn: isPluggedIn,
                        timeToEmpty: info[kIOPSTimeToEmptyKey] as? Int,
                        timeToFull: info[kIOPSTimeToFullChargeKey] as? Int
                    )
                    return (capacity, isCharging, true, isPluggedIn, minutes)
                }
            }
        }

        // Desktop Macs have no battery and are always on AC power.
        return (0, false, false, true, nil)
    }

    // MARK: - Network Speed
    private func getNetworkSpeed() -> (up: Double, down: Double) {
        guard let current = getNetworkCounters() else {
            return (0, 0)
        }

        defer {
            previousNetworkCounters = current
        }

        return SystemStatsMath.networkSpeed(previous: previousNetworkCounters, current: current)
    }

    private func getNetworkCounters() -> SystemStatsMath.NetworkCounters? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var interfaces: [String: SystemStatsMath.NetworkInterfaceCounters] = [:]

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let currentPtr = ptr {
            defer {
                ptr = currentPtr.pointee.ifa_next
            }

            let interface = currentPtr.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_LINK) else {
                continue
            }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            guard !name.hasPrefix("awdl"),
                  !name.hasPrefix("llw"),
                  !name.hasPrefix("utun"),
                  !name.hasPrefix("gif"),
                  !name.hasPrefix("stf") else {
                continue
            }

            if let data = interface.ifa_data {
                let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                let existing = interfaces[name] ?? SystemStatsMath.NetworkInterfaceCounters(bytesIn: 0, bytesOut: 0)
                interfaces[name] = SystemStatsMath.NetworkInterfaceCounters(
                    bytesIn: existing.bytesIn + UInt64(networkData.ifi_ibytes),
                    bytesOut: existing.bytesOut + UInt64(networkData.ifi_obytes)
                )
            }
        }

        return SystemStatsMath.NetworkCounters(interfaces: interfaces, date: Date())
    }

    // MARK: - Active Apps
    private func getActiveApps() -> [String] {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
            .filter { $0.activationPolicy == .regular && $0.isActive == false }
            .prefix(5)
            .compactMap { $0.localizedName }

        if let frontmost = workspace.frontmostApplication?.localizedName {
            return [frontmost] + apps.filter { $0 != frontmost }
        }

        return Array(apps)
    }
}

// MARK: - Dynamic Island Math
/// Pure, testable predicates for the Dynamic Island. Kept separate from any
/// AppKit context so they compile in the test target (which links
/// `SystemStats.swift` via the SPM library target).
enum DynamicIslandMath {
    /// The standard menu-bar height in points, with no notch. A safe-area top
    /// inset greater than this implies the menu bar sits beside a notch.
    static let menuBarOnlyHeight: CGFloat = 24

    /// At rest the island is exactly as tall as the notch and extends a
    /// compact "ear" either side of the cutout, like the iPhone's Dynamic
    /// Island. Expanded, it grows downward into a full card. Widths derive
    /// from the measured cutout when AppKit exposes both auxiliary areas.
    static let fallbackNotchWidth: CGFloat = 180
    static let compactEarWidth: CGFloat = 80
    static let expandedContentHeight: CGFloat = 182
    static let expandedMinimumWidth: CGFloat = 500
    static let expandedHorizontalPadding: CGFloat = 230

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

    static func measuredNotchWidth(_ notchWidth: CGFloat) -> CGFloat {
        notchWidth.isFinite && notchWidth > 0 ? notchWidth : fallbackNotchWidth
    }

    static func restingWidth(notchWidth: CGFloat) -> CGFloat {
        measuredNotchWidth(notchWidth) + compactEarWidth * 2
    }

    static func expandedWidth(notchWidth: CGFloat) -> CGFloat {
        max(measuredNotchWidth(notchWidth) + expandedHorizontalPadding, expandedMinimumWidth)
    }

    /// The resting island is notch-height so it reads as part of the
    /// hardware, with content only in the ears beside the cutout. The top
    /// edge remains pinned to the top of the screen.
    static func restingFrame(
        screen: CGRect,
        notchHeight: CGFloat,
        notchWidth: CGFloat = fallbackNotchWidth
    ) -> CGRect {
        let height = notchHeight.isFinite ? max(notchHeight, 1) : 1
        let width = restingWidth(notchWidth: notchWidth)
        let x = screen.midX - width / 2
        let y = screen.maxY - height  // top edge at screen top
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The expanded pill frame: same center and top edge as the resting frame,
    /// taller and wider, so the expand animation reads as "growing downward".
    static func expandedFrame(
        screen: CGRect,
        notchHeight: CGFloat,
        notchWidth: CGFloat = fallbackNotchWidth
    ) -> CGRect {
        let cutoutHeight = notchHeight.isFinite ? max(notchHeight, 1) : 1
        let width = expandedWidth(notchWidth: notchWidth)
        let height = cutoutHeight + expandedContentHeight
        let x = screen.midX - width / 2
        let y = screen.maxY - height  // top edge aligns with resting top edge
        return CGRect(x: x, y: y, width: width, height: height)
    }

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

}
