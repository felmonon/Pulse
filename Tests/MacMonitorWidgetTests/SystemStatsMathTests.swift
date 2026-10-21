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
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(0), "0.0 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(4.2), "4.2 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(8.5), "8.5 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(12.34), "12.3 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(16.0), "16.0 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(99.9), "99.9 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(234.56), "235 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(512.0), "512 GB")
    }

    func testFormatGigabytesClampsNegativeToZero() {
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(-10.0), "0.0 GB")
    }

    func testFormatGigabytesSanitizesNonFiniteValues() {
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(.nan), "0.0 GB")
        XCTAssertEqual(PulseSharedSettings.formatGigabytes(.infinity), "0.0 GB")
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

    // MARK: - CPU breakdown

    func testCPUBreakdownSplitsUserAndSystemPerCore() {
        let previous = [
            SystemStatsMath.CPUCoreTicks(user: 100, system: 50, idle: 850, nice: 0),
            SystemStatsMath.CPUCoreTicks(user: 0, system: 0, idle: 1_000, nice: 0)
        ]
        let current = [
            // +60 user, +20 system, +20 idle -> 80% busy
            SystemStatsMath.CPUCoreTicks(user: 160, system: 70, idle: 870, nice: 0),
            // +100 idle -> 0% busy
            SystemStatsMath.CPUCoreTicks(user: 0, system: 0, idle: 1_100, nice: 0)
        ]

        let breakdown = SystemStatsMath.cpuBreakdown(previous: previous, current: current)

        XCTAssertEqual(breakdown.cores.count, 2)
        XCTAssertEqual(breakdown.cores[0], 0.8, accuracy: 0.0001)
        XCTAssertEqual(breakdown.cores[1], 0, accuracy: 0.0001)
        XCTAssertEqual(breakdown.user, 0.3, accuracy: 0.0001)
        XCTAssertEqual(breakdown.system, 0.1, accuracy: 0.0001)
        XCTAssertEqual(breakdown.total, 0.4, accuracy: 0.0001)
    }

    func testCPUBreakdownCountsNiceAsUserTime() {
        let previous = [SystemStatsMath.CPUCoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let current = [SystemStatsMath.CPUCoreTicks(user: 10, system: 0, idle: 80, nice: 10)]

        let breakdown = SystemStatsMath.cpuBreakdown(previous: previous, current: current)

        XCTAssertEqual(breakdown.user, 0.2, accuracy: 0.0001)
        XCTAssertEqual(breakdown.system, 0, accuracy: 0.0001)
    }

    func testCPUBreakdownFallsBackToCumulativeTicksWhenCoreCountChanges() {
        let previous = [SystemStatsMath.CPUCoreTicks(user: 900, system: 0, idle: 100, nice: 0)]
        let current = [
            SystemStatsMath.CPUCoreTicks(user: 25, system: 25, idle: 50, nice: 0),
            SystemStatsMath.CPUCoreTicks(user: 0, system: 0, idle: 100, nice: 0)
        ]

        let breakdown = SystemStatsMath.cpuBreakdown(previous: previous, current: current)

        XCTAssertEqual(breakdown.cores, [0.5, 0])
        XCTAssertEqual(breakdown.total, 0.25, accuracy: 0.0001)
    }

    func testCPUBreakdownWithNoTicksIsIdle() {
        let breakdown = SystemStatsMath.cpuBreakdown(previous: nil, current: [])
        XCTAssertEqual(breakdown.total, 0)
        XCTAssertTrue(breakdown.cores.isEmpty)
    }

    // MARK: - Memory breakdown

    func testMemoryBreakdownMatchesActivityMonitorDefinitions() {
        let breakdown = SystemStatsMath.memoryBreakdown(
            totalBytes: 1_000,
            pageSize: 10,
            internalPages: 40,
            purgeablePages: 5,
            externalPages: 15,
            wiredPages: 20,
            compressorPages: 10
        )

        XCTAssertEqual(breakdown.appBytes, 350, accuracy: 0.01)       // (40 - 5) * 10
        XCTAssertEqual(breakdown.wiredBytes, 200, accuracy: 0.01)
        XCTAssertEqual(breakdown.compressedBytes, 100, accuracy: 0.01)
        XCTAssertEqual(breakdown.cachedBytes, 200, accuracy: 0.01)    // (15 + 5) * 10
        XCTAssertEqual(breakdown.usedBytes, 650, accuracy: 0.01)      // app + wired + compressed
        XCTAssertEqual(breakdown.usage, 0.65, accuracy: 0.0001)
    }

    func testMemoryBreakdownClampsToPhysicalMemory() {
        let breakdown = SystemStatsMath.memoryBreakdown(
            totalBytes: 100,
            pageSize: 10,
            internalPages: 50,
            purgeablePages: 60,
            externalPages: 50,
            wiredPages: 20,
            compressorPages: 0
        )

        XCTAssertEqual(breakdown.appBytes, 0, accuracy: 0.01)
        XCTAssertEqual(breakdown.usedBytes, 100, accuracy: 0.01)
        XCTAssertEqual(breakdown.cachedBytes, 0, accuracy: 0.01)
        XCTAssertEqual(breakdown.usage, 1, accuracy: 0.0001)
    }

    func testMemoryBreakdownRejectsInvalidTotals() {
        XCTAssertEqual(
            SystemStatsMath.memoryBreakdown(
                totalBytes: .nan,
                pageSize: 16_384,
                internalPages: 1,
                purgeablePages: 0,
                externalPages: 0,
                wiredPages: 0,
                compressorPages: 0
            ),
            .empty
        )
    }

    // MARK: - Battery time

    func testBatteryMinutesUsesTimeToFullWhileCharging() {
        XCTAssertEqual(
            SystemStatsMath.batteryMinutes(isCharging: true, isPluggedIn: true, timeToEmpty: 300, timeToFull: 42),
            42
        )
    }

    func testBatteryMinutesUsesTimeToEmptyOnBattery() {
        XCTAssertEqual(
            SystemStatsMath.batteryMinutes(isCharging: false, isPluggedIn: false, timeToEmpty: 185, timeToFull: nil),
            185
        )
    }

    func testBatteryMinutesHidesEstimatesThatAreStillCalculating() {
        XCTAssertNil(SystemStatsMath.batteryMinutes(isCharging: true, isPluggedIn: true, timeToEmpty: nil, timeToFull: -1))
        XCTAssertNil(SystemStatsMath.batteryMinutes(isCharging: false, isPluggedIn: false, timeToEmpty: -1, timeToFull: nil))
        // Plugged in but not charging (e.g. held at 80%): no countdown.
        XCTAssertNil(SystemStatsMath.batteryMinutes(isCharging: false, isPluggedIn: true, timeToEmpty: 200, timeToFull: nil))
    }

    // MARK: - History

    func testHistoryKeepsMostRecentSamplesWithinCapacity() {
        var history = MetricHistory(capacity: 3)
        for value in [0.1, 0.2, 0.3, 0.4, 0.5] {
            history.append(cpu: value, memory: value, networkUp: 0, networkDown: 0)
        }

        XCTAssertEqual(history.samples.count, 3)
        XCTAssertEqual(history.samples.map(\.cpu), [0.3, 0.4, 0.5])
        XCTAssertEqual(history.samples.map(\.id), [2, 3, 4])
    }

    func testHistorySanitizesSamples() {
        var history = MetricHistory(capacity: 4)
        history.append(cpu: .nan, memory: 1.7, networkUp: -5, networkDown: .infinity)

        let sample = history.samples[0]
        XCTAssertEqual(sample.cpu, 0)
        XCTAssertEqual(sample.memory, 1)
        XCTAssertEqual(sample.networkUp, 0)
        XCTAssertEqual(sample.networkDown, 0)
    }

    func testHistoryNetworkCeilingHasAFloor() {
        var history = MetricHistory()
        XCTAssertEqual(history.networkCeiling, 64, accuracy: 0.01)
        history.append(cpu: 0, memory: 0, networkUp: 100, networkDown: 1_000)
        XCTAssertEqual(history.networkCeiling, 1_150, accuracy: 0.01)
    }

    // MARK: - Formatting

    func testUptimeFormatting() {
        XCTAssertEqual(PulseSharedSettings.formatUptime(0), "—")
        XCTAssertEqual(PulseSharedSettings.formatUptime(8 * 60), "8m")
        XCTAssertEqual(PulseSharedSettings.formatUptime(5 * 3600 + 12 * 60), "5h 12m")
        XCTAssertEqual(PulseSharedSettings.formatUptime(3 * 86_400 + 4 * 3600 + 59), "3d 4h")
    }

    func testBatteryTimeFormatting() {
        XCTAssertEqual(PulseSharedSettings.formatBatteryTime(minutes: 125), "2:05")
        XCTAssertEqual(PulseSharedSettings.formatBatteryTime(minutes: -3), "0:00")
    }

    func testIntervalDescriptionReadsLikeSettings() {
        XCTAssertEqual(PulseSharedSettings.intervalDescription(1), "Every second")
        XCTAssertEqual(PulseSharedSettings.intervalDescription(15), "Every 15 seconds")
        XCTAssertEqual(PulseSharedSettings.intervalDescription(60), "Every minute")
    }

    // MARK: - Severity latch

    func testLatchAdoptsFirstReadingImmediately() {
        var latch = SystemStatsMath.SeverityLatch(enterSamples: 3, exitSamples: 8)
        XCTAssertEqual(latch.update(.critical), .critical)
    }

    func testLatchRaisesOnlyAfterSustainedSamples() {
        var latch = SystemStatsMath.SeverityLatch(enterSamples: 3, exitSamples: 8)
        _ = latch.update(.nominal)
        XCTAssertEqual(latch.update(.high), .nominal)
        XCTAssertEqual(latch.update(.high), .nominal)
        XCTAssertEqual(latch.update(.high), .high)
    }

    func testLatchIgnoresASingleSpike() {
        var latch = SystemStatsMath.SeverityLatch(enterSamples: 3, exitSamples: 8)
        _ = latch.update(.nominal)
        XCTAssertEqual(latch.update(.high), .nominal)
        XCTAssertEqual(latch.update(.nominal), .nominal)
        XCTAssertEqual(latch.update(.high), .nominal)
        XCTAssertEqual(latch.update(.high), .nominal)
        XCTAssertEqual(latch.update(.high), .high)
    }

    func testLatchLowersOnlyAfterLongerCalm() {
        var latch = SystemStatsMath.SeverityLatch(enterSamples: 2, exitSamples: 4)
        _ = latch.update(.high)
        for _ in 0..<3 {
            XCTAssertEqual(latch.update(.nominal), .high)
        }
        XCTAssertEqual(latch.update(.nominal), .nominal)
    }

    func testLatchedSeverityOverridesRawSeverity() {
        var stats = SystemStats.placeholder
        stats.cpuUsage = 0.95
        XCTAssertEqual(stats.rawCPUSeverity, .critical)
        stats.latchedCPUSeverity = .nominal
        XCTAssertEqual(stats.cpuSeverity, .nominal)
    }

    // MARK: - Speed thresholds

    func testAutomaticSpeedNeverShowsFourKilobyteDigits() {
        XCTAssertEqual(PulseSharedSettings.formatSpeed(999, unitsMode: .automatic), "999 KB/s")
        XCTAssertEqual(PulseSharedSettings.formatSpeed(1006, unitsMode: .automatic), "1.0 MB/s")
    }

    func testKilobyteModeGroupsThousands() {
        let text = PulseSharedSettings.formatSpeed(12_345, unitsMode: .kilobytesPerSecond)
        XCTAssertTrue(text.hasSuffix(" KB/s"))
        XCTAssertGreaterThan(text.count, "12345 KB/s".count, "expected a grouping separator in \(text)")
    }
}
