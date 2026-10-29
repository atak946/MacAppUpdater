import Foundation
import MonitorCore

// MARK: - Category filter

/// Which category of groups the Processes list shows. Apps, Background and System are disjoint; All is their union.
enum ProcessFilter: String, CaseIterable, Identifiable, Sendable {
    case apps, background, system, all

    var id: Self { self }

    var title: String {
        switch self {
        case .apps: String(localized: "Apps")
        case .background: String(localized: "Background")
        case .system: String(localized: "System")
        case .all: String(localized: "All")
        }
    }

    var help: String {
        switch self {
        case .apps: String(localized: "Apps you can see in the Dock")
        case .background: String(localized: "Your helpers, agents and command line tools")
        case .system: String(localized: "macOS services and protected processes")
        case .all: String(localized: "Every running process")
        }
    }

    func matches(_ item: ProcessListItem) -> Bool {
        self == .all || item.category == self
    }

    /// The category a group belongs to. `appBundleIDs` are regular (Dock) apps, so Finder counts as an app.
    static func category(of group: ProcessGroup, appBundleIDs: Set<String>) -> ProcessFilter {
        if let bundleID = group.bundleIdentifier, appBundleIDs.contains(bundleID) { return .apps }
        if group.bundleURL != nil && group.kind == .user { return .apps }
        return group.kind == .user ? .background : .system
    }
}

// MARK: - Chips

/// Toggleable narrowing chips; active chips combine with AND.
enum ProcessChip: String, CaseIterable, Identifiable, Sendable {
    case highCPU, highMemory, hasPorts, mine

    var id: Self { self }

    /// Percent of one core.
    static let cpuThreshold: Double = 5
    /// 500 MB, binary like the memory column.
    static let memoryThreshold: UInt64 = 500 * 1024 * 1024

    var title: String {
        switch self {
        case .highCPU: String(localized: "CPU > \(MonitorFormat.cpu(Self.cpuThreshold))")
        case .highMemory: String(localized: "Memory > \(MonitorFormat.bytes(Self.memoryThreshold))")
        case .hasPorts: String(localized: "Open ports")
        case .mine: String(localized: "Mine only")
        }
    }

    var symbol: String {
        switch self {
        case .highCPU: "cpu"
        case .highMemory: "memorychip"
        case .hasPorts: "network"
        case .mine: "person.fill"
        }
    }

    func matches(_ item: ProcessListItem) -> Bool {
        switch self {
        case .highCPU: item.cpuPercent > Self.cpuThreshold
        case .highMemory: item.memoryBytes > Self.memoryThreshold
        case .hasPorts: !item.ports.isEmpty
        case .mine: item.isMine
        }
    }

    /// Comma separated raw values, for `@AppStorage`.
    static func encode(_ chips: Set<ProcessChip>) -> String {
        allCases.filter(chips.contains).map(\.rawValue).joined(separator: ",")
    }

    static func decode(_ raw: String) -> Set<ProcessChip> {
        Set(raw.split(separator: ",").compactMap { ProcessChip(rawValue: String($0)) })
    }
}

// MARK: - Sorting

/// Sortable columns of the Processes list. PID sorts groups by their main process.
enum ProcessSortKey: String, CaseIterable, Identifiable, Sendable {
    case name, pid, cpu, memory, threads, ports

    var id: Self { self }

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .pid: String(localized: "PID")
        case .cpu: String(localized: "CPU")
        case .memory: String(localized: "Memory")
        case .threads: String(localized: "Threads")
        case .ports: String(localized: "Ports")
        }
    }

    /// Column header label; shorter than `title` where the full word overflows its column.
    var columnTitle: String {
        switch self {
        case .threads: String(localized: "Threads.column", defaultValue: "Threads", comment: "Short header of the threads column")
        default: title
        }
    }

    /// Text columns start A→Z; numeric columns start with the biggest consumer.
    var defaultAscending: Bool { self == .name || self == .pid }
}

/// Active column plus direction; persisted as "cpu.desc".
struct ProcessSortOrder: Equatable, Hashable, Sendable {
    var key: ProcessSortKey
    var ascending: Bool

    static let `default` = ProcessSortOrder(key: .cpu, ascending: false)

    init(key: ProcessSortKey, ascending: Bool? = nil) {
        self.key = key
        self.ascending = ascending ?? key.defaultAscending
    }

    /// Clicking the active column flips the direction; another column starts at its default.
    func toggled(_ newKey: ProcessSortKey) -> ProcessSortOrder {
        newKey == key ? ProcessSortOrder(key: key, ascending: !ascending) : ProcessSortOrder(key: newKey)
    }

    var rawValue: String { "\(key.rawValue).\(ascending ? "asc" : "desc")" }

    init(rawValue: String) {
        let parts = rawValue.split(separator: ".")
        guard let first = parts.first, let key = ProcessSortKey(rawValue: String(first)) else {
            self = .default
            return
        }
        self.init(key: key, ascending: parts.count > 1 ? parts[1] == "asc" : nil)
    }
}
