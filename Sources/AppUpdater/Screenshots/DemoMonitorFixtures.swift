import Foundation
import MonitorCore

/// Made-up machine for the System and Processes screenshots: a 12-core, 32 GB laptop running the
/// demo apps plus generic macOS services. Values follow smooth deterministic curves, never the host.
enum DemoMonitorFixtures {
    static let coreCount = 12
    static let memoryTotal: UInt64 = 32 * 1_073_741_824
    static let diskTotal: Int64 = 994_662_584_320
    static let diskAvailable: Int64 = 412_860_000_000
    static let uptime: TimeInterval = 4 * 86_400 + 7 * 3600
    static let userID: UInt32 = 501

    /// Ticks recorded before the first shot, so every chart is full.
    static let warmUpTicks = 120

    struct Process {
        let pid: Int32
        let name: String
        /// Demo app the process belongs to (its bundle id), nil for standalone processes.
        let appBundleID: String?
        let cpu: Double
        let megabytes: Double
        let threads: Int
        var kind: ProcessKind = .user
        var userID: UInt32 = DemoMonitorFixtures.userID
        var parent: Int32 = 1
        /// Combined network rate (bytes/s) split 85% in, 15% out.
        var network: Double = 0
        var ports: [UInt16] = []
    }

    static let processes: [Process] = [
        Process(pid: 812, name: "Firefox", appBundleID: "org.mozilla.firefox", cpu: 18.4, megabytes: 1_240, threads: 96,
                network: 1_420_000),
        Process(pid: 845, name: "Firefox GPU Helper", appBundleID: "org.mozilla.firefox", cpu: 9.6, megabytes: 410, threads: 22,
                parent: 812),
        Process(pid: 851, name: "Firefox Web Content", appBundleID: "org.mozilla.firefox", cpu: 6.2, megabytes: 620, threads: 31,
                parent: 812),
        Process(pid: 903, name: "Slack", appBundleID: "com.tinyspeck.slackmacgap", cpu: 4.8, megabytes: 520, threads: 41,
                network: 46_000),
        Process(pid: 917, name: "Slack Helper (Renderer)", appBundleID: "com.tinyspeck.slackmacgap", cpu: 3.1, megabytes: 380,
                threads: 19, parent: 903),
        Process(pid: 1_022, name: "Code", appBundleID: "com.microsoft.VSCode", cpu: 7.9, megabytes: 860, threads: 54,
                network: 12_400),
        Process(pid: 1_031, name: "Code Helper (Plugin)", appBundleID: "com.microsoft.VSCode", cpu: 5.4, megabytes: 470, threads: 27,
                parent: 1_022),
        Process(pid: 1_204, name: "Docker", appBundleID: "com.docker.docker", cpu: 2.2, megabytes: 240, threads: 33,
                network: 8_200, ports: [5432, 6379]),
        Process(pid: 1_219, name: "com.docker.virtualization", appBundleID: "com.docker.docker", cpu: 22.6, megabytes: 3_420,
                threads: 18, parent: 1_204),
        Process(pid: 1_350, name: "Spotify", appBundleID: "com.spotify.client", cpu: 3.6, megabytes: 410, threads: 48,
                network: 318_000, ports: [57621]),
        Process(pid: 1_402, name: "zoom.us", appBundleID: "us.zoom.xos", cpu: 11.3, megabytes: 690, threads: 62,
                network: 402_000),
        Process(pid: 1_488, name: "Figma", appBundleID: "com.figma.Desktop", cpu: 6.7, megabytes: 930, threads: 37,
                network: 64_000),
        Process(pid: 1_533, name: "iTerm2", appBundleID: "com.googlecode.iterm2", cpu: 1.4, megabytes: 180, threads: 12),
        Process(pid: 1_560, name: "Rectangle", appBundleID: "com.knollsoft.Rectangle", cpu: 0.2, megabytes: 46, threads: 6),
        Process(pid: 1_611, name: "Obsidian", appBundleID: "md.obsidian", cpu: 0.9, megabytes: 310, threads: 24),
        Process(pid: 2_104, name: "node", appBundleID: nil, cpu: 4.1, megabytes: 260, threads: 11, parent: 1_533,
                network: 22_000, ports: [3000]),
        Process(pid: 2_188, name: "python3", appBundleID: nil, cpu: 1.2, megabytes: 98, threads: 4, parent: 1_533,
                ports: [8000]),
        Process(pid: 0, name: "kernel_task", appBundleID: nil, cpu: 6.8, megabytes: 120, threads: 540, kind: .critical,
                userID: 0, parent: 0),
        Process(pid: 1, name: "launchd", appBundleID: nil, cpu: 0.4, megabytes: 22, threads: 4, kind: .critical,
                userID: 0, parent: 0),
        Process(pid: 167, name: "WindowServer", appBundleID: nil, cpu: 8.9, megabytes: 610, threads: 23, kind: .critical,
                userID: 88),
        Process(pid: 402, name: "mds_stores", appBundleID: nil, cpu: 3.3, megabytes: 140, threads: 9, kind: .system, userID: 0),
        Process(pid: 388, name: "coreaudiod", appBundleID: nil, cpu: 1.1, megabytes: 36, threads: 12, kind: .system, userID: 202),
        Process(pid: 431, name: "bluetoothd", appBundleID: nil, cpu: 0.3, megabytes: 18, threads: 7, kind: .system, userID: 0),
        Process(pid: 455, name: "photoanalysisd", appBundleID: nil, cpu: 2.4, megabytes: 220, threads: 8, kind: .system),
    ]

