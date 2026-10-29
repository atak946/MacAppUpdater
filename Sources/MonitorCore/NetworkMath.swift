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

    /// Rates for every pid in `current` that also appeared in `previous`; pids that are gone or new
    /// since the previous read are dropped, so a reused pid never reports a bogus spike.
    static func throughput(previous: [Int32: NetworkCounters], current: [Int32: NetworkCounters],
                           elapsed: TimeInterval) -> [Int32: NetworkThroughput] {
        guard elapsed > 0 else { return [:] }
        var rates: [Int32: NetworkThroughput] = [:]
        for (pid, counters) in current {
            guard let old = previous[pid] else { continue }
            rates[pid] = throughput(previous: old, current: counters, elapsed: elapsed)
        }
        return rates
    }

    private static func rate(_ old: UInt64, _ new: UInt64, _ elapsed: TimeInterval) -> Double {
        guard new >= old else { return 0 }
        return Double(new - old) / elapsed
    }
}
