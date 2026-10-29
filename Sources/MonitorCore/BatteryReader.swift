import Foundation
import IOKit
import IOKit.ps

/// Reads battery state from IOPowerSources and the `AppleSmartBattery` registry entry.
enum BatteryReader {
    /// Nil on Macs without an internal battery.
    static func read() -> BatteryStats? {
        guard let source = internalBatteryValues() else { return nil }
        return BatteryMath.stats(source: source, registry: registryValues())
    }

    // MARK: - IOPowerSources

    private static func internalBatteryValues() -> BatteryMath.PowerSourceValues? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            return values(from: description)
        }
        return nil
    }

    /// Extracts the fields `BatteryMath` needs from one description dictionary.
    static func values(from description: [String: Any]) -> BatteryMath.PowerSourceValues {
        BatteryMath.PowerSourceValues(
            currentCapacity: description[kIOPSCurrentCapacityKey] as? Int ?? 0,
            maxCapacity: description[kIOPSMaxCapacityKey] as? Int ?? 100,
            isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
            isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
            timeToEmpty: description[kIOPSTimeToEmptyKey] as? Int,
            timeToFull: description[kIOPSTimeToFullChargeKey] as? Int
        )
    }

    // MARK: - IORegistry

    private static func registryValues() -> BatteryMath.RegistryValues {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return BatteryMath.RegistryValues() }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        return BatteryMath.RegistryValues(
            cycleCount: int("CycleCount"), rawMaxCapacity: int("AppleRawMaxCapacity"),
            maxCapacity: int("MaxCapacity"), designCapacity: int("DesignCapacity")
        )
    }
}
