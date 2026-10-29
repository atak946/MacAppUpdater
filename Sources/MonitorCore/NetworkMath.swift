import Foundation

// MARK: - Counters

/// Cumulative byte counters summed over the active non-loopback interfaces.
struct NetworkCounters: Sendable, Hashable {
    var bytesIn: UInt64
    var bytesOut: UInt64
}

// MARK: - Delta math

/// Pure throughput math between two counter samples.
enum NetworkMath {
    /// Bytes per second between samples. A counter that went backwards (reset, interface removed, wrap)
    /// yields 0 for that direction; a missing previous sample or non-positive interval yields 0.
    static func throughput(previous: NetworkCounters?, current: NetworkCounters, elapsed: TimeInterval) -> NetworkThroughput {
        guard let previous, elapsed > 0 else {
            return NetworkThroughput(bytesInPerSecond: 0, bytesOutPerSecond: 0)
        }
        return NetworkThroughput(
            bytesInPerSecond: rate(previous.bytesIn, current.bytesIn, elapsed),
            bytesOutPerSecond: rate(previous.bytesOut, current.bytesOut, elapsed)
        )
    }

    private static func rate(_ old: UInt64, _ new: UInt64, _ elapsed: TimeInterval) -> Double {
        guard new >= old else { return 0 }
        return Double(new - old) / elapsed
    }
}
