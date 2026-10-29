import Foundation
import MonitorCore
import Testing
@testable import AppUpdater

// MARK: - Fakes

private struct IdleSystemSampler: SystemSampling {
    func sample() async -> SystemSnapshot {
        SystemSnapshot(
            timestamp: Date(), cpuUsage: 0, perCoreUsage: [],
            memory: MemoryStats(totalBytes: 100, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0,
                                swapUsedBytes: 0, pressure: .normal),
            disk: DiskStats(totalBytes: 1, availableBytes: 1),
            network: NetworkThroughput(bytesInPerSecond: 0, bytesOutPerSecond: 0),
            battery: nil, thermal: .nominal, uptime: 1
        )
    }
}

/// Returns whatever list the test set last.
private actor ScriptedProcessSampler: ProcessSampling {
    private var list: [ProcessSnapshot] = []

    func set(_ processes: [ProcessSnapshot]) { list = processes }
    func sample() async -> [ProcessSnapshot] { list }
}

private struct StaticPortScanner: PortScanning {
    let ports: [ListeningPort]
    func listeningPorts() async -> [ListeningPort] { ports }
}

private struct NoopTerminator: ProcessTerminating {
    func terminate(_ process: ProcessSnapshot, mode: TerminationMode) async throws(TerminationError) {}
}

private func process(_ pid: Int32, _ name: String, cpu: Double = 0, memory: UInt64 = 0) -> ProcessSnapshot {
    ProcessSnapshot(pid: pid, parentPID: 1, name: name, executablePath: nil, bundleURL: nil, bundleIdentifier: nil,
                    userID: 501, cpuPercent: cpu, memoryBytes: memory, threadCount: 2, startDate: nil, kind: .user)
}

private func item(_ process: ProcessSnapshot) -> ProcessListItem {
    let group = ProcessGroup(id: "pid:\(process.pid)", name: process.name, bundleURL: nil, bundleIdentifier: nil,
                             processes: [process], kind: process.kind)
    return ProcessListItem(group: group, ports: [:], appBundleIDs: [], currentUserID: 501)
}

// MARK: - Tests

@MainActor
@Suite("Process selection")
struct ProcessSelectionTests {
    private let sampler = ScriptedProcessSampler()

    private func model(ports: [ListeningPort] = []) -> MonitorModel {
        MonitorModel(
            system: IdleSystemSampler(), processes: sampler, ports: StaticPortScanner(ports: ports),
            terminator: NoopTerminator(), interval: .seconds(3600), portInterval: 0
        )
    }

    @Test("selecting a group seeds its history with the current values")
    func selectSeeds() async {
        await sampler.set([process(10, "node", cpu: 12, memory: 400)])
        let model = model()
        await model.sampleOnce(including: .processes)

        model.select("pid:10")

        #expect(model.selection?.groupID == "pid:10")
        #expect(model.selection?.isRunning == true)
        #expect(model.selection?.cpuHistory.values == [12])
        #expect(model.selection?.memoryHistory.values == [400])
    }

    @Test("unknown ids select nothing; nil closes the inspector")
    func selectUnknownAndClose() async {
        await sampler.set([process(10, "node")])
        let model = model()
        await model.sampleOnce(including: .processes)

        model.select("pid:99")
        #expect(model.selection == nil)

        model.select("pid:10")
        model.select(nil)
        #expect(model.selection == nil)
    }

    @Test("each process sample appends once; port-only rescans refresh without recording")
    func historyTicksPerSample() async {
        await sampler.set([process(10, "node", cpu: 1, memory: 100)])
        let model = model(ports: [ListeningPort(pid: 10, port: 3000, transport: "TCP", address: "*")])
        await model.sampleOnce(including: .processes)
        model.select("pid:10")

        await sampler.set([process(10, "node", cpu: 5, memory: 200)])
        await model.sampleOnce(including: .ports)

        #expect(model.selection?.cpuHistory.values == [1, 5])
        #expect(model.selection?.memoryHistory.values == [100, 200])
        #expect(model.selection?.ports.map(\.port) == [3000])
        #expect(model.selection?.item.cpuPercent == 5)
    }

    @Test("re-selecting the open group keeps its history; another group starts fresh")
    func reselect() async {
        await sampler.set([process(10, "node", cpu: 1), process(11, "zsh", cpu: 3)])
        let model = model()
        await model.sampleOnce(including: .processes)
        model.select("pid:10")
        await model.sampleOnce(including: .processes)

        model.select("pid:10")
        #expect(model.selection?.cpuHistory.values.count == 2)

        model.select("pid:11")
        #expect(model.selection?.groupID == "pid:11")
        #expect(model.selection?.cpuHistory.values == [3])
    }

    @Test("a vanished group is marked ended, keeps its last values and recovers if it returns")
    func endedGroup() async {
        await sampler.set([process(10, "node", cpu: 7)])
        let model = model()
        await model.sampleOnce(including: .processes)
        model.select("pid:10")

        await sampler.set([])
        await model.sampleOnce(including: .processes)
        #expect(model.selection?.isRunning == false)
        #expect(model.selection?.item.group.name == "node")
        #expect(model.selection?.cpuHistory.values == [7])

        await sampler.set([process(10, "node", cpu: 2)])
        await model.sampleOnce(including: .processes)
        #expect(model.selection?.isRunning == true)
        #expect(model.selection?.cpuHistory.values == [7, 2])
    }

    @Test("history is bounded to the sparkline capacity")
    func historyCapacity() {
        var selection = ProcessSelection(item: item(process(10, "node")), portsByPID: [:])
        for cpu in 1...(ProcessSelection.historyCapacity + 10) {
            selection.update(from: [item(process(10, "node", cpu: Double(cpu)))], portsByPID: [:], recordsSample: true)
        }

        #expect(selection.cpuHistory.values.count == ProcessSelection.historyCapacity)
        #expect(selection.cpuHistory.latest == Double(ProcessSelection.historyCapacity + 10))
    }

    @Test("ports are unique per transport and sorted", arguments: [false, true])
    func portOrdering(reversed: Bool) {
        let raw = [
            ListeningPort(pid: 10, port: 8080, transport: "TCP", address: "*"),
            ListeningPort(pid: 10, port: 3000, transport: "UDP", address: "*"),
            ListeningPort(pid: 10, port: 3000, transport: "TCP", address: "127.0.0.1"),
            ListeningPort(pid: 10, port: 3000, transport: "TCP", address: "::1"),
        ]
        let ports = reversed ? Array(raw.reversed()) : raw
        let selection = ProcessSelection(item: item(process(10, "node")), portsByPID: [10: ports])

        #expect(selection.ports.map { "\($0.port)/\($0.transport)" } == ["3000/TCP", "3000/UDP", "8080/TCP"])
    }

    @Test("page search wins while it has text, otherwise the sidebar search applies")
    func searchPrecedence() {
        #expect(ProcessListQuery.effectiveSearch(page: "node", sidebar: "zsh") == "node")
        #expect(ProcessListQuery.effectiveSearch(page: "  ", sidebar: "zsh") == "zsh")
        #expect(ProcessListQuery.effectiveSearch(page: "", sidebar: "") == "")
    }
}
