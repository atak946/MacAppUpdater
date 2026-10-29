import Foundation
import MonitorCore
import Testing
@testable import AppUpdater

// MARK: - Fixtures

private let me: UInt32 = 501
private let mb: UInt64 = 1024 * 1024

private func process(
    _ pid: Int32, _ name: String, cpu: Double = 0, memory: UInt64 = 0, threads: Int = 1,
    user: UInt32 = me, kind: ProcessKind = .user
) -> ProcessSnapshot {
    ProcessSnapshot(pid: pid, parentPID: 1, name: name, executablePath: nil, bundleURL: nil, bundleIdentifier: nil,
                    userID: user, cpuPercent: cpu, memoryBytes: memory, threadCount: threads, startDate: nil, kind: kind)
}

private func item(
    _ id: String, name: String, processes: [ProcessSnapshot], kind: ProcessKind = .user, isApp: Bool = true,
    ports: [Int32: [ListeningPort]] = [:], appBundleIDs: Set<String> = []
) -> ProcessListItem {
    let group = ProcessGroup(
        id: id, name: name,
        bundleURL: isApp ? URL(fileURLWithPath: "/Applications/\(name).app") : nil,
        bundleIdentifier: isApp ? "com.example.\(name.lowercased())" : nil,
        processes: processes, kind: kind
    )
    return ProcessListItem(group: group, ports: ports, appBundleIDs: appBundleIDs, currentUserID: me)
}

private func port(_ pid: Int32, _ number: UInt16) -> [Int32: [ListeningPort]] {
    [pid: [ListeningPort(pid: pid, port: number, transport: "TCP", address: "127.0.0.1")]]
}

/// One parameterized chip scenario.
struct ChipCase: Sendable, CustomTestStringConvertible {
    let chips: Set<ProcessChip>
    let expected: [String]
    var testDescription: String { ProcessChip.encode(chips) }
}

// MARK: - Tests

@Suite("ProcessListQuery")
struct ProcessListQueryTests {
    private static let mixed = [
        item("a", name: "Xcode", processes: [process(1, "Xcode")]),
        item("b", name: "mds", processes: [process(2, "mds", user: 0)], kind: .system, isApp: false),
        item("c", name: "WindowServer", processes: [process(3, "WindowServer", user: 88)], kind: .critical, isApp: false),
        item("d", name: "node", processes: [process(4, "node")], isApp: false),
    ]

    private static func ids(_ query: ProcessListQuery, _ items: [ProcessListItem] = mixed) -> [String] {
        query.apply(to: items).map(\.id)
    }

    @Test("categories are disjoint and Dock apps count as apps")
    func categories() {
        #expect(Self.ids(ProcessListQuery(filter: .apps)) == ["a"])
        #expect(Self.ids(ProcessListQuery(filter: .background)) == ["d"])
        #expect(Set(Self.ids(ProcessListQuery(filter: .system))) == ["b", "c"])
        #expect(Self.ids(ProcessListQuery(filter: .all)).count == 4)
        let finder = item("f", name: "Finder", processes: [process(5, "Finder")], kind: .system,
                          appBundleIDs: ["com.example.finder"])
        #expect(finder.category == .apps)
    }

    @Test("counts reflect chips and search but not the category")
    func counts() {
        let counts = ProcessListQuery(filter: .apps, chips: [.mine]).counts(in: Self.mixed)
        #expect(counts == [.apps: 1, .background: 1, .system: 0, .all: 2])
    }

    private static let chipCases: [ChipCase] = [
        ChipCase(chips: [.highCPU], expected: ["hot"]),
        ChipCase(chips: [.highMemory], expected: ["big"]),
        ChipCase(chips: [.hasPorts], expected: ["srv"]),
        ChipCase(chips: [.mine], expected: ["big", "hot", "srv"]),
        ChipCase(chips: [.highCPU, .hasPorts], expected: []),
    ]

    @Test("chips narrow with AND", arguments: chipCases)
    func chips(_ testCase: ChipCase) {
        let chips = testCase.chips
        let expected = testCase.expected
        let items = [
            item("hot", name: "Hot", processes: [process(1, "Hot", cpu: 5.5)]),
            item("big", name: "Big", processes: [process(2, "Big", cpu: 5, memory: 501 * mb)]),
            item("srv", name: "Srv", processes: [process(3, "Srv")], ports: port(3, 8080)),
            item("root", name: "Root", processes: [process(4, "Root", memory: 500 * mb, user: 0)]),
        ]
        #expect(Self.ids(ProcessListQuery(filter: .all, chips: chips, sort: ProcessSortOrder(key: .name)), items) == expected)
    }

    @Test("every column sorts both ways with name then id as tie-breakers")
    func sorting() {
        let items = [
            item("a", name: "Beta", processes: [process(9, "b", cpu: 5, memory: 300, threads: 4)], ports: port(9, 80)),
            item("b", name: "alpha", processes: [process(2, "a", cpu: 50, memory: 100, threads: 40)]),
            item("c", name: "Gamma", processes: [process(3, "g", cpu: 5, memory: 900, threads: 4)]),
        ]
        func ids(_ key: ProcessSortKey, ascending: Bool? = nil) -> [String] {
            Self.ids(ProcessListQuery(filter: .all, sort: ProcessSortOrder(key: key, ascending: ascending)), items)
        }

        #expect(ids(.cpu) == ["b", "a", "c"])
        #expect(ids(.cpu, ascending: true) == ["a", "c", "b"])
        #expect(ids(.memory) == ["c", "a", "b"])
        #expect(ids(.threads) == ["b", "a", "c"])
        #expect(ids(.ports) == ["a", "b", "c"])
        #expect(ids(.name) == ["b", "a", "c"])
        #expect(ids(.name, ascending: false) == ["c", "a", "b"])
        #expect(ids(.pid) == ["b", "c", "a"])
    }

