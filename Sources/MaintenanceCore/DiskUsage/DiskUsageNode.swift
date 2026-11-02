import Foundation

// Public contract shared by the disk usage scanner and the Disk Usage screen.

/// One entry of a disk usage tree: a folder with its children, a file, or the
/// small files of a folder folded into a single row.
public struct DiskUsageNode: Identifiable, Sendable {
    public enum Kind: Sendable, Hashable {
        case folder
        case file
        /// Files of a folder too small to list one by one, summed into one row.
        case smallFiles
    }

    public let id: String
    public let url: URL
    public let name: String
    public let kind: Kind
    /// Allocated size on disk, including everything below a folder.
    public let sizeInBytes: Int64
    /// Files at or below this node.
    public let fileCount: Int
    /// Largest first. Empty for files and folded small files.
    public let children: [DiskUsageNode]
    /// The folder (or part of it) could not be read; its size is a lower bound.
    public let isPartial: Bool

    public init(
        url: URL,
        name: String,
        kind: Kind,
        sizeInBytes: Int64,
        fileCount: Int,
        children: [DiskUsageNode] = [],
        isPartial: Bool = false
    ) {
        self.id = kind == .smallFiles ? url.path + "/\u{0}small-files" : url.path
        self.url = url
        self.name = name
        self.kind = kind
        self.sizeInBytes = sizeInBytes
        self.fileCount = fileCount
        self.children = children
        self.isPartial = isPartial
    }

    public var isFolder: Bool { kind == .folder }

    /// Sub-folders at or below this node.
    public var folderCount: Int {
        children.reduce(0) { $0 + ($1.isFolder ? 1 + $1.folderCount : 0) }
    }

    /// A copy without the node `id` anywhere below, with every ancestor's size and file count
    /// reduced by what was removed. Returns `self` when `id` is not found or is this node.
    public func removing(_ id: String) -> DiskUsageNode {
        updating(id, with: nil) ?? self
    }

    /// A copy with the node `id` swapped for `replacement` (a fresh scan of that folder), every
    /// ancestor's totals adjusted by the difference and re-sorted. Returns `self` when `id` is not found.
    public func replacing(_ id: String, with replacement: DiskUsageNode) -> DiskUsageNode {
        if self.id == id { return replacement.adopting(self) }
        return updating(id, with: replacement) ?? self
    }

    /// `self`'s contents under `original`'s URL, name and id, so the tree keeps finding it
    /// even when a fresh scan spelled the path differently (`/var` vs `/private/var`).
    private func adopting(_ original: DiskUsageNode) -> DiskUsageNode {
        DiskUsageNode(
            url: original.url, name: original.name, kind: kind,
            sizeInBytes: sizeInBytes, fileCount: fileCount, children: children, isPartial: isPartial
        )
    }

    /// The chain of nodes from this one down to `id`, or nil when it is not in the tree.
    public func path(to id: String) -> [DiskUsageNode]? {
        if self.id == id { return [self] }
        if let leaf = children.first(where: { $0.id == id }) { return [self, leaf] }
        for child in children where child.isFolder {
            if let tail = child.path(to: id) { return [self] + tail }
        }
        return nil
    }

    /// Rebuilds only the folders on the way down to `id`; nil when `id` is not below this node.
    /// A nil `replacement` removes the node.
    private func updating(_ id: String, with replacement: DiskUsageNode?) -> DiskUsageNode? {
        for (index, child) in children.enumerated() {
            let newChild: DiskUsageNode?
            if child.id == id {
                newChild = replacement?.adopting(child)
            } else if child.isFolder, let updated = child.updating(id, with: replacement) {
                newChild = updated
            } else {
                continue
            }
            var updatedChildren = children
            if let newChild {
                updatedChildren[index] = newChild
            } else {
                updatedChildren.remove(at: index)
            }
            return DiskUsageNode(
                url: url, name: name, kind: kind,
                sizeInBytes: sizeInBytes - child.sizeInBytes + (newChild?.sizeInBytes ?? 0),
                fileCount: fileCount - child.fileCount + (newChild?.fileCount ?? 0),
                children: updatedChildren.sorted(by: DiskUsageNode.largestFirst),
                isPartial: isPartial
            )
        }
        return nil
    }

    /// Size descending, then name, so equal sizes keep a stable order.
    public static func largestFirst(_ lhs: DiskUsageNode, _ rhs: DiskUsageNode) -> Bool {
        if lhs.sizeInBytes != rhs.sizeInBytes { return lhs.sizeInBytes > rhs.sizeInBytes }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

extension DiskUsageNode: Equatable {
    /// Identity plus totals; comparing whole subtrees would walk millions of nodes.
    public static func == (lhs: DiskUsageNode, rhs: DiskUsageNode) -> Bool {
        lhs.id == rhs.id && lhs.sizeInBytes == rhs.sizeInBytes
            && lhs.fileCount == rhs.fileCount && lhs.children.count == rhs.children.count
    }
}

/// Reported while scanning, a few times per second at most, and whenever a top-level folder finishes.
public struct DiskUsageScanProgress: Sendable, Hashable {
    /// A finished top-level folder and its total.
    public struct Folder: Sendable, Hashable {
        public let name: String
        public let sizeInBytes: Int64

        public init(name: String, sizeInBytes: Int64) {
            self.name = name
            self.sizeInBytes = sizeInBytes
        }
    }

    public let itemsScanned: Int
    public let bytesScanned: Int64
    /// Top-level folders of the scanned root, and how many are done.
    public let foldersTotal: Int
    public let foldersDone: Int
    /// Finished top-level folders, largest first.
    public let finishedFolders: [Folder]

    public init(
        itemsScanned: Int, bytesScanned: Int64,
        foldersTotal: Int = 0, foldersDone: Int = 0, finishedFolders: [Folder] = []
    ) {
        self.itemsScanned = itemsScanned
        self.bytesScanned = bytesScanned
        self.foldersTotal = foldersTotal
        self.foldersDone = foldersDone
        self.finishedFolders = finishedFolders
    }

    /// 0...1 by finished top-level folders; a coarse but steady measure.
    public var fractionCompleted: Double {
        foldersTotal == 0 ? 0 : Double(foldersDone) / Double(foldersTotal)
    }
}

public protocol DiskUsageScanning: Sendable {
    /// Builds the size tree below `root`. Throws `CancellationError` when the task is cancelled.
    func scan(
        _ root: URL,
        progress: @escaping @Sendable (DiskUsageScanProgress) -> Void
    ) async throws -> DiskUsageNode
}
