import Darwin
import Foundation

/// Samples all running processes. Keeps the previous CPU times to report per-process CPU %.
public actor LiveProcessSampler: ProcessSampling {
    /// Identity of a process across samples: pid plus start time, so reused pids do not mix.
    private struct ProcessKey: Hashable {
        let pid: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private var previousCPU: [ProcessKey: UInt64] = [:]
    private var previousWallNanos: UInt64?
    private var bundleIdentifiers: [String: String?] = [:]
    private let timebase: mach_timebase_info_data_t

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info
    }

    public func sample() async -> [ProcessSnapshot] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousWallNanos.map { now &- $0 } ?? 0
        var currentCPU: [ProcessKey: UInt64] = [:]
        let snapshots = ProcessReader.allPIDs().compactMap { pid -> ProcessSnapshot? in
            guard let raw = ProcessReader.read(pid: pid) else { return nil }
            return snapshot(from: raw, elapsedNanos: elapsed, currentCPU: &currentCPU)
        }
        previousCPU = currentCPU
        previousWallNanos = now
        return snapshots
    }

    // MARK: - Assembly

    private func snapshot(from raw: RawProcessInfo, elapsedNanos: UInt64,
                          currentCPU: inout [ProcessKey: UInt64]) -> ProcessSnapshot {
        let key = ProcessKey(pid: raw.pid, startSeconds: raw.startSeconds, startMicroseconds: raw.startMicroseconds)
        var cpuPercent = 0.0
        if let ticks = raw.cpuTimeTicks {
            let nanos = ProcessCPUMath.nanoseconds(fromTicks: ticks, numer: timebase.numer, denom: timebase.denom)
            cpuPercent = ProcessCPUMath.percent(previousNanos: previousCPU[key], currentNanos: nanos, elapsedNanos: elapsedNanos)
            currentCPU[key] = nanos
        }
        let bundleURL = raw.path.flatMap(ProcessClassifier.outermostAppURL(forExecutablePath:))
        let startDate = raw.startSeconds > 0
            ? Date(timeIntervalSince1970: TimeInterval(raw.startSeconds) + TimeInterval(raw.startMicroseconds) / 1_000_000)
            : nil
        return ProcessSnapshot(
            pid: raw.pid, parentPID: raw.parentPID, name: raw.name, executablePath: raw.path,
            bundleURL: bundleURL, bundleIdentifier: bundleURL.flatMap(bundleIdentifier(for:)),
            userID: raw.userID, cpuPercent: cpuPercent, memoryBytes: raw.footprintBytes,
            threadCount: raw.threadCount, startDate: startDate,
            kind: ProcessClassifier.kind(name: raw.name, path: raw.path, userID: raw.userID, pid: raw.pid)
        )
    }

    /// Bundle identifier of an app bundle, cached per path (including misses).
    private func bundleIdentifier(for url: URL) -> String? {
        if let cached = bundleIdentifiers[url.path] { return cached }
        let identifier = Bundle(url: url)?.bundleIdentifier
        bundleIdentifiers[url.path] = identifier
        return identifier
    }
}
