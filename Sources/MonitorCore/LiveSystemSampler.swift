import Foundation

/// Samples whole-machine state. Holds the previous CPU and network counters for delta values.
public actor LiveSystemSampler: SystemSampling {
    private var previousTicks: [CPUCoreTicks] = []
    private var previousNetwork: NetworkCounters?
    private var previousNetworkTime: UInt64 = 0

    public init() {}

    public func sample() async -> SystemSnapshot {
        let cpu = sampleCPU()
        return SystemSnapshot(
            timestamp: Date(),
            cpuUsage: cpu.total,
            perCoreUsage: cpu.perCore,
            memory: MemoryMath.stats(from: SystemReaders.memoryCounts()),
            disk: SystemReaders.diskStats(),
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
