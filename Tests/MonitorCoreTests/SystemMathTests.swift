import Foundation
import Testing
@testable import MonitorCore

// MARK: - CPU

@Suite("CPU usage math")
struct CPUUsageMathTests {
    private func ticks(_ user: UInt32, _ system: UInt32, _ idle: UInt32, _ nice: UInt32 = 0) -> CPUCoreTicks {
        CPUCoreTicks(user: user, system: system, idle: idle, nice: nice)
    }

    @Test("total and per-core load from deltas")
    func perCore() {
        let previous = [ticks(100, 100, 800), ticks(0, 0, 1000)]
        let current = [ticks(150, 130, 820, 0), ticks(0, 0, 1100)]
        let usage = CPUUsageMath.usage(previous: previous, current: current)
        #expect(usage.perCore.count == 2)
        #expect(abs(usage.perCore[0] - 0.8) < 1e-9)
        #expect(usage.perCore[1] == 0)
        #expect(abs(usage.total - 80.0 / 200.0) < 1e-9)
    }

    @Test("nice time counts as busy")
    func nice() {
        let usage = CPUUsageMath.usage(previous: [ticks(0, 0, 0, 0)], current: [ticks(0, 0, 50, 50)])
        #expect(abs(usage.total - 0.5) < 1e-9)
    }

    @Test("counter wrap uses wrapping subtraction")
    func wrap() {
        let usage = CPUUsageMath.usage(previous: [ticks(UInt32.max - 9, 0, 0)], current: [ticks(10, 0, 20)])
        #expect(abs(usage.total - 20.0 / 40.0) < 1e-9)
    }

    @Test("no previous sample reports load since boot")
    func noPrevious() {
        let usage = CPUUsageMath.usage(previous: [], current: [ticks(25, 25, 50)])
        #expect(abs(usage.total - 0.5) < 1e-9)
        #expect(usage.perCore.count == 1)
    }

    @Test("idle interval and empty input yield zero")
    func zero() {
        #expect(CPUUsageMath.usage(previous: [ticks(1, 1, 1)], current: [ticks(1, 1, 1)]).total == 0)
        #expect(CPUUsageMath.usage(previous: [], current: []).total == 0)
        #expect(CPUUsageMath.ratio(5, 0) == 0)
    }
}

// MARK: - Network

@Suite("Network math")
struct NetworkMathTests {
    @Test("bytes per second from deltas")
    func rate() {
        let result = NetworkMath.throughput(
            previous: NetworkCounters(bytesIn: 1000, bytesOut: 500),
            current: NetworkCounters(bytesIn: 3000, bytesOut: 1500), elapsed: 2
        )
        #expect(result == NetworkThroughput(bytesInPerSecond: 1000, bytesOutPerSecond: 500))
    }

    @Test("counter reset yields zero for that direction")
    func reset() {
        let result = NetworkMath.throughput(
            previous: NetworkCounters(bytesIn: 5000, bytesOut: 100),
            current: NetworkCounters(bytesIn: 10, bytesOut: 300), elapsed: 1
        )
        #expect(result.bytesInPerSecond == 0)
        #expect(result.bytesOutPerSecond == 200)
    }

    @Test("first sample or zero interval yields zero")
    func first() {
        let current = NetworkCounters(bytesIn: 10, bytesOut: 10)
        #expect(NetworkMath.throughput(previous: nil, current: current, elapsed: 1).bytesInPerSecond == 0)
        #expect(NetworkMath.throughput(previous: current, current: current, elapsed: 0).bytesOutPerSecond == 0)
    }
}

// MARK: - Memory

@Suite("Memory math")
struct MemoryMathTests {
    private func raw(internalCount: UInt64 = 1000, purgeable: UInt64 = 200, wired: UInt64 = 300,
                     compressor: UInt64 = 100, total: UInt64 = 16_384 * 10_000, level: Int32 = 1) -> MemoryRawCounts {
        MemoryRawCounts(internalPages: internalCount, purgeablePages: purgeable, wiredPages: wired,
                        compressorPages: compressor, pageSize: 16_384, totalBytes: total,
                        swapUsedBytes: 42, pressureLevel: level)
    }

