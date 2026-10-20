import XCTest
@testable import MacMonitorWidget

final class SystemStatsMathTests: XCTestCase {
    func testCPUUsesDeltaBetweenSamples() {
        let previous = SystemStatsMath.CPUCounters(used: 100, total: 400)
        let current = SystemStatsMath.CPUCounters(used: 160, total: 500)

        XCTAssertEqual(
            SystemStatsMath.cpuUsage(previous: previous, current: current),
            0.6,
            accuracy: 0.0001
        )
    }

    func testCPUHandlesCounterReset() {
        let previous = SystemStatsMath.CPUCounters(used: 1_000, total: 4_000)
        let current = SystemStatsMath.CPUCounters(used: 40, total: 100)

        XCTAssertEqual(
            SystemStatsMath.cpuUsage(previous: previous, current: current),
            0.4,
            accuracy: 0.0001
        )
    }

    func testNetworkUsesOnlyStableInterfaces() {
        let start = Date()
        let previous = SystemStatsMath.NetworkCounters(
            interfaces: [
                "en0": .init(bytesIn: 1_000, bytesOut: 2_000),
                "en5": .init(bytesIn: 8_000, bytesOut: 16_000)
            ],
            date: start
        )
        let current = SystemStatsMath.NetworkCounters(
            interfaces: [
                "en0": .init(bytesIn: 3_048, bytesOut: 4_048),
                "en7": .init(bytesIn: 50_000, bytesOut: 50_000)
            ],
            date: start.addingTimeInterval(2)
        )

        let speed = SystemStatsMath.networkSpeed(previous: previous, current: current)

        XCTAssertEqual(speed.down, 1.0, accuracy: 0.0001)
        XCTAssertEqual(speed.up, 1.0, accuracy: 0.0001)
    }

    func testNetworkIgnoresResetInterfaces() {
        let start = Date()
        let previous = SystemStatsMath.NetworkCounters(
            interfaces: ["en0": .init(bytesIn: 10_000, bytesOut: 10_000)],
            date: start
        )
        let current = SystemStatsMath.NetworkCounters(
            interfaces: ["en0": .init(bytesIn: 500, bytesOut: 500)],
            date: start.addingTimeInterval(1)
        )

        let speed = SystemStatsMath.networkSpeed(previous: previous, current: current)

        XCTAssertEqual(speed.down, 0, accuracy: 0.0001)
        XCTAssertEqual(speed.up, 0, accuracy: 0.0001)
    }

    func testNetworkIgnoresTooShortSampleWindows() {
        let start = Date()
        let previous = SystemStatsMath.NetworkCounters(
            interfaces: ["en0": .init(bytesIn: 1_000, bytesOut: 1_000)],
            date: start
        )
        let current = SystemStatsMath.NetworkCounters(
            interfaces: ["en0": .init(bytesIn: 10_000, bytesOut: 10_000)],
            date: start.addingTimeInterval(0.1)
        )

        let speed = SystemStatsMath.networkSpeed(previous: previous, current: current)

        XCTAssertEqual(speed.down, 0, accuracy: 0.0001)
        XCTAssertEqual(speed.up, 0, accuracy: 0.0001)
    }

    // MARK: - Load Severity

    func testLoadSeverityBandsAtThresholds() {
        XCTAssertEqual(LoadSeverity.from(usage: 0.0), .nominal)
        XCTAssertEqual(LoadSeverity.from(usage: 0.49), .nominal)
        XCTAssertEqual(LoadSeverity.from(usage: 0.50), .moderate)
        XCTAssertEqual(LoadSeverity.from(usage: 0.74), .moderate)
        XCTAssertEqual(LoadSeverity.from(usage: 0.75), .high)
        XCTAssertEqual(LoadSeverity.from(usage: 0.89), .high)
        XCTAssertEqual(LoadSeverity.from(usage: 0.90), .critical)
        XCTAssertEqual(LoadSeverity.from(usage: 1.0), .critical)
    }

    func testLoadSeverityClampsOutOfRange() {
        XCTAssertEqual(LoadSeverity.from(usage: -0.5), .nominal)
        XCTAssertEqual(LoadSeverity.from(usage: 1.5), .critical)
    }