    @Test("network sums members, sorts groups and members, and treats unread pids as idle")
    func networkSorting() {
        let rates: [Int32: NetworkThroughput] = [
            10: NetworkThroughput(bytesInPerSecond: 100, bytesOutPerSecond: 50),
            11: NetworkThroughput(bytesInPerSecond: 1000, bytesOutPerSecond: 0),
            20: NetworkThroughput(bytesInPerSecond: 200, bytesOutPerSecond: 300),
        ]
        func networkItem(_ id: String, _ name: String, _ members: [ProcessSnapshot]) -> ProcessListItem {
            let group = ProcessGroup(id: id, name: name, bundleURL: nil, bundleIdentifier: nil, processes: members, kind: .user)
            return ProcessListItem(group: group, ports: [:], appBundleIDs: [], currentUserID: me, network: rates)
        }
        let app = networkItem("app", "App", [process(10, "App"), process(11, "Helper"), process(12, "Idle")])
        let tool = networkItem("tool", "tool", [process(20, "tool")])
        let quiet = networkItem("quiet", "quiet", [process(30, "quiet")])

        #expect(app.network == NetworkThroughput(bytesInPerSecond: 1100, bytesOutPerSecond: 50))
        #expect(app.memberNetwork.keys.sorted() == [10, 11])
        #expect(quiet.network.bytesPerSecond == 0)

        let query = ProcessListQuery(filter: .all, sort: ProcessSortOrder(key: .network))
        let sorted = query.apply(to: [quiet, tool, app])
        #expect(sorted.map(\.id) == ["app", "tool", "quiet"])
        #expect(sorted.first?.members.map(\.pid) == [11, 10, 12])
        let ascending = ProcessListQuery(filter: .all, sort: ProcessSortOrder(key: .network, ascending: true))
        #expect(ascending.apply(to: [quiet, tool, app]).map(\.id) == ["quiet", "tool", "app"])
        #expect(ProcessSortOrder(rawValue: "network.desc") == ProcessSortOrder(key: .network))
    }

    @Test("members of an expanded group follow the active sort")
    func memberSorting() {
        let app = item("x", name: "App", processes: [process(10, "App", cpu: 1), process(11, "Helper", cpu: 7)])
        let query = ProcessListQuery(filter: .all, sort: ProcessSortOrder(key: .cpu))
        #expect(query.apply(to: [app]).first?.members.map(\.pid) == [11, 10])
        let byPID = ProcessListQuery(filter: .all, sort: ProcessSortOrder(key: .pid, ascending: false))
        #expect(byPID.apply(to: [app]).first?.members.map(\.pid) == [11, 10])
    }

    @Test("clicking the active column flips direction; a new column starts at its default")
    func sortToggle() {
        let cpu = ProcessSortOrder.default
        #expect(cpu.toggled(.cpu) == ProcessSortOrder(key: .cpu, ascending: true))
        #expect(cpu.toggled(.name) == ProcessSortOrder(key: .name, ascending: true))
        #expect(cpu.toggled(.memory).ascending == false)
        #expect(ProcessSortOrder(rawValue: "threads.asc") == ProcessSortOrder(key: .threads, ascending: true))
        #expect(ProcessSortOrder(rawValue: cpu.rawValue) == cpu)
        #expect(ProcessSortOrder(rawValue: "garbage") == .default)
        #expect(ProcessChip.decode(ProcessChip.encode([.mine, .hasPorts])) == [.mine, .hasPorts])
        #expect(ProcessChip.decode("mine,bogus") == [.mine])
    }

    @Test("search matches name, bundle id, member, pid and port")
    func search() {
        let items = [
            item("a", name: "Code", processes: [process(11, "Code"), process(12, "Code Helper (Renderer)")]),
            item("b", name: "node", processes: [process(42, "node")], isApp: false, ports: port(42, 3000)),
        ]
        func ids(_ term: String) -> [String] {
            Self.ids(ProcessListQuery(filter: .all, sort: ProcessSortOrder(key: .name), search: term), items)
        }

        #expect(ids("code") == ["a"])
        #expect(ids("com.example") == ["a"])
        #expect(ids("renderer") == ["a"])
        #expect(ids("42") == ["b"])
        #expect(ids(":3000") == ["b"])
        #expect(ids("300") == ["b"])
        #expect(ids("nothing").isEmpty)
        #expect(ids("  ").count == 2)
    }

    @Test("clearing resets category and chips but keeps search and sort")
    func clearing() {
        let query = ProcessListQuery(filter: .apps, chips: [.mine], sort: ProcessSortOrder(key: .name), search: "x")
        #expect(query.isNarrowed)
        #expect(!query.cleared.isNarrowed)
        #expect(query.cleared.search == "x")
        #expect(query.cleared.sort == query.sort)
    }

    @Test("frozen order keeps known rows in place and appends new ones")
    func preservingOrder() {
        let fresh = [
            item("n", name: "New", processes: [process(7, "New")]),
            item("b", name: "B", processes: [process(2, "B", cpu: 90)]),
            item("a", name: "A", processes: [process(1, "A")]),
        ]
        let kept = ProcessListQuery.preservingOrder(fresh, previous: ["a", "gone", "b"])
        #expect(kept.map(\.id) == ["a", "b", "n"])
        #expect(kept[1].cpuPercent == 90)
    }
}
