import Foundation
import MonitorCore

// MARK: - Item

/// One row of the Processes list with every value the row and the query need, computed once per sample.
struct ProcessListItem: Identifiable, Hashable, Sendable {
    let group: ProcessGroup
    let category: ProcessFilter
    let cpuPercent: Double
    let memoryBytes: UInt64
    let threadCount: Int
    /// Unique listening ports of all members, ascending.
    let ports: [UInt16]
    /// Sum over members; zero until the first network read.
    let network: NetworkThroughput
    /// Per-member rates, only for members with a reading.
    let memberNetwork: [Int32: NetworkThroughput]
    /// True when any member runs as the current user.
    let isMine: Bool
    /// Second line under the name (catalog summary, member count, bundle id or PID).
    let subtitle: String
    /// Members in the active sort order; the query re-sorts them.
    private(set) var members: [ProcessSnapshot]

    var id: String { group.id }
    var mainPID: Int32 { group.processes.first?.pid ?? 0 }

    init(group: ProcessGroup, ports: [Int32: [ListeningPort]], appBundleIDs: Set<String>, currentUserID: UInt32,
         network: [Int32: NetworkThroughput] = [:]) {
        self.group = group
        category = ProcessFilter.category(of: group, appBundleIDs: appBundleIDs)
        cpuPercent = group.cpuPercent
        memoryBytes = group.memoryBytes
        threadCount = group.processes.reduce(0) { $0 + $1.threadCount }
        self.ports = group.listeningPorts(in: ports)
        memberNetwork = group.processes.reduce(into: [:]) { rates, process in
            if let rate = network[process.pid] { rates[process.pid] = rate }
        }
        self.network = NetworkThroughput(
            bytesInPerSecond: memberNetwork.values.reduce(0) { $0 + $1.bytesInPerSecond },
            bytesOutPerSecond: memberNetwork.values.reduce(0) { $0 + $1.bytesOutPerSecond }
        )
        isMine = group.processes.contains { $0.userID == currentUserID }
        subtitle = Self.subtitle(for: group)
        members = group.processes
    }

    /// A copy whose members follow `order`.
    func sortingMembers(_ order: ProcessSortOrder) -> ProcessListItem {
        guard members.count > 1 else { return self }
        var copy = self
        copy.members = members.sorted { ProcessListQuery.isOrdered($0, $1, by: order, network: memberNetwork) }
        return copy
    }

    private static func subtitle(for group: ProcessGroup) -> String {
        if let main = group.processes.first, let info = KnownProcessCatalog.info(forProcessNamed: main.name) {
            return String(localized: String.LocalizationValue(info.summary))
        }
        if group.processes.count > 1 { return String(localized: "\(group.processes.count) processes") }
        if let bundleID = group.bundleIdentifier { return bundleID }
        return group.processes.first.map { "PID \($0.pid)" } ?? ""
    }
}

// MARK: - Query

/// Category, chips, search and sort applied to the list; pure so it is easy to test.
struct ProcessListQuery: Equatable, Sendable {
    var filter: ProcessFilter = .apps
    var chips: Set<ProcessChip> = []
    var sort: ProcessSortOrder = .default
    var search = ""

    /// True when the category or a chip narrows the list (search has its own clear buttons).
    var isNarrowed: Bool { filter != .all || !chips.isEmpty }

    /// The same query with category and chips reset; search and sort stay.
    var cleared: ProcessListQuery {
        ProcessListQuery(filter: .all, chips: [], sort: sort, search: search)
    }

    func apply(to items: [ProcessListItem]) -> [ProcessListItem] {
        items
            .filter { filter.matches($0) && passesChipsAndSearch($0) }
            .sorted { Self.isOrdered($0, $1, by: sort) }
            .map { $0.sortingMembers(sort) }
    }

