import AppKit
import MonitorCore
import Observation
import os

/// Samples system and process state for the System and Processes screens and the menu bar.
/// Sampling runs only while at least one observer (page or popover) is visible.
@MainActor
@Observable
final class MonitorModel {
    static let historyCapacity = 120

    // MARK: State

    private(set) var snapshot: SystemSnapshot?
    private(set) var cpuHistory = SampleHistory(capacity: historyCapacity)
    private(set) var memoryHistory = SampleHistory(capacity: historyCapacity)
    private(set) var networkInHistory = SampleHistory(capacity: historyCapacity)
    private(set) var networkOutHistory = SampleHistory(capacity: historyCapacity)
    private(set) var processList: [ProcessSnapshot] = []
    private(set) var groups: [ProcessGroup] = []
    private(set) var portsByPID: [Int32: [ListeningPort]] = [:]
    /// Bundle ids of running regular apps, so Finder counts as an app in the "Apps" filter.
    private(set) var regularAppBundleIDs: Set<String> = []
    /// True once the first process sample arrived (distinguishes "loading" from "empty").
    private(set) var hasProcessSample = false
    /// Every group as a precomputed list row, in sampler order.
    private(set) var listItems: [ProcessListItem] = []
    /// `listItems` after `listQuery`, ready for the Processes list.
    private(set) var visibleItems: [ProcessListItem] = []
    /// Matches per category for the filter capsule badges.
    private(set) var filterCounts: [ProcessFilter: Int] = [:]
    /// Filter, chips, sort and search of the Processes list; the view keeps it in sync with its settings.
    var listQuery = ProcessListQuery() {
        didSet { if listQuery != oldValue { refreshVisible(keepingOrder: false) } }
    }
    /// While true (pointer over the list) new samples update values but keep the row order.
    var isOrderFrozen = false {
        didSet { if oldValue && !isOrderFrozen { refreshVisible(keepingOrder: false) } }
    }
    /// Group shown in the Processes inspector; nil while the inspector is closed.
    private(set) var selection: ProcessSelection?
    /// Last termination failure, shown as an alert; the view clears it.
    var errorMessage: String?

    private let system: any SystemSampling
    private let processes: any ProcessSampling
    private let ports: any PortScanning
    private let terminator: any ProcessTerminating
    private let interval: Duration
    private let portInterval: TimeInterval
    private let currentUserID: UInt32
    private let logger = Logger(subsystem: "com.macappupdater", category: "MonitorModel")

    @ObservationIgnored private var demandCounts: [MonitorDemand: Int] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastPortScan: Date = .distantPast
    @ObservationIgnored private var iconCache: [URL: NSImage] = [:]

    init(
        system: any SystemSampling,
        processes: any ProcessSampling,
        ports: any PortScanning,
        terminator: any ProcessTerminating,
        interval: Duration = .milliseconds(1500),
        portInterval: TimeInterval = 5,
        currentUserID: UInt32 = getuid()
    ) {
        self.currentUserID = currentUserID
        self.system = system
        self.processes = processes
        self.ports = ports
        self.terminator = terminator
        self.interval = interval
        self.portInterval = portInterval
    }

    // MARK: Observation

    var isSampling: Bool { loop != nil }

    /// The highest demand of all visible observers, nil when nothing is visible.
    var currentDemand: MonitorDemand? {
        demandCounts.filter { $0.value > 0 }.keys.max()
    }

    /// Call from `.onAppear`; balanced by `endObserving(_:)`.
    func beginObserving(_ demand: MonitorDemand = .system) {
        demandCounts[demand, default: 0] += 1
        start()
    }

    func endObserving(_ demand: MonitorDemand = .system) {
        demandCounts[demand] = max(0, (demandCounts[demand] ?? 0) - 1)
        if currentDemand == nil { stop() }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self, interval] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleOnce(including: self.currentDemand ?? .system)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: Sampling

    /// One tick: system stats always, processes and ports when `demand` asks for them.
    func sampleOnce(including demand: MonitorDemand, now: Date = Date()) async {
        let wantsProcesses = demand >= .processes
        async let systemSample = system.sample()
        async let processSample: [ProcessSnapshot]? = wantsProcesses ? processes.sample() : nil
        record(await systemSample)
        if let list = await processSample { apply(list) }

        guard demand >= .ports, now.timeIntervalSince(lastPortScan) >= portInterval else { return }
        lastPortScan = now
        let listening = await ports.listeningPorts()
        portsByPID = Dictionary(grouping: listening, by: \.pid)
        rebuildListItems()
    }

    private func record(_ sample: SystemSnapshot) {
        snapshot = sample
        cpuHistory.append(sample.cpuUsage)
        memoryHistory.append(Self.usedFraction(sample.memory))
        networkInHistory.append(sample.network.bytesInPerSecond)
        networkOutHistory.append(sample.network.bytesOutPerSecond)
    }

