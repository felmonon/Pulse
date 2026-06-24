import Foundation
import IOKit
import IOKit.ps
import AppKit

// MARK: - Load Severity
/// Coarse classification of how loaded a metric is, used to tint rings and
/// give the widget a glanceable "is something under pressure?" signal.
enum LoadSeverity: Int, Comparable {
    case nominal = 0
    case moderate = 1
    case high = 2
    case critical = 3

    /// Maps a 0...1 utilization to a severity band.
    /// Thresholds: <50% nominal, <75% moderate, <90% high, otherwise critical.
    static func from(usage: Double) -> LoadSeverity {
        let clamped = SystemStatsMath.unitInterval(usage)
        switch clamped {
        case ..<0.50: return .nominal
        case ..<0.75: return .moderate
        case ..<0.90: return .high
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

    var isStale: Bool {
        Date().timeIntervalSince(timestamp) > 120
    }

    static var placeholder: SystemStats {
        SystemStats(
            cpuUsage: 0.45,
            memoryUsage: 0.62,
            memoryUsed: 10.2,
            memoryTotal: 16.0,
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
            timestamp: Date()
        )
    }
}

// MARK: - Shared Stats Cache
enum PulseSharedDefaults {
    static let appGroupID = "group.com.macmonitor.widget.shared"
    static let legacySuiteName = "com.macmonitor.widget.shared"

    static let defaults: UserDefaults = {
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil,
           let groupDefaults = UserDefaults(suiteName: appGroupID) {
            return groupDefaults
        }

        return UserDefaults(suiteName: legacySuiteName) ?? .standard
    }()
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
        static let showActiveApps = "settings.showActiveApps"
        static let islandEnabled = "settings.islandEnabled"
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

    static func percent(_ value: Double) -> String {
        "\(Int((SystemStatsMath.unitInterval(value) * 100).rounded()))%"
    }

    /// Formats a gibibyte (GiB) value as a compact, human-readable string.
    /// Used everywhere storage/memory appears so the unit is always GB and
    /// the precision scales sensibly with magnitude (234 GB, not 234.5 GB).
    static func formatGigabytes(_ value: Double) -> String {
        guard value.isFinite else { return "0.00 GB" }
        let clamped = max(value, 0)
        if clamped >= 100 {
            return String(format: "%.0f GB", clamped)
        }
        if clamped >= 10 {
            return String(format: "%.1f GB", clamped)
        }
        return String(format: "%.2f GB", clamped)
    }

    static func formatSpeed(_ speed: Double, unitsMode: UnitsMode) -> String {
        let speed = SystemStatsMath.sanitizeSpeed(speed)
        switch unitsMode {
        case .automatic:
            if speed >= 1024 {
                return formatMegabytes(speed / 1024)
            }
            return String(format: "%.0f KB/s", speed)
        case .kilobytesPerSecond:
            return String(format: "%.0f KB/s", speed)
        case .megabytesPerSecond:
            return formatMegabytes(speed / 1024)
        }
    }

    private static func formatMegabytes(_ value: Double) -> String {
        if value >= 10 {
            return String(format: "%.0f MB/s", value)
        }

        return String(format: "%.1f MB/s", value)
    }
}

// MARK: - Shared Stats Cache
enum SystemStatsCache {
    private static let statsKey = "latestSystemStats"
    private static let defaults = PulseSharedDefaults.defaults

    static func save(_ stats: SystemStats) {
        guard let data = try? JSONEncoder().encode(stats) else {
            return
        }

        defaults.set(data, forKey: statsKey)
        defaults.synchronize()
    }

    static func load(maxAge: TimeInterval) -> SystemStats? {
        guard let data = defaults.data(forKey: statsKey),
              let stats = try? JSONDecoder().decode(SystemStats.self, from: data) else {
            return nil
        }

        let age = Date().timeIntervalSince(stats.timestamp)
        guard age >= 0 && age <= maxAge else {
            return nil
        }

        return stats
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

    private static func clamp(_ value: Double) -> Double {
        unitInterval(value)
    }
}

// MARK: - System Monitor
class SystemMonitor {
    static let shared = SystemMonitor()

    private var previousCPUCounters: SystemStatsMath.CPUCounters?
    private var previousNetworkCounters: SystemStatsMath.NetworkCounters?

    // EMA-smoothed display values. Raw CPU deltas between two samples are
    // jumpy; smoothing with a light alpha keeps the ring from flickering
    // every tick while still tracking real changes quickly.
    private static let cpuSmoothingAlpha: Double = 0.4
    private static let networkSmoothingAlpha: Double = 0.5
    private var smoothedCPU: Double?
    private var smoothedNetworkUp: Double?
    private var smoothedNetworkDown: Double?

    func getCachedStats(maxAge: TimeInterval = 120) -> SystemStats? {
        SystemStatsCache.load(maxAge: maxAge)
    }

    func getStatsAndCache() -> SystemStats {
        let stats = getStats()
        SystemStatsCache.save(stats)
        return stats
    }

    func getStats() -> SystemStats {
        // Cache results to avoid multiple calls
        let memory = getMemoryUsage()
        let disk = getDiskUsage()
        let battery = getBatteryLevel()
        let network = getNetworkSpeed()

        let rawCPU = getCPUUsage()
        let cpu = SystemStatsMath.smoothed(
            previous: smoothedCPU,
            current: rawCPU,
            alpha: SystemMonitor.cpuSmoothingAlpha
        )
        smoothedCPU = cpu

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

        return SystemStats(
            cpuUsage: cpu,
            memoryUsage: memory.percentage,
            memoryUsed: memory.used,
            memoryTotal: memory.total,
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
            timestamp: Date()
        )
    }

    // MARK: - CPU Usage
    private func getCPUUsage() -> Double {
        guard let current = getCPUCounters(), current.total > 0 else {
            return 0.0
        }

        defer {
            previousCPUCounters = current
        }

        return SystemStatsMath.cpuUsage(previous: previousCPUCounters, current: current)
    }

    private func getCPUCounters() -> SystemStatsMath.CPUCounters? {
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

        var usedTicks: UInt64 = 0
        var totalTicks: UInt64 = 0

        for i in 0..<Int(numCPUs) {
            let offset = Int(CPU_STATE_MAX) * i
            let user = UInt64(Int64(max(info[offset + Int(CPU_STATE_USER)], 0)))
            let system = UInt64(Int64(max(info[offset + Int(CPU_STATE_SYSTEM)], 0)))
            let idle = UInt64(Int64(max(info[offset + Int(CPU_STATE_IDLE)], 0)))
            let nice = UInt64(Int64(max(info[offset + Int(CPU_STATE_NICE)], 0)))

            usedTicks += user + system + nice
            totalTicks += user + system + idle + nice
        }

        return SystemStatsMath.CPUCounters(used: usedTicks, total: totalTicks)
    }

    // MARK: - Memory Usage
    private func getMemoryUsage() -> (percentage: Double, used: Double, total: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return (0, 0, 0)
        }

        let pageSize = Double(vm_kernel_page_size)
        let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)

        let activeMemory = Double(stats.active_count) * pageSize
        let wiredMemory = Double(stats.wire_count) * pageSize
        let compressedMemory = Double(stats.compressor_page_count) * pageSize

        let usedMemory = activeMemory + wiredMemory + compressedMemory
        let percentage = usedMemory / totalMemory

        return (min(percentage, 1.0), usedMemory / 1_073_741_824, totalMemory / 1_073_741_824)
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
                let totalGB = Double(total) / 1_000_000_000
                let freeGB = freeBytes / 1_000_000_000
                let usedGB = max(totalGB - freeGB, 0)
                let purgeableGB = max((importantAvailableBytes - freeBytes) / 1_000_000_000, 0)
                let percentage = totalGB > 0 ? usedGB / totalGB : 0
                return (min(max(percentage, 0), 1), usedGB, totalGB, freeGB, purgeableGB)
            }
        } catch {}

        return (0, 0, 0, 0, 0)
    }

    // MARK: - Battery
    private func getBatteryLevel() -> (level: Int, isCharging: Bool, hasBattery: Bool) {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

        for source in sources {
            if let info = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                if let capacity = info[kIOPSCurrentCapacityKey] as? Int,
                   let isCharging = info[kIOPSIsChargingKey] as? Bool {
                    return (capacity, isCharging, true)
                }
            }
        }

        return (0, false, false)
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

    /// Pill dimensions. The resting pill exactly fills the notch vertically
    /// and is comfortably narrower than the physical notch. The expanded pill
    /// grows downward into a rounded card.
    static let restingWidth: CGFloat = 150
    static let expandedWidth: CGFloat = 240
    static let expandedHeight: CGFloat = 150

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
