import Foundation
import MonitorCore

/// The group open in the Processes inspector, with its latest row values and a short CPU/memory history.
/// Only the selected group keeps a history, so sampling cost stays flat however many processes run.
struct ProcessSelection: Equatable, Sendable {
    /// Samples kept per sparkline (~90 s at the default 1.5 s interval).
    static let historyCapacity = 60

    let groupID: String
    /// Latest values; while the group is gone this keeps the last values seen.
    private(set) var item: ProcessListItem
    /// Listening sockets of every member, by port then transport.
    private(set) var ports: [ListeningPort]
    /// False once the group vanished from the latest process sample.
    private(set) var isRunning = true
    /// Group CPU, percent of one core.
    private(set) var cpuHistory = SampleHistory(capacity: historyCapacity)
    /// Group physical footprint in bytes.
    private(set) var memoryHistory = SampleHistory(capacity: historyCapacity)

    /// Starts a selection seeded with the item's current values.
    init(item: ProcessListItem, portsByPID: [Int32: [ListeningPort]]) {
        groupID = item.id
        self.item = item
        ports = Self.ports(of: item.group, in: portsByPID)
        record()
    }

    // MARK: Updates

    /// Refreshes values from a fresh list. `recordsSample` is true for process samples
    /// and false for port-only rescans, so the history ticks once per sample.
    mutating func update(from items: [ProcessListItem], portsByPID: [Int32: [ListeningPort]], recordsSample: Bool) {
        guard let fresh = items.first(where: { $0.id == groupID }) else {
            isRunning = false
            return
        }
        item = fresh
        isRunning = true
        ports = Self.ports(of: fresh.group, in: portsByPID)
        if recordsSample { record() }
    }

    private mutating func record() {
        cpuHistory.append(item.cpuPercent)
        memoryHistory.append(Double(item.memoryBytes))
    }

    private static func ports(of group: ProcessGroup, in portsByPID: [Int32: [ListeningPort]]) -> [ListeningPort] {
        let all = group.processes.flatMap { portsByPID[$0.pid] ?? [] }
        let unique = Dictionary(all.map { ("\($0.transport):\($0.port)", $0) }, uniquingKeysWith: { first, _ in first })
        return unique.values.sorted { ($0.port, $0.transport) < ($1.port, $1.transport) }
    }
}

// MARK: - Search

extension ProcessListQuery {
    /// The Processes page field wins while it has text; otherwise the sidebar search applies.
    static func effectiveSearch(page: String, sidebar: String) -> String {
        page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sidebar : page
    }
}
