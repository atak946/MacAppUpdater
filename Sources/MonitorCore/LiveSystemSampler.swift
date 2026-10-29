import Foundation

/// Samples whole-machine state. Holds the previous CPU and network counters for delta values.
public actor LiveSystemSampler: SystemSampling {
    private var previousTicks: [CPUCoreTicks] = []
    private var previousNetwork: NetworkCounters?
    private var previousNetworkTime: UInt64 = 0
    /// Free space comes from the CacheDelete daemon (an XPC round trip) and changes slowly.
    private var cachedDisk: (stats: DiskStats, readAt: UInt64)?
    private let diskInterval: UInt64

    /// - Parameter diskInterval: Seconds between disk capacity reads.
    public init(diskInterval: TimeInterval = 30) {
        self.diskInterval = UInt64(max(0, diskInterval) * 1_000_000_000)
    }

    public func sample() async -> SystemSnapshot {
        let cpu = sampleCPU()
        return SystemSnapshot(
            timestamp: Date(),
            cpuUsage: cpu.total,
            perCoreUsage: cpu.perCore,
            memory: MemoryMath.stats(from: SystemReaders.memoryCounts()),
            disk: sampleDisk(),
            network: sampleNetwork(),
            battery: BatteryReader.read(),
            thermal: SystemReaders.thermalLevel(ProcessInfo.processInfo.thermalState),
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    // MARK: - Deltas

    private func sampleCPU() -> CPUUsageMath.Usage {
        let ticks = SystemReaders.cpuTicks()
        let usage = CPUUsageMath.usage(previous: previousTicks, current: ticks)
        previousTicks = ticks
        return usage
    }

    private func sampleDisk() -> DiskStats {
        let now = DispatchTime.now().uptimeNanoseconds
        if let cachedDisk, now &- cachedDisk.readAt < diskInterval { return cachedDisk.stats }
        let stats = SystemReaders.diskStats()
        cachedDisk = (stats, now)
        return stats
    }

    private func sampleNetwork() -> NetworkThroughput {
        let now = DispatchTime.now().uptimeNanoseconds
        let counters = SystemReaders.networkCounters()
        let elapsed = TimeInterval(now &- previousNetworkTime) / 1_000_000_000
        let throughput = NetworkMath.throughput(previous: previousNetwork, current: counters, elapsed: elapsed)
        previousNetwork = counters
        previousNetworkTime = now
        return throughput
    }
}