    /// Matches per category with the current chips and search, for the capsule badges.
    func counts(in items: [ProcessListItem]) -> [ProcessFilter: Int] {
        var counts = Dictionary(uniqueKeysWithValues: ProcessFilter.allCases.map { ($0, 0) })
        for item in items where passesChipsAndSearch(item) {
            counts[item.category, default: 0] += 1
            counts[.all, default: 0] += 1
        }
        return counts
    }

    func passesChipsAndSearch(_ item: ProcessListItem) -> Bool {
        chips.allSatisfy { $0.matches(item) } && matchesSearch(item)
    }

    /// Name, bundle id, member names, PID or listening port (":3000" or "3000").
    func matchesSearch(_ item: ProcessListItem) -> Bool {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        let group = item.group
        if group.name.localizedCaseInsensitiveContains(term) { return true }
        if group.bundleIdentifier?.localizedCaseInsensitiveContains(term) == true { return true }
        if group.processes.contains(where: { $0.name.localizedCaseInsensitiveContains(term) }) { return true }
        let number = term.hasPrefix(":") ? String(term.dropFirst()) : term
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return false }
        if group.processes.contains(where: { String($0.pid) == number }) { return true }
        return item.ports.contains { String($0).hasPrefix(number) }
    }

    // MARK: Ordering

    /// Primary column in the chosen direction, then name A→Z, then id, so equal rows never swap between samples.
    static func isOrdered(_ lhs: ProcessListItem, _ rhs: ProcessListItem, by order: ProcessSortOrder) -> Bool {
        let primary: ComparisonResult = switch order.key {
        case .name: compareNames(lhs.group.name, rhs.group.name)
        case .pid: compare(lhs.mainPID, rhs.mainPID)
        case .cpu: compare(lhs.cpuPercent, rhs.cpuPercent)
        case .memory: compare(lhs.memoryBytes, rhs.memoryBytes)
        case .threads: compare(lhs.threadCount, rhs.threadCount)
        case .ports: compare(lhs.ports.count, rhs.ports.count)
        case .network: compare(lhs.network.bytesPerSecond, rhs.network.bytesPerSecond)
        }
        if primary != .orderedSame { return (primary == .orderedAscending) == order.ascending }
        let name = compareNames(lhs.group.name, rhs.group.name)
        if name != .orderedSame { return name == .orderedAscending }
        return lhs.id < rhs.id
    }

    /// Member order inside an expanded group; ports have no per-member value, so they sort like name.
    /// `network` holds member rates; members without one count as idle.
    static func isOrdered(_ lhs: ProcessSnapshot, _ rhs: ProcessSnapshot, by order: ProcessSortOrder,
                          network: [Int32: NetworkThroughput] = [:]) -> Bool {
        let primary: ComparisonResult = switch order.key {
        case .name, .ports: compareNames(lhs.name, rhs.name)
        case .pid: compare(lhs.pid, rhs.pid)
        case .cpu: compare(lhs.cpuPercent, rhs.cpuPercent)
        case .memory: compare(lhs.memoryBytes, rhs.memoryBytes)
        case .threads: compare(lhs.threadCount, rhs.threadCount)
        case .network: compare(network[lhs.pid]?.bytesPerSecond ?? 0, network[rhs.pid]?.bytesPerSecond ?? 0)
        }
        if primary != .orderedSame { return (primary == .orderedAscending) == order.ascending }
        let name = compareNames(lhs.name, rhs.name)
        if name != .orderedSame { return name == .orderedAscending }
        return lhs.pid < rhs.pid
    }

    /// Keeps rows that were already visible in their previous position, updating their values;
    /// new rows follow in sorted order. Used while the pointer is over the list.
    static func preservingOrder(_ fresh: [ProcessListItem], previous ids: [String]) -> [ProcessListItem] {
        let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = ids.compactMap { byID[$0] }
        let keptIDs = Set(kept.map(\.id))
        return kept + fresh.filter { !keptIDs.contains($0.id) }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }

    private static func compareNames(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedStandardCompare(rhs)
    }
}
