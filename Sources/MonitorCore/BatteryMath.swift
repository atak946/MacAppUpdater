import Foundation

// MARK: - Battery math

/// Pure helpers that turn IOKit power-source values into `BatteryStats`.
enum BatteryMath {
    /// Values read from one IOPowerSources description dictionary.
    struct PowerSourceValues: Sendable, Hashable {
        var currentCapacity: Int
        var maxCapacity: Int
        var isCharging: Bool
        var isPluggedIn: Bool
        /// Minutes, negative when the OS is still estimating.
        var timeToEmpty: Int?
        var timeToFull: Int?
    }

    /// Values read from the `AppleSmartBattery` IORegistry entry.
    struct RegistryValues: Sendable, Hashable {
        var cycleCount: Int?
        var rawMaxCapacity: Int?
        var maxCapacity: Int?
        var designCapacity: Int?
    }

    /// Combines both sources into the public stats.
    static func stats(source: PowerSourceValues, registry: RegistryValues) -> BatteryStats {
        let level = source.maxCapacity > 0
            ? min(1, max(0, Double(source.currentCapacity) / Double(source.maxCapacity)))
            : 0
        return BatteryStats(
            level: level, isCharging: source.isCharging, isPluggedIn: source.isPluggedIn,
            cycleCount: registry.cycleCount, health: health(registry),
            minutesRemaining: minutesRemaining(source)
        )
    }

    /// Max vs design capacity in mAh, 0...1. `MaxCapacity` is only trusted when it looks like mAh
    /// (Apple Silicon reports it as a percentage, so `AppleRawMaxCapacity` is preferred).
    static func health(_ registry: RegistryValues) -> Double? {
        guard let design = registry.designCapacity, design > 0 else { return nil }
        let maxMAh: Int?
        if let raw = registry.rawMaxCapacity, raw > 0 {
            maxMAh = raw
        } else if let max = registry.maxCapacity, max > 100 {
            maxMAh = max
        } else {
            maxMAh = nil
        }
        guard let maxMAh else { return nil }
        return min(1, Double(maxMAh) / Double(design))
    }

    /// Time to full while charging, time to empty on battery; nil when unknown.
    static func minutesRemaining(_ source: PowerSourceValues) -> Int? {
        let value = source.isCharging ? source.timeToFull : (source.isPluggedIn ? nil : source.timeToEmpty)
        guard let value, value >= 0 else { return nil }
        return value
    }
}
