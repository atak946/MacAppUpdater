import Foundation

// MARK: - Raw ticks

/// Cumulative CPU ticks of one logical core, as reported by `host_processor_info`.
/// Counters are 32-bit in the kernel and may wrap, so deltas use wrapping arithmetic.
struct CPUCoreTicks: Sendable, Hashable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

// MARK: - Delta math

/// Pure CPU-load math over two tick samples.
enum CPUUsageMath {
    /// Result of comparing two samples: whole-machine load plus per-core load, all 0...1.
    struct Usage: Sendable, Hashable {
        let total: Double
        let perCore: [Double]
    }

    /// Computes usage between `previous` and `current`.
    /// When the core count changed (or there is no previous sample) the load since boot is reported.
    static func usage(previous: [CPUCoreTicks], current: [CPUCoreTicks]) -> Usage {
        let baseline = previous.count == current.count
            ? previous
            : Array(repeating: CPUCoreTicks(user: 0, system: 0, idle: 0, nice: 0), count: current.count)
        var busyTotal: UInt64 = 0
        var allTotal: UInt64 = 0
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        for (old, new) in zip(baseline, current) {
            let (busy, all) = delta(old, new)
            busyTotal += busy
            allTotal += all
            perCore.append(ratio(busy, all))
        }
        return Usage(total: ratio(busyTotal, allTotal), perCore: perCore)
    }

    /// Busy (user + system + nice) and total ticks elapsed between two core samples.
    static func delta(_ old: CPUCoreTicks, _ new: CPUCoreTicks) -> (busy: UInt64, total: UInt64) {
        let user = UInt64(new.user &- old.user)
        let system = UInt64(new.system &- old.system)
        let nice = UInt64(new.nice &- old.nice)
        let idle = UInt64(new.idle &- old.idle)
        let busy = user + system + nice
        return (busy, busy + idle)
    }

    /// `part / whole` clamped to 0...1; 0 when `whole` is 0.
    static func ratio(_ part: UInt64, _ whole: UInt64) -> Double {
        guard whole > 0 else { return 0 }
        return min(1, max(0, Double(part) / Double(whole)))
    }
}