    /// Smooth, repeatable wobble in -1...1 for tick `tick` and series `seed`.
    static func wave(_ tick: Int, seed: Double) -> Double {
        let t = Double(tick)
        return 0.6 * sin(t / 7.3 + seed) + 0.3 * sin(t / 2.9 + seed * 2.1) + 0.1 * sin(t * 1.7 + seed * 5.3)
    }

    static func systemSnapshot(tick: Int, now: Date) -> SystemSnapshot {
        let cpu = 0.27 + 0.11 * wave(tick, seed: 0.4)
        let usedFraction = 0.58 + 0.03 * wave(tick, seed: 2.2)
        let used = UInt64(Double(memoryTotal) * usedFraction)
        let networkIn = max(0, 1_650_000 + 900_000 * wave(tick, seed: 1.1))
        let networkOut = max(0, 240_000 + 140_000 * wave(tick, seed: 3.7))
        let perCore = (0..<coreCount).map { core in
            // Performance cores (first eight) busier than efficiency cores.
            let base = core < 8 ? cpu * 1.15 : cpu * 0.55
            return min(1, max(0.02, base + 0.12 * wave(tick, seed: Double(core) * 0.9)))
        }
        return SystemSnapshot(
            timestamp: now,
            cpuUsage: cpu,
            perCoreUsage: perCore,
            memory: MemoryStats(
                totalBytes: memoryTotal, usedBytes: used, appBytes: UInt64(Double(used) * 0.62),
                wiredBytes: 3_650_000_000, compressedBytes: 2_140_000_000, swapUsedBytes: 412_000_000,
                pressure: .normal
            ),
            disk: DiskStats(totalBytes: diskTotal, availableBytes: diskAvailable),
            network: NetworkThroughput(bytesInPerSecond: networkIn, bytesOutPerSecond: networkOut),
            battery: BatteryStats(level: 0.82, isCharging: false, isPluggedIn: false, cycleCount: 214, health: 0.93,
                                  minutesRemaining: 412),
            thermal: .nominal,
            uptime: uptime
        )
    }

    // MARK: Usage history

    struct UsageApp {
        let bundleID: String
        let name: String
        let cpu: Double
        let megabytes: Double
        /// Hours ago (start, end) of a sustained heavy stretch, if any.
        var busyStretch: (Double, Double)?
    }

    static let usageApps: [UsageApp] = [
        UsageApp(bundleID: "com.docker.docker", name: "Docker", cpu: 14, megabytes: 3_600, busyStretch: (3.2, 2.1)),
        UsageApp(bundleID: "org.mozilla.firefox", name: "Firefox", cpu: 21, megabytes: 2_300),
        UsageApp(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", cpu: 12, megabytes: 1_400),
        UsageApp(bundleID: "us.zoom.xos", name: "Zoom", cpu: 9, megabytes: 720),
        UsageApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", cpu: 6, megabytes: 910),
        UsageApp(bundleID: "com.spotify.client", name: "Spotify", cpu: 3, megabytes: 420),
        UsageApp(bundleID: "com.figma.Desktop", name: "Figma", cpu: 5, megabytes: 950),
    ]
}
