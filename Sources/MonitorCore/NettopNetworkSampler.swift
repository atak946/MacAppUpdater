import Foundation

/// Per-process network rates from `nettop` (no shell): each call reads cumulative counters once
/// and divides the change since the previous call by the time between them.
public actor NettopNetworkSampler: ProcessNetworkSampling {
    static let executable = URL(fileURLWithPath: "/usr/bin/nettop")
    /// Per process (-P), one snapshot (-L 1) as CSV, two columns, raw numbers (-x).
    /// `-n` skips name resolution, which otherwise stalls every run for about five seconds.
    static let arguments = ["-P", "-L", "1", "-n", "-J", "bytes_in,bytes_out", "-x"]
    static let timeout: TimeInterval = 3

    private var previous: (counters: [Int32: NetworkCounters], readAt: UInt64)?
    private let maxInterval: UInt64

    /// - Parameter maxInterval: Seconds after which the previous read is too old to average over
    ///   (the page was hidden meanwhile); the call then starts a new baseline instead.
    public init(maxInterval: TimeInterval = 30) {
        self.maxInterval = UInt64(max(0, maxInterval) * 1_000_000_000)
    }

    /// An empty result (not nil) when nettop could not run, so callers keep their slow cadence.
    public func sample() async -> [Int32: NetworkThroughput]? {
        guard let output = await ToolOutputRunner.run(Self.executable, arguments: Self.arguments, timeout: Self.timeout) else {
            return [:]
        }
        return record(NettopOutputParser.parse(output), at: DispatchTime.now().uptimeNanoseconds)
    }

    /// Keeps `counters` as the new baseline and returns rates against the previous one.
    func record(_ counters: [Int32: NetworkCounters], at now: UInt64) -> [Int32: NetworkThroughput]? {
        defer { previous = (counters, now) }
        guard let previous, now > previous.readAt, now - previous.readAt <= maxInterval else { return nil }
        let elapsed = TimeInterval(now - previous.readAt) / 1_000_000_000
        return NetworkMath.throughput(previous: previous.counters, current: counters, elapsed: elapsed)
    }
}
