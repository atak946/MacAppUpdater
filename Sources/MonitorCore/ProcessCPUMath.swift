import Foundation

/// Pure CPU-percentage math for processes.
enum ProcessCPUMath {
    /// Converts Mach absolute-time units to nanoseconds (identity on Intel, 125/3 on Apple Silicon).
    static func nanoseconds(fromTicks ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        guard denom > 0 else { return ticks }
        let (high, low) = ticks.multipliedFullWidth(by: UInt64(numer))
        guard high < UInt64(denom) else { return UInt64.max }
        return UInt64(denom).dividingFullWidth((high, low)).quotient
    }

    /// Percent of one core used between samples; 0 for a missing baseline, a counter that
    /// went backwards or a non-positive interval.
    static func percent(previousNanos: UInt64?, currentNanos: UInt64, elapsedNanos: UInt64) -> Double {
        guard let previousNanos, elapsedNanos > 0, currentNanos >= previousNanos else { return 0 }
        return Double(currentNanos - previousNanos) / Double(elapsedNanos) * 100
    }
}