    private func apply(_ list: [ProcessSnapshot]) {
        processList = list
        groups = ProcessGrouper.group(list)
        hasProcessSample = true
        regularAppBundleIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.bundleIdentifier)
        )
        rebuildListItems(recordsSample: true)
    }

    /// Precomputes row values once per sample so list rows do no work in `body`.
    private func rebuildListItems(recordsSample: Bool = false) {
        listItems = groups.map {
            ProcessListItem(group: $0, ports: portsByPID, appBundleIDs: regularAppBundleIDs, currentUserID: currentUserID)
        }
        selection?.update(from: listItems, portsByPID: portsByPID, recordsSample: recordsSample)
        refreshVisible(keepingOrder: isOrderFrozen)
    }

    private func refreshVisible(keepingOrder: Bool) {
        let fresh = listQuery.apply(to: listItems)
        visibleItems = keepingOrder ? ProcessListQuery.preservingOrder(fresh, previous: visibleItems.map(\.id)) : fresh
        filterCounts = listQuery.counts(in: listItems)
    }

    static func usedFraction(_ memory: MemoryStats) -> Double {
        guard memory.totalBytes > 0 else { return 0 }
        return min(1, Double(memory.usedBytes) / Double(memory.totalBytes))
    }

    // MARK: Selection

    /// Opens the inspector for a group; re-selecting the open group keeps its history, nil closes it.
    func select(_ groupID: String?) {
        guard let groupID else {
            selection = nil
            return
        }
        guard selection?.groupID != groupID else { return }
        selection = listItems.first { $0.id == groupID }.map { ProcessSelection(item: $0, portsByPID: portsByPID) }
    }

    // MARK: Derived

    func topGroups(_ limit: Int = 5) -> [ProcessGroup] {
        let query = ProcessListQuery(filter: .all, sort: ProcessSortOrder(key: .cpu, ascending: false))
        return Array(query.apply(to: listItems).prefix(limit).map(\.group))
    }

    var totalProcessCPU: Double { processList.reduce(0) { $0 + $1.cpuPercent } }

    /// App icon for a bundle, cached; nil for bundle-less processes.
    func icon(for group: ProcessGroup) -> NSImage? {
        guard let url = group.bundleURL else { return nil }
        if let cached = iconCache[url] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[url] = image
        return image
    }

    // MARK: Termination

    func canTerminate(_ group: ProcessGroup) -> Bool {
        group.kind != .critical && group.processes.contains(where: canTerminate)
    }

    func canTerminate(_ process: ProcessSnapshot) -> Bool {
        process.kind != .critical
    }

    /// Graceful quits the main process (helpers follow it); force kills every member.
    func terminate(_ group: ProcessGroup, mode: TerminationMode) async {
        guard canTerminate(group) else {
            errorMessage = Self.message(for: .protectedProcess(group.name), name: group.name)
            return
        }
        let members = group.processes.filter(canTerminate)
        let targets = mode == .graceful ? Array(members.prefix(1)) : members
        var terminated: Set<Int32> = []
        for process in targets where await send(process, mode: mode, displayName: group.name) {
            terminated.insert(process.pid)
        }
        removeOptimistically(terminated)
    }

    func terminate(_ process: ProcessSnapshot, mode: TerminationMode) async {
        guard canTerminate(process) else {
            errorMessage = Self.message(for: .protectedProcess(process.name), name: process.name)
            return
        }
        if await send(process, mode: mode, displayName: process.name) { removeOptimistically([process.pid]) }
    }

    /// Returns true when the process is gone or was signalled.
    private func send(_ process: ProcessSnapshot, mode: TerminationMode, displayName: String) async -> Bool {
        do {
            try await terminator.terminate(process, mode: mode)
            return true
        } catch .noSuchProcess {
            return true
        } catch {
            logger.error("Terminate \(process.pid) failed: \(String(describing: error), privacy: .public)")
            errorMessage = Self.message(for: error, name: displayName)
            return false
        }
    }

    /// Drops killed processes right away; the next sample reconciles.
    private func removeOptimistically(_ pids: Set<Int32>) {
        guard !pids.isEmpty else { return }
        apply(processList.filter { !pids.contains($0.pid) })
    }

    static func message(for error: TerminationError, name: String) -> String {
        switch error {
        case .protectedProcess:
            String(localized: "\(name) is protected by macOS and can't be quit.")
        case .notPermitted:
            String(localized: "You don't have permission to quit \(name).")
        case .noSuchProcess:
            String(localized: "\(name) is no longer running.")
        case .failed(let code):
            String(localized: "Couldn't quit \(name) (error \(Int(code))).")
        }
    }
}
