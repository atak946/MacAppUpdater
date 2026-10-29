import Darwin
import Foundation

/// Raw per-process values read through libproc.
struct RawProcessInfo: Sendable, Hashable {
    var pid: Int32
    var parentPID: Int32
    var name: String
    var path: String?
    var userID: UInt32
    var startSeconds: UInt64
    var startMicroseconds: UInt64
    /// User + system CPU time in Mach absolute-time units; nil when access is denied.
    var cpuTimeTicks: UInt64?
    var threadCount: Int
    var footprintBytes: UInt64
}

/// libproc wrappers. Processes that vanish or deny access are skipped or partially filled.
enum ProcessReader {
    private static let maxPathSize = 4 * Int(MAXPATHLEN)

    // MARK: - Listing

    /// All pids currently known to the kernel.
    static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        let capacity = Int(estimate) + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    // MARK: - Per process

    /// Reads one process; nil when even its BSD info is unavailable (it exited).
    static func read(pid: Int32) -> RawProcessInfo? {
        guard let bsd = bsdInfo(pid: pid) else { return nil }
        let path = executablePath(pid: pid)
        let task = taskInfo(pid: pid)
        let shortName = cString(fromTuple: bsd.pbi_name)
        let name = displayName(short: shortName.isEmpty ? cString(fromTuple: bsd.pbi_comm) : shortName, path: path)
        return RawProcessInfo(
            pid: pid, parentPID: Int32(bitPattern: bsd.pbi_ppid), name: name, path: path, userID: bsd.pbi_uid,
            startSeconds: bsd.pbi_start_tvsec, startMicroseconds: bsd.pbi_start_tvusec,
            cpuTimeTicks: task.map { $0.pti_total_user &+ $0.pti_total_system },
            threadCount: Int(task?.pti_threadnum ?? 0),
            footprintBytes: footprint(pid: pid) ?? task?.pti_resident_size ?? 0
        )
    }

    /// The kernel truncates names; prefer the executable's file name when it extends the short name.
    static func displayName(short: String, path: String?) -> String {
        guard let path else { return short }
        let file = (path as NSString).lastPathComponent
        if short.isEmpty || (file.hasPrefix(short) && file.count > short.count) { return file }
        return short
    }

    private static func bsdInfo(pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func taskInfo(pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? info : nil
    }

    private static func footprint(pid: Int32) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }

    private static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: maxPathSize)
        let length = proc_pidpath(pid, &buffer, UInt32(maxPathSize))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Decodes a fixed-size C char tuple (NUL-terminated or full).
    static func cString<T>(fromTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
