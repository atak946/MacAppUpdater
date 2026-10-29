import Foundation

// MARK: - Raw counts

/// Raw VM counters (in pages) plus byte totals, gathered from `host_statistics64` and sysctl.
struct MemoryRawCounts: Sendable, Hashable {
    var internalPages: UInt64
    var purgeablePages: UInt64
    var wiredPages: UInt64
    var compressorPages: UInt64
    var pageSize: UInt64
    var totalBytes: UInt64
    var swapUsedBytes: UInt64
    /// `kern.memorystatus_vm_pressure_level` value.
    var pressureLevel: Int32
}

// MARK: - Assembly

/// Turns raw VM counters into `MemoryStats` using Activity Monitor's formula.
enum MemoryMath {
    /// app = internal − purgeable, used = app + wired + compressed (clamped to total).
    static func stats(from raw: MemoryRawCounts) -> MemoryStats {
        let appPages = raw.internalPages > raw.purgeablePages ? raw.internalPages - raw.purgeablePages : 0
        let app = appPages &* raw.pageSize
        let wired = raw.wiredPages &* raw.pageSize
        let compressed = raw.compressorPages &* raw.pageSize
        let used = min(raw.totalBytes, app &+ wired &+ compressed)
        return MemoryStats(
            totalBytes: raw.totalBytes, usedBytes: used, appBytes: app, wiredBytes: wired,
            compressedBytes: compressed, swapUsedBytes: raw.swapUsedBytes,
            pressure: pressure(fromLevel: raw.pressureLevel)
        )
    }

    /// Maps the kernel pressure level (1 normal, 2 warning, 4 critical) to `MemoryPressure`.
    static func pressure(fromLevel level: Int32) -> MemoryPressure {
        switch level {
        case 4: .critical
        case 2: .warning
        default: .normal
        }
    }
}