    func testLoadSeverityTreatsNonFiniteValuesAsNominal() {
        XCTAssertEqual(LoadSeverity.from(usage: .nan), .nominal)
        XCTAssertEqual(LoadSeverity.from(usage: .infinity), .nominal)
        XCTAssertEqual(LoadSeverity.from(usage: -.infinity), .nominal)
    }

    func testLoadSeverityIsOrdered() {
        XCTAssertLessThan(LoadSeverity.nominal, .moderate)
        XCTAssertLessThan(LoadSeverity.moderate, .high)
        XCTAssertLessThan(LoadSeverity.high, .critical)
    }

    func testMemorySeverityUsesKernelPressureWhenAvailable() {
        XCTAssertEqual(
            LoadSeverity.memory(usage: 0.99, pressureLevel: .normal),
            .nominal
        )
        XCTAssertEqual(
            LoadSeverity.memory(usage: 0.60, pressureLevel: .warning),
            .high
        )
        XCTAssertEqual(
            LoadSeverity.memory(usage: 0.60, pressureLevel: .critical),
            .critical
        )
    }

    func testMemorySeverityUsesConservativeFallbackBands() {
        XCTAssertEqual(LoadSeverity.memory(usage: 0.74, pressureLevel: nil), .nominal)
        XCTAssertEqual(LoadSeverity.memory(usage: 0.75, pressureLevel: nil), .moderate)
        XCTAssertEqual(LoadSeverity.memory(usage: 0.85, pressureLevel: nil), .high)
        XCTAssertEqual(LoadSeverity.memory(usage: 0.95, pressureLevel: nil), .critical)
    }

    func testDiskSeverityUsesStorageSpecificBands() {
        XCTAssertEqual(LoadSeverity.disk(usage: 0.79), .nominal)
        XCTAssertEqual(LoadSeverity.disk(usage: 0.80), .moderate)
        XCTAssertEqual(LoadSeverity.disk(usage: 0.90), .high)
        XCTAssertEqual(LoadSeverity.disk(usage: 0.95), .critical)
    }

    // MARK: - APFS Disk Accounting

    func testDiskUsageIncludesReclaimableCapacityAsAvailable() {
        let usage = SystemStatsMath.diskUsage(
            totalBytes: 494.38e9,
            freeBytes: 20.38e9,
            importantAvailableBytes: 36.24e9
        )

        XCTAssertEqual(usage.usedBytes, 458.14e9, accuracy: 1)
        XCTAssertEqual(usage.availableBytes, 36.24e9, accuracy: 1)
        XCTAssertEqual(usage.purgeableBytes, 15.86e9, accuracy: 1)
        XCTAssertEqual(usage.percentage, 458.14 / 494.38, accuracy: 0.0001)
    }

    func testDiskUsageClampsInvalidCapacityRelationships() {
        let belowHardFree = SystemStatsMath.diskUsage(
            totalBytes: 100,
            freeBytes: 20,
            importantAvailableBytes: 10
        )
        XCTAssertEqual(belowHardFree.availableBytes, 20)
        XCTAssertEqual(belowHardFree.purgeableBytes, 0)

        let aboveTotal = SystemStatsMath.diskUsage(
            totalBytes: 100,
            freeBytes: 20,
            importantAvailableBytes: 120
        )
        XCTAssertEqual(aboveTotal.availableBytes, 100)
        XCTAssertEqual(aboveTotal.usedBytes, 0)
        XCTAssertEqual(aboveTotal.percentage, 0)
    }

    func testDiskUsageSanitizesNonFiniteValues() {
        let invalidTotal = SystemStatsMath.diskUsage(
            totalBytes: .infinity,
            freeBytes: 20,
            importantAvailableBytes: 30
        )
        XCTAssertEqual(invalidTotal.totalBytes, 0)

        let invalidAvailable = SystemStatsMath.diskUsage(
            totalBytes: 100,
            freeBytes: 20,
            importantAvailableBytes: .nan
        )
        XCTAssertEqual(invalidAvailable.availableBytes, 20)
        XCTAssertEqual(invalidAvailable.percentage, 0.8)
    }

    // MARK: - Shared Settings Formatting

