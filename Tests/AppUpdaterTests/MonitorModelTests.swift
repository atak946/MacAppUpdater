import Foundation
import MonitorCore
import Testing
@testable import AppUpdater

// MARK: - Fakes

/// Returns a CPU value that increases by 0.01 on every call.
private actor CountingSystemSampler: SystemSampling {
    private var calls = 0

    func sample() async -> SystemSnapshot {
        calls += 1
        return SystemSnapshot(
            timestamp: Date(), cpuUsage: Double(calls) / 100, perCoreUsage: [0.1, 0.2],
            memory: MemoryStats(totalBytes: 100, usedBytes: 25, appBytes: 10, wiredBytes: 5, compressedBytes: 2,
                                swapUsedBytes: 0, pressure: .normal),
            disk: DiskStats(totalBytes: 1000, availableBytes: 400),
            network: NetworkThroughput(bytesInPerSecond: Double(calls), bytesOutPerSecond: 0),
            battery: nil, thermal: .nominal, uptime: 3600
        )
    }
}

private struct FixedProcessSampler: ProcessSampling {
    let processes: [ProcessSnapshot]
    func sample() async -> [ProcessSnapshot] { processes }
}

private final class RecordingPortScanner: PortScanning, @unchecked Sendable {
    let ports: [ListeningPort]
    private let lock = NSLock()
    private var count = 0

    init(ports: [ListeningPort] = []) { self.ports = ports }

    var calls: Int { lock.withLock { count } }

    func listeningPorts() async -> [ListeningPort] {
        lock.withLock { count += 1 }
        return ports
    }
}

/// Replays scripted network reads (nil = baseline) and counts calls.
private final class ScriptedNetworkSampler: ProcessNetworkSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[Int32: NetworkThroughput]?]
    private var count = 0

    init(_ script: [[Int32: NetworkThroughput]?]) { self.script = script }

    var calls: Int { lock.withLock { count } }

    func sample() async -> [Int32: NetworkThroughput]? {
        lock.withLock {
            count += 1
            return script.isEmpty ? [:] : script.removeFirst()
        }
    }
}

private final class RecordingTerminator: ProcessTerminating, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(Int32, TerminationMode)] = []
    let error: TerminationError?

    init(error: TerminationError? = nil) { self.error = error }

    var calls: [(pid: Int32, mode: TerminationMode)] { lock.withLock { log.map { ($0.0, $0.1) } } }

    func terminate(_ process: ProcessSnapshot, mode: TerminationMode) async throws(TerminationError) {
        lock.withLock { log.append((process.pid, mode)) }
        if let error { throw error }
    }
}

private func process(_ pid: Int32, _ name: String, cpu: Double = 0, memory: UInt64 = 0, kind: ProcessKind = .user) -> ProcessSnapshot {
    ProcessSnapshot(pid: pid, parentPID: 1, name: name, executablePath: nil, bundleURL: nil, bundleIdentifier: nil,
                    userID: 501, cpuPercent: cpu, memoryBytes: memory, threadCount: 1, startDate: nil, kind: kind)
}

private func group(
    _ id: String, name: String, processes: [ProcessSnapshot], kind: ProcessKind = .user, isApp: Bool = true
) -> ProcessGroup {
    ProcessGroup(
        id: id, name: name,
        bundleURL: isApp ? URL(fileURLWithPath: "/Applications/\(name).app") : nil,
        bundleIdentifier: isApp ? "com.example.\(name.lowercased())" : nil,
        processes: processes, kind: kind
    )
}

// MARK: - Tests

@MainActor
@Suite("MonitorModel")
struct MonitorModelTests {
    private static func model(
        processes: [ProcessSnapshot] = [], ports: RecordingPortScanner = RecordingPortScanner(),
        network: ScriptedNetworkSampler? = nil, terminator: RecordingTerminator = RecordingTerminator()
    ) -> MonitorModel {
        MonitorModel(
            system: CountingSystemSampler(), processes: FixedProcessSampler(processes: processes),
            ports: ports, network: network, terminator: terminator, interval: .seconds(3600)
        )
    }

    @Test("history keeps only the newest samples up to capacity")
    func ringBuffer() {
        var history = SampleHistory(capacity: 3)
        for value in [1.0, 2, 3, 4, 5] { history.append(value) }

        #expect(history.values == [3, 4, 5])
        #expect(history.latest == 5)
        #expect(history.peak == 5)
    }

    @Test("sampling records snapshot and histories; processes only when demanded")
    func sampling() async {
        let model = Self.model(processes: [process(10, "zsh")])

        await model.sampleOnce(including: .system)
        #expect(model.snapshot?.cpuUsage == 0.01)
        #expect(model.cpuHistory.values == [0.01])
        #expect(model.memoryHistory.values == [0.25])
        #expect(model.processList.isEmpty)
        #expect(!model.hasProcessSample)

        await model.sampleOnce(including: .processes)
        #expect(model.cpuHistory.values.count == 2)
        #expect(model.networkInHistory.values == [1, 2])
        #expect(model.processList.map(\.pid) == [10])
        #expect(model.hasProcessSample)
    }

