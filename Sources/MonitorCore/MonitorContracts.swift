import Foundation

// Public contract shared by the monitor engine and the System / Processes screens.
// Change only additively: the UI is built against these shapes.

public enum MemoryPressure: String, Sendable, Hashable {
    case normal, warning, critical
}

public enum ThermalLevel: String, Sendable, Hashable {
    case nominal, fair, serious, critical
}

public struct MemoryStats: Sendable, Hashable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let pressure: MemoryPressure

    public init(totalBytes: UInt64, usedBytes: UInt64, appBytes: UInt64, wiredBytes: UInt64,
                compressedBytes: UInt64, swapUsedBytes: UInt64, pressure: MemoryPressure) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }
}

public struct DiskStats: Sendable, Hashable {
    public let totalBytes: Int64
    /// "Available for important usage" (includes purgeable space), like Finder shows.
    public let availableBytes: Int64

    public init(totalBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

public struct NetworkThroughput: Sendable, Hashable {
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double

    public init(bytesInPerSecond: Double, bytesOutPerSecond: Double) {
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
    }
}

public struct BatteryStats: Sendable, Hashable {
    /// 0...1
    public let level: Double
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let cycleCount: Int?
    /// Max capacity vs design capacity, 0...1, when IOKit reports it.
    public let health: Double?
    public let minutesRemaining: Int?

    public init(level: Double, isCharging: Bool, isPluggedIn: Bool, cycleCount: Int?, health: Double?, minutesRemaining: Int?) {
        self.level = level
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.cycleCount = cycleCount
        self.health = health
        self.minutesRemaining = minutesRemaining
    }
}

/// One sample of whole-machine state.
public struct SystemSnapshot: Sendable, Hashable {
    public let timestamp: Date
    /// 0...1 across all cores.
    public let cpuUsage: Double
    /// 0...1 per logical core.
    public let perCoreUsage: [Double]
    public let memory: MemoryStats
    public let disk: DiskStats
    public let network: NetworkThroughput
    /// Nil on Macs without a battery.
    public let battery: BatteryStats?
    public let thermal: ThermalLevel
    public let uptime: TimeInterval

    public init(timestamp: Date, cpuUsage: Double, perCoreUsage: [Double], memory: MemoryStats, disk: DiskStats,
                network: NetworkThroughput, battery: BatteryStats?, thermal: ThermalLevel, uptime: TimeInterval) {
        self.timestamp = timestamp
        self.cpuUsage = cpuUsage
        self.perCoreUsage = perCoreUsage
        self.memory = memory
        self.disk = disk
        self.network = network
        self.battery = battery
        self.thermal = thermal
        self.uptime = uptime
    }
}

/// How safe a process is to quit, from the known-process catalog and ownership.
public enum ProcessKind: String, Sendable, Hashable {
    /// A regular app or user tool: safe to quit.
    case user
    /// A macOS service that restarts on its own; quitting is usually harmless but pointless.
    case system
    /// Must never be terminated (kernel_task, launchd, WindowServer, loginwindow…).
    case critical
}

/// One running process at sample time.
public struct ProcessSnapshot: Identifiable, Sendable, Hashable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let parentPID: Int32
    public let name: String
    public let executablePath: String?
    /// Enclosing `.app` bundle, for grouping helpers under their app.
    public let bundleURL: URL?
    public let bundleIdentifier: String?
    public let userID: UInt32
    /// Percent of one core (can exceed 100 for multi-threaded processes), like Activity Monitor.
    public let cpuPercent: Double
    /// Physical footprint in bytes.
    public let memoryBytes: UInt64
    public let threadCount: Int
    public let startDate: Date?
    public let kind: ProcessKind

    public init(pid: Int32, parentPID: Int32, name: String, executablePath: String?, bundleURL: URL?,
                bundleIdentifier: String?, userID: UInt32, cpuPercent: Double, memoryBytes: UInt64,
                threadCount: Int, startDate: Date?, kind: ProcessKind) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.executablePath = executablePath
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.userID = userID
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.threadCount = threadCount
        self.startDate = startDate
        self.kind = kind
    }
}

/// An app with all of its helper processes, or a single standalone process.
public struct ProcessGroup: Identifiable, Sendable, Hashable {
    /// Bundle identifier, bundle path or "pid:<n>" for standalone processes.
    public let id: String
    public let name: String
    public let bundleURL: URL?
    public let bundleIdentifier: String?
    /// Main process first.
    public let processes: [ProcessSnapshot]
    public var cpuPercent: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    public var memoryBytes: UInt64 { processes.reduce(0) { $0 + $1.memoryBytes } }
    /// The most protective kind among members.
    public let kind: ProcessKind

    public init(id: String, name: String, bundleURL: URL?, bundleIdentifier: String?, processes: [ProcessSnapshot], kind: ProcessKind) {
        self.id = id
        self.name = name
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.processes = processes
        self.kind = kind
    }
}

/// A socket a process listens on.
public struct ListeningPort: Sendable, Hashable, Identifiable {
    public var id: String { "\(pid)-\(transport)-\(address):\(port)" }
    public let pid: Int32
    public let port: UInt16
    /// "TCP" or "UDP".
    public let transport: String
    /// "127.0.0.1", "*", "::1"…
    public let address: String

    public init(pid: Int32, port: UInt16, transport: String, address: String) {
        self.pid = pid
        self.port = port
        self.transport = transport
        self.address = address
    }
}

/// Human description of a well-known process ("mds_stores" → Spotlight indexing).
public struct KnownProcessInfo: Sendable, Hashable {
    /// English summary; the app localizes via its string catalog using this as the key.
    public let summary: String
    public let kind: ProcessKind

    public init(summary: String, kind: ProcessKind) {
        self.summary = summary
        self.kind = kind
    }
}

public protocol SystemSampling: Sendable {
    /// CPU and network values are deltas since the previous call; the first call may report 0.
    func sample() async -> SystemSnapshot
}

public protocol ProcessSampling: Sendable {
    /// CPU percentages are deltas since the previous call; the first call may report 0.
    func sample() async -> [ProcessSnapshot]
}

/// Per-process network rates. A read spawns a tool, far costlier than the other samplers,
/// so callers read it at a slower cadence and only while the rates are on screen.
public protocol ProcessNetworkSampling: Sendable {
    /// Bytes per second in and out per pid since the previous call. Nil when there is no usable
    /// previous read yet (first call, or the previous read is too old to average over).
    func sample() async -> [Int32: NetworkThroughput]?
}

public protocol PortScanning: Sendable {
    func listeningPorts() async -> [ListeningPort]
}

public enum TerminationMode: Sendable, Hashable {
    /// SIGTERM (apps get to save).
    case graceful
    /// SIGKILL.
    case force
}

public enum TerminationError: Error, Sendable, Hashable {
    /// Critical processes are refused before any signal is sent.
    case protectedProcess(String)
    case notPermitted
    case noSuchProcess
    case failed(Int32)
}

public protocol ProcessTerminating: Sendable {
    func terminate(_ process: ProcessSnapshot, mode: TerminationMode) async throws(TerminationError)
}