    func testUnitIntervalClampsAndSanitizesNonFiniteValues() {
        XCTAssertEqual(SystemStatsMath.unitInterval(-0.2), 0)
        XCTAssertEqual(SystemStatsMath.unitInterval(0.42), 0.42, accuracy: 0.0001)
        XCTAssertEqual(SystemStatsMath.unitInterval(1.2), 1)
        XCTAssertEqual(SystemStatsMath.unitInterval(.nan), 0)
        XCTAssertEqual(SystemStatsMath.unitInterval(.infinity), 0)
        XCTAssertEqual(SystemStatsMath.unitInterval(-.infinity), 0)
    }

    func testPercentClampsAndSanitizesNonFiniteValues() {
        XCTAssertEqual(PulseSharedSettings.percent(-0.2), "0%")
        XCTAssertEqual(PulseSharedSettings.percent(1.2), "100%")
        XCTAssertEqual(PulseSharedSettings.percent(.nan), "0%")
        XCTAssertEqual(PulseSharedSettings.percent(.infinity), "0%")
    }

    func testRefreshIntervalClampUsesDefaultForNonFiniteValues() {
        XCTAssertEqual(PulseSharedSettings.clampedRefreshInterval(0.2), 1)
        XCTAssertEqual(PulseSharedSettings.clampedRefreshInterval(120), 60)
        XCTAssertEqual(
            PulseSharedSettings.clampedRefreshInterval(.nan),
            PulseSharedSettings.defaultRefreshInterval
        )
        XCTAssertEqual(
            PulseSharedSettings.clampedRefreshInterval(.infinity),
            PulseSharedSettings.defaultRefreshInterval
        )
    }

    // MARK: - Gigabyte Formatting

    func testFormatGigabytesScalesPrecisionWithMagnitude() {
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(0), "0.00 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(4.2), "4.20 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(8.5), "8.50 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(12.34), "12.3 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(16.0), "16.0 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(99.9), "99.9 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(234.56), "235 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(512.0), "512 GB")
    }

    func testFormatGigabytesClampsNegativeToZero() {
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(-10.0), "0.00 GB")
    }

    func testFormatGigabytesSanitizesNonFiniteValues() {
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(.nan), "0.00 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(.infinity), "0.00 GB")
    }

    // MARK: - Smoothing / Sanitization

    func testSmoothedSeedsFromFirstFiniteSample() {
        XCTAssertEqual(
            SystemStatsMath.smoothed(previous: nil, current: 0.8, alpha: 0.4),
            0.8,
            accuracy: 0.0001
        )
    }

    func testSmoothedClampsAlphaAndIgnoresNonFiniteCurrentSample() {
        XCTAssertEqual(
            SystemStatsMath.smoothed(previous: 0.25, current: 1.0, alpha: 2.0),
            1.0,
            accuracy: 0.0001
        )

        XCTAssertEqual(
            SystemStatsMath.smoothed(previous: 0.25, current: .nan, alpha: 0.5),
            0.25,
            accuracy: 0.0001
        )
    }

    func testSmoothedUsesExponentialMovingAverage() {
        XCTAssertEqual(
            SystemStatsMath.smoothed(previous: 0.2, current: 0.8, alpha: 0.25),
            0.35,
            accuracy: 0.0001
        )
    }

    func testSanitizeSpeedRemovesInvalidValuesAndCapsAbsurdValues() {
        XCTAssertEqual(SystemStatsMath.sanitizeSpeed(-1), 0)
        XCTAssertEqual(SystemStatsMath.sanitizeSpeed(.infinity), 0)
        XCTAssertEqual(SystemStatsMath.sanitizeSpeed(.nan), 0)
        XCTAssertEqual(SystemStatsMath.sanitizeSpeed(42), 42)
        XCTAssertEqual(SystemStatsMath.sanitizeSpeed(99_000_000), 10_000_000)
    }

    func testFormatSpeedSanitizesDisplayInput() {
        XCTAssertEqual(
            PulseSharedSettings.formatSpeed(-500, unitsMode: .automatic),
            "0 KB/s"
        )
        XCTAssertEqual(
            PulseSharedSettings.formatSpeed(.nan, unitsMode: .megabytesPerSecond),
            "0.0 MB/s"
        )
    }
}
