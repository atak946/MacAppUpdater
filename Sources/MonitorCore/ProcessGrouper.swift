import Foundation

/// Groups helpers under their app; everything outside a `.app` bundle stands alone.
public enum ProcessGrouper {
    /// Groups sorted by CPU (desc), then memory (desc), then name.
    public static func group(_ processes: [ProcessSnapshot]) -> [ProcessGroup] {
        var byBundle: [String: [ProcessSnapshot]] = [:]
        var standalone: [ProcessGroup] = []
        for process in processes {
            if let bundleURL = process.bundleURL {
                byBundle[bundleURL.standardizedFileURL.path, default: []].append(process)
            } else {
                standalone.append(standaloneGroup(process))
            }
        }
        let appGroups = uniquingIDs(byBundle.values.map(appGroup))
        return (appGroups + standalone).sorted(by: ordersBefore)
    }

    // MARK: - Builders

    private static func standaloneGroup(_ process: ProcessSnapshot) -> ProcessGroup {
        ProcessGroup(id: "pid:\(process.pid)", name: process.name, bundleURL: nil,
                     bundleIdentifier: process.bundleIdentifier, processes: [process], kind: process.kind)
    }

    private static func appGroup(_ members: [ProcessSnapshot]) -> ProcessGroup {
        let ordered = orderedMembers(members)
        let main = ordered[0]
        let bundleURL = main.bundleURL
        let identifier = ordered.lazy.compactMap(\.bundleIdentifier).first
        let name = bundleURL.map { $0.deletingPathExtension().lastPathComponent } ?? main.name
        return ProcessGroup(id: identifier ?? bundleURL?.path ?? "pid:\(main.pid)", name: name,
                            bundleURL: bundleURL, bundleIdentifier: identifier, processes: ordered,
                            kind: mostProtectiveKind(ordered.map(\.kind)))
    }

    /// Main process first (the bundle's `Contents/MacOS` executable, else the lowest pid),
    /// the rest by CPU desc then pid.
    static func orderedMembers(_ members: [ProcessSnapshot]) -> [ProcessSnapshot] {
        let byPID = members.sorted { $0.pid < $1.pid }
        let main = byPID.first { process in
            process.bundleURL.map { ProcessClassifier.isMainExecutable(process.executablePath, of: $0) } ?? false
        } ?? byPID[0]
        let rest = byPID.filter { $0.pid != main.pid }.sorted {
            $0.cpuPercent != $1.cpuPercent ? $0.cpuPercent > $1.cpuPercent : $0.pid < $1.pid
        }
        return [main] + rest
    }

    /// critical > system > user.
    static func mostProtectiveKind(_ kinds: [ProcessKind]) -> ProcessKind {
        kinds.max { ProcessClassifier.protectionRank($0) < ProcessClassifier.protectionRank($1) } ?? .user
    }

    /// Two copies of the same app share a bundle identifier; fall back to the bundle path for those.
    private static func uniquingIDs(_ groups: [ProcessGroup]) -> [ProcessGroup] {
        let counts = Dictionary(grouping: groups, by: \.id).mapValues(\.count)
        return groups.map { group in
            guard counts[group.id, default: 0] > 1, let path = group.bundleURL?.path else { return group }
            return ProcessGroup(id: path, name: group.name, bundleURL: group.bundleURL,
                                bundleIdentifier: group.bundleIdentifier, processes: group.processes, kind: group.kind)
        }
    }

    private static func ordersBefore(_ lhs: ProcessGroup, _ rhs: ProcessGroup) -> Bool {
        if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
        if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
        if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
        return lhs.id < rhs.id
    }
}
