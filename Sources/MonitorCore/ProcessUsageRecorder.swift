import Darwin
import Foundation

/// Cheap per-minute recorder for the usage history. Unlike `LiveProcessSampler` it reads one
/// `proc_pidinfo` per process (CPU time, resident size, start time), resolves paths and bundles only
/// for processes it hasn't seen yet, and reads the physical footprint only for the top apps' members.
public actor LiveProcessUsageRecorder: ProcessUsageRecording {
    /// Identity of a process across ticks: pid plus start time, so reused pids do not mix.
    private struct ProcessKey: Hashable {
        let pid: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    /// Per-process values that never change, resolved once.
    private struct Identity {
        let name: String
        let path: String?
        let bundleURL: URL?
        let bundleIdentifier: String?
    }

    private let limit: Int
    private let maxIntervalNanos: UInt64
    private let timebase: mach_timebase_info_data_t
    private var previousCPU: [ProcessKey: UInt64] = [:]
    private var previousUptimeNanos: UInt64?
    private var identities: [ProcessKey: Identity] = [:]
    private var bundleIdentifiers: [String: String?] = [:]

    /// `maxInterval`: a longer gap between calls (e.g. the app was suspended) only re-baselines.
    public init(limit: Int = 10, maxInterval: TimeInterval = 180) {
        self.limit = max(1, limit)
        self.maxIntervalNanos = UInt64(max(1, maxInterval) * 1_000_000_000)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info
    }

    public func record(now: Date) async -> UsageMinute? {
        // Uptime stops while the Mac sleeps, like process CPU time, so sleep doesn't dilute averages.
        let uptime = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousUptimeNanos.map { uptime &- $0 } ?? 0
        var currentCPU: [ProcessKey: UInt64] = [:]
        var snapshots: [ProcessSnapshot] = []
        var seen: [ProcessKey: Identity] = [:]
        for pid in ProcessReader.allPIDs() {
            guard let info = Self.taskAllInfo(pid: pid) else { continue }
            let key = ProcessKey(pid: pid, startSeconds: info.pbsd.pbi_start_tvsec, startMicroseconds: info.pbsd.pbi_start_tvusec)
            let ticks = info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system
            let nanos = ProcessCPUMath.nanoseconds(fromTicks: ticks, numer: timebase.numer, denom: timebase.denom)
            currentCPU[key] = nanos
            let identity = identities[key] ?? resolveIdentity(pid: pid, info: info)
            seen[key] = identity
            let percent = ProcessCPUMath.percent(previousNanos: previousCPU[key], currentNanos: nanos, elapsedNanos: elapsed)
            snapshots.append(ProcessSnapshot(
                pid: pid, parentPID: 0, name: identity.name, executablePath: identity.path,
                bundleURL: identity.bundleURL, bundleIdentifier: identity.bundleIdentifier, userID: 0,
                cpuPercent: percent, memoryBytes: info.ptinfo.pti_resident_size, threadCount: 0,
                startDate: nil, kind: .user
            ))
        }
        let hadBaseline = previousUptimeNanos != nil && elapsed > 0 && elapsed <= maxIntervalNanos
        previousCPU = currentCPU
        previousUptimeNanos = uptime
        identities = seen
        guard hadBaseline else { return nil }
        let apps = Self.topApps(ProcessGrouper.group(snapshots), limit: limit, footprint: ProcessReader.footprint(pid:))
        return UsageMinute(timestamp: now, seconds: Double(elapsed) / 1_000_000_000, apps: apps)
    }

    // MARK: - Assembly

    /// Merges groups sharing a history id, keeps the `limit` busiest with CPU > 0 and measures their
    /// memory as the members' physical footprint (resident size when that's unavailable).
    static func topApps(_ groups: [ProcessGroup], limit: Int, footprint: (Int32) -> UInt64?) -> [AppUsageSample] {
        struct Bucket {
            let id: String
            let members: [ProcessGroup]
            let cpu: Double
        }
        let buckets: [Bucket] = Dictionary(grouping: groups, by: historyID).map { id, members in
            Bucket(id: id, members: members, cpu: members.reduce(0.0) { $0 + $1.cpuPercent })
        }
        let ranked = buckets.filter { $0.cpu > 0 }
            .sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.id < $1.id }
            .prefix(limit)
        return ranked.map { bucket in
            let processes = bucket.members.flatMap { $0.processes }
            let memory = processes.reduce(UInt64(0)) { total, process in total &+ (footprint(process.pid) ?? process.memoryBytes) }
            let main = bucket.members[0]
            return AppUsageSample(id: bucket.id, name: main.name, bundlePath: main.bundleURL?.path,
                                  cpuPercent: bucket.cpu, memoryBytes: memory)
        }
    }

    /// Apps keep their `ProcessGroup` id; standalone tools use their executable path instead of the pid,
    /// so a tool that restarts (or runs twice) stays one history entry.
    static func historyID(_ group: ProcessGroup) -> String {
        guard group.bundleURL == nil else { return group.id }
        if let path = group.processes.first?.executablePath { return "exe:\(path)" }
        return "name:\(group.name)"
    }

    // MARK: - Reading

    private static func taskAllInfo(pid: Int32) -> proc_taskallinfo? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size ? info : nil
    }

    private func resolveIdentity(pid: Int32, info: proc_taskallinfo) -> Identity {
        let path = ProcessReader.executablePath(pid: pid)
        let shortName = ProcessReader.cString(fromTuple: info.pbsd.pbi_name)
        let name = ProcessReader.displayName(
            short: shortName.isEmpty ? ProcessReader.cString(fromTuple: info.pbsd.pbi_comm) : shortName, path: path
        )
        let bundleURL = path.flatMap(ProcessClassifier.outermostAppURL(forExecutablePath:))
        return Identity(name: name, path: path, bundleURL: bundleURL, bundleIdentifier: bundleURL.flatMap(bundleIdentifier(for:)))
    }

    /// Bundle identifier of an app bundle, cached per path (including misses).
    private func bundleIdentifier(for url: URL) -> String? {
        if let cached = bundleIdentifiers[url.path] { return cached }
        let identifier = Bundle(url: url)?.bundleIdentifier
        bundleIdentifiers[url.path] = identifier
        return identifier
    }
}