    @Test("ports are rescanned at most every port interval")
    func portThrottle() async {
        let scanner = RecordingPortScanner(ports: [ListeningPort(pid: 10, port: 3000, transport: "TCP", address: "*")])
        let model = Self.model(ports: scanner)
        let start = Date()

        await model.sampleOnce(including: .ports, now: start)
        await model.sampleOnce(including: .ports, now: start.addingTimeInterval(2))
        await model.sampleOnce(including: .processes, now: start.addingTimeInterval(10))
        await model.sampleOnce(including: .ports, now: start.addingTimeInterval(6))

        #expect(scanner.calls == 2)
        #expect(model.portsByPID[10]?.map(\.port) == [3000])
    }

    @Test("network is read only on the Processes page, every network interval, retrying after a baseline")
    func networkCadence() async {
        let rate = NetworkThroughput(bytesInPerSecond: 300, bytesOutPerSecond: 100)
        let network = ScriptedNetworkSampler([nil, [10: rate], [:]])
        let model = Self.model(processes: [process(10, "curl"), process(11, "zsh")], network: network)
        model.listQuery = ProcessListQuery(filter: .all)
        let start = Date()

        await model.sampleOnce(including: .processes, now: start)
        #expect(network.calls == 0)

        await model.sampleOnce(including: .ports, now: start)
        #expect(network.calls == 1)
        #expect(model.networkByPID.isEmpty)

        // The baseline read is retried on the next tick, then the cadence slows down.
        await model.sampleOnce(including: .ports, now: start.addingTimeInterval(2))
        #expect(network.calls == 2)
        #expect(model.networkByPID[10] == rate)
        #expect(model.visibleItems.first { $0.id == "pid:10" }?.network == rate)

        await model.sampleOnce(including: .ports, now: start.addingTimeInterval(4))
        #expect(network.calls == 2)
        await model.sampleOnce(including: .ports, now: start.addingTimeInterval(8))
        #expect(network.calls == 3)
        #expect(model.networkByPID.isEmpty)
    }

    @Test("observation is reference counted and stops when the last observer leaves")
    func observation() {
        let model = Self.model()

        model.beginObserving(.system)
        model.beginObserving(.ports)
        #expect(model.isSampling)
        #expect(model.currentDemand == .ports)

        model.endObserving(.ports)
        #expect(model.currentDemand == .system)
        #expect(model.isSampling)

        model.endObserving(.system)
        #expect(model.currentDemand == nil)
        #expect(!model.isSampling)
    }

    @Test("model precomputes list rows and counts and re-sorts on query changes")
    func listPipeline() async {
        let list = [process(1, "zsh", cpu: 1), process(2, "node", cpu: 9)]
        let scanner = RecordingPortScanner(ports: [ListeningPort(pid: 2, port: 3000, transport: "TCP", address: "*")])
        let model = Self.model(processes: list, ports: scanner)
        model.listQuery = ProcessListQuery(filter: .all)

        await model.sampleOnce(including: .ports)
        #expect(model.visibleItems.map(\.group.name) == ["node", "zsh"])
        #expect(model.visibleItems.first?.ports == [3000])
        #expect(model.filterCounts[.all] == 2)

        model.listQuery.sort = ProcessSortOrder(key: .name, ascending: false)
        #expect(model.visibleItems.map(\.group.name) == ["zsh", "node"])
        model.listQuery.chips = [.hasPorts]
        #expect(model.visibleItems.map(\.group.name) == ["node"])
        #expect(model.topGroups(1).map(\.name) == ["node"])
    }

    @Test("critical groups and processes are never signalled")
    func terminateGuard() async {
        let terminator = RecordingTerminator()
        let model = Self.model(terminator: terminator)
        let critical = group("w", name: "WindowServer", processes: [process(3, "WindowServer", kind: .critical)], kind: .critical)

        await model.terminate(critical, mode: .force)
        await model.terminate(process(1, "launchd", kind: .critical), mode: .graceful)

        #expect(terminator.calls.isEmpty)
        #expect(!model.canTerminate(critical))
        #expect(model.errorMessage != nil)
    }

    @Test("graceful quits the main process, force kills every member and drops them")
    func terminateModes() async {
        let members = [process(20, "App"), process(21, "App Helper"), process(22, "App Helper (GPU)")]
        let terminator = RecordingTerminator()
        let model = Self.model(processes: members, terminator: terminator)
        await model.sampleOnce(including: .processes)
        let app = group("app", name: "App", processes: members)

        await model.terminate(app, mode: .graceful)
        #expect(terminator.calls.map(\.pid) == [20])
        #expect(terminator.calls.first?.mode == .graceful)

        await model.terminate(app, mode: .force)
        #expect(terminator.calls.map(\.pid) == [20, 20, 21, 22])
        #expect(model.processList.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test("permission failures surface a message; vanished processes do not")
    func terminateErrors() async {
        let denied = Self.model(terminator: RecordingTerminator(error: .notPermitted))
        let gone = Self.model(terminator: RecordingTerminator(error: .noSuchProcess))
        let target = process(30, "backupd")

        await denied.terminate(target, mode: .graceful)
        await gone.terminate(target, mode: .graceful)

        #expect(denied.errorMessage == MonitorModel.message(for: .notPermitted, name: "backupd"))
        #expect(gone.errorMessage == nil)
    }
}
