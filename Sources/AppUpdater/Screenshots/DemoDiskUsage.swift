import Foundation
import MaintenanceCore

/// A believable home folder size tree for the Disk Usage screenshot; nothing is read from disk.
struct DemoDiskUsageScanner: DiskUsageScanning {
    private static let gigabyte: Int64 = 1_000_000_000

    func scan(
        _ root: URL,
        progress: @escaping @Sendable (DiskUsageScanProgress) -> Void
    ) async throws -> DiskUsageNode {
        let entries: [(String, DiskUsageNode.Kind, Double, Int, Bool)] = [
            ("Library", .folder, 61.4, 412_830, true),
            ("Developer", .folder, 38.2, 296_114, false),
            ("Movies", .folder, 24.7, 312, false),
            ("Downloads", .folder, 12.9, 1_284, false),
            ("Pictures", .folder, 9.6, 18_402, true),
            ("Documents", .folder, 4.1, 7_915, false),
            ("Music", .folder, 2.3, 2_210, false),
            ("Desktop", .folder, 0.8, 96, false),
            ("ubuntu-24.04-desktop-arm64.iso", .file, 3.1, 1, false),
        ]
        let children = entries.map { name, kind, gigabytes, files, isPartial in
            let url = root.appendingPathComponent(name)
            let size = Int64(gigabytes * Double(Self.gigabyte))
            // Folders get one placeholder child so the row shows its drill-down chevron.
            let inner = kind == .folder
                ? [DiskUsageNode(url: url.appendingPathComponent("Contents"), name: "Contents", kind: .file, sizeInBytes: size, fileCount: files)]
                : []
            return DiskUsageNode(url: url, name: name, kind: kind, sizeInBytes: size, fileCount: files, children: inner, isPartial: isPartial)
        }
        return DiskUsageNode(
            url: root, name: root.lastPathComponent, kind: .folder,
            sizeInBytes: children.reduce(0) { $0 + $1.sizeInBytes },
            fileCount: children.reduce(0) { $0 + $1.fileCount },
            children: children, isPartial: true
        )
    }
}