    @Test("Activity Monitor formula")
    func assembly() {
        let stats = MemoryMath.stats(from: raw())
        #expect(stats.appBytes == 800 * 16_384)
        #expect(stats.wiredBytes == 300 * 16_384)
        #expect(stats.compressedBytes == 100 * 16_384)
        #expect(stats.usedBytes == 1200 * 16_384)
        #expect(stats.totalBytes == 16_384 * 10_000)
        #expect(stats.swapUsedBytes == 42)
        #expect(stats.pressure == .normal)
    }

    @Test("purgeable above internal clamps app to zero; used clamps to total")
    func clamping() {
        #expect(MemoryMath.stats(from: raw(internalCount: 10, purgeable: 50)).appBytes == 0)
        #expect(MemoryMath.stats(from: raw(total: 1000)).usedBytes == 1000)
    }

    @Test("pressure level mapping", arguments: [
        (Int32(1), MemoryPressure.normal), (2, .warning), (4, .critical), (0, .normal), (3, .normal),
    ])
    func pressure(level: Int32, expected: MemoryPressure) {
        #expect(MemoryMath.pressure(fromLevel: level) == expected)
        #expect(MemoryMath.stats(from: raw(level: level)).pressure == expected)
    }
}

// MARK: - Battery & thermal

@Suite("Battery math")
struct BatteryMathTests {
    private let discharging = BatteryMath.PowerSourceValues(
        currentCapacity: 80, maxCapacity: 100, isCharging: false, isPluggedIn: false, timeToEmpty: 240, timeToFull: -1)

    @Test("level, cycle count and health from raw mAh")
    func stats() {
        let registry = BatteryMath.RegistryValues(cycleCount: 120, rawMaxCapacity: 4500, maxCapacity: 100, designCapacity: 5000)
        let stats = BatteryMath.stats(source: discharging, registry: registry)
        #expect(stats.level == 0.8)
        #expect(stats.cycleCount == 120)
        #expect(stats.health == 0.9)
        #expect(stats.minutesRemaining == 240)
    }

    @Test("health falls back to MaxCapacity only when it is in mAh")
    func healthFallback() {
        #expect(BatteryMath.health(.init(maxCapacity: 4000, designCapacity: 5000)) == 0.8)
        #expect(BatteryMath.health(.init(maxCapacity: 95, designCapacity: 5000)) == nil)
        #expect(BatteryMath.health(.init(rawMaxCapacity: 6000, designCapacity: 5000)) == 1)
        #expect(BatteryMath.health(.init()) == nil)
    }

    @Test("remaining time depends on power state")
    func remaining() {
        var charging = discharging
        charging.isCharging = true
        charging.isPluggedIn = true
        charging.timeToFull = 35
        #expect(BatteryMath.minutesRemaining(charging) == 35)
        var pluggedFull = charging
        pluggedFull.isCharging = false
        #expect(BatteryMath.minutesRemaining(pluggedFull) == nil)
        var estimating = discharging
        estimating.timeToEmpty = -1
        #expect(BatteryMath.minutesRemaining(estimating) == nil)
    }

    @Test("zero max capacity gives zero level")
    func zeroMax() {
        var source = discharging
        source.maxCapacity = 0
        #expect(BatteryMath.stats(source: source, registry: .init()).level == 0)
    }

    @Test("description dictionary parsing")
    func parsing() {
        let values = BatteryReader.values(from: [
            "Current Capacity": 50, "Max Capacity": 100, "Is Charging": true,
            "Power Source State": "AC Power", "Time to Full Charge": 20,
        ])
        #expect(values.currentCapacity == 50)
        #expect(values.isCharging && values.isPluggedIn)
        #expect(values.timeToFull == 20)
        #expect(values.timeToEmpty == nil)
    }

    @Test("thermal mapping")
    func thermal() {
        #expect(SystemReaders.thermalLevel(.nominal) == .nominal)
        #expect(SystemReaders.thermalLevel(.fair) == .fair)
        #expect(SystemReaders.thermalLevel(.serious) == .serious)
        #expect(SystemReaders.thermalLevel(.critical) == .critical)
    }
}
