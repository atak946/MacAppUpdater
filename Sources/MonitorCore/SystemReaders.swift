import Darwin
import Foundation
import os

/// Thin wrappers over Mach / sysctl APIs. Each returns nil (or an empty value) on failure.
enum SystemReaders {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "SystemReaders")

    // MARK: - CPU

    /// Cumulative per-core ticks from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`.
    static func cpuTicks() -> [CPUCoreTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else {
            logger.error("host_processor_info failed: \(result)")
            return []
        }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { core in
            let base = core * stride
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return CPUCoreTicks(
                user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE)
            )
        }
    }

    // MARK: - Memory

    /// Raw VM counters for `MemoryMath`.
    static func memoryCounts() -> MemoryRawCounts {
        let vm = vmStatistics()
        return MemoryRawCounts(
            internalPages: UInt64(vm?.internal_page_count ?? 0),
            purgeablePages: UInt64(vm?.purgeable_count ?? 0),
            wiredPages: UInt64(vm?.wire_count ?? 0),
            compressorPages: UInt64(vm?.compressor_page_count ?? 0),
            pageSize: pageSize(),
            totalBytes: sysctlValue("hw.memsize", as: UInt64.self) ?? 0,
            swapUsedBytes: sysctlValue("vm.swapusage", as: xsw_usage.self)?.xsu_used ?? 0,
            pressureLevel: sysctlValue("kern.memorystatus_vm_pressure_level", as: Int32.self) ?? 1
        )
    }

    private static func vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            logger.error("host_statistics64 failed: \(result)")
            return nil
        }
        return stats
    }

    /// Kernel VM page size (16 KiB on Apple Silicon, 4 KiB on Intel).
    private static func pageSize() -> UInt64 {
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 else { return UInt64(getpagesize()) }
        return UInt64(size)
    }

    /// Reads a fixed-size sysctl value by name.
    static func sysctlValue<T>(_ name: String, as _: T.Type) -> T? {
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return pointer.pointee
    }

    // MARK: - Disk

    /// Capacity of the startup volume.
    static func diskStats() -> DiskStats {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        do {
            let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
            return DiskStats(
                totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                availableBytes: values.volumeAvailableCapacityForImportantUsage ?? 0
            )
        } catch {
            logger.error("Volume capacity unavailable: \(error.localizedDescription)")
            return DiskStats(totalBytes: 0, availableBytes: 0)
        }
    }

    // MARK: - Network

    /// 64-bit byte counters summed over up, non-loopback interfaces (`NET_RT_IFLIST2`).
    static func networkCounters() -> NetworkCounters {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return NetworkCounters(bytesIn: 0, bytesOut: 0)
        }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else {
            return NetworkCounters(bytesIn: 0, bytesOut: 0)
        }
        return buffer.withUnsafeBytes { sumInterfaceCounters($0, length: length) }
    }

    private static func sumInterfaceCounters(_ raw: UnsafeRawBufferPointer, length: Int) -> NetworkCounters {
        var totals = NetworkCounters(bytesIn: 0, bytesOut: 0)
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            guard header.ifm_msglen > 0 else { break }
            if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                let flags = message.ifm_flags
                if flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                    totals.bytesIn &+= message.ifm_data.ifi_ibytes
                    totals.bytesOut &+= message.ifm_data.ifi_obytes
                }
            }
            offset += Int(header.ifm_msglen)
        }
        return totals
    }

    // MARK: - Thermal

    /// Maps Foundation's thermal state to the contract's level.
    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }
}
