import Foundation
import Testing
@testable import MaintenanceCore

@Suite("Disk usage")
struct DiskUsageTests {
    private static let kilobyte = 1_024

    private func scan(_ home: FakeHome, filesPerFolder: Int = 40) async throws -> DiskUsageNode {
        try await FileSystemDiskUsageScanner(filesPerFolder: filesPerFolder).scan(home.url) { _ in }
    }

    // MARK: Scanning

    @Test("folders sum their contents and list children largest first")
    func sumsAndSorts() async throws {
        let home = try FakeHome()
        try home.file("Small/a.bin", bytes: 4 * Self.kilobyte)
        try home.file("Big/nested/b.bin", bytes: 400 * Self.kilobyte)
        try home.file("Big/c.bin", bytes: 40 * Self.kilobyte)
        try home.file("top.bin", bytes: 100 * Self.kilobyte)

        let root = try await scan(home)

        #expect(root.children.map(\.name) == ["Big", "top.bin", "Small"])
        #expect(root.fileCount == 4)
        #expect(root.sizeInBytes == root.children.reduce(0) { $0 + $1.sizeInBytes })
        let big = try #require(root.children.first)
        #expect(big.isFolder)
        #expect(big.sizeInBytes >= Int64(440 * Self.kilobyte))
        #expect(big.children.map(\.name) == ["nested", "c.bin"])
        #expect(root.folderCount == 3)
    }

    @Test("files beyond the per-folder limit are folded into one row")
    func foldsSmallFiles() async throws {
        let home = try FakeHome()
        for index in 0..<5 {
            try home.file("f\(index).bin", bytes: (index + 1) * 8 * Self.kilobyte)
        }

        let root = try await scan(home, filesPerFolder: 2)

        let files = root.children.filter { $0.kind == .file }
        let folded = try #require(root.children.first { $0.kind == .smallFiles })
        #expect(files.map(\.name) == ["f4.bin", "f3.bin"])
        #expect(folded.fileCount == 3)
        #expect(root.fileCount == 5)
        #expect(root.sizeInBytes == files.reduce(0) { $0 + $1.sizeInBytes } + folded.sizeInBytes)
    }

    @Test("symbolic links are not followed")
    func skipsSymlinks() async throws {
        let home = try FakeHome()
        let target = try home.file("Real/data.bin", bytes: 64 * Self.kilobyte)
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Link"), withDestinationURL: target.deletingLastPathComponent()
        )

        let root = try await scan(home)

        #expect(root.children.map(\.name) == ["Real"])
        #expect(root.fileCount == 1)
    }

    @Test("a cancelled scan throws")
    func cancels() async throws {
        let home = try FakeHome()
        for index in 0..<600 { try home.file("d\(index % 6)/f\(index).bin", bytes: 1) }

        let task = Task { try await scan(home) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: Tree edits

    @Test("removing a node shrinks every ancestor")
    func removesAndUpdatesAncestors() async throws {
        let home = try FakeHome()
        try home.file("A/B/doomed.bin", bytes: 200 * Self.kilobyte)
        try home.file("A/keep.bin", bytes: 8 * Self.kilobyte)
        let root = try await scan(home)
        let folderB = try #require(root.children.first?.children.first { $0.name == "B" })
        let doomedNode = try #require(folderB.children.first)
        let path = try #require(root.path(to: doomedNode.id))

        let updated = root.removing(doomedNode.id)

        #expect(path.map(\.name).dropFirst() == ["A", "B", "doomed.bin"])
        #expect(updated.sizeInBytes == root.sizeInBytes - doomedNode.sizeInBytes)
        #expect(updated.fileCount == 1)
        #expect(updated.path(to: doomedNode.id) == nil)
        let folderA = try #require(updated.children.first)
        #expect(folderA.children.first { $0.name == "B" }?.sizeInBytes == 0)
    }

    @Test("removing an unknown id leaves the tree unchanged")
    func removingUnknownIsNoOp() async throws {
        let home = try FakeHome()
        try home.file("A/x.bin", bytes: 4 * Self.kilobyte)
        let root = try await scan(home)

        #expect(root.removing("/nope") == root)
    }

    @Test("a rescanned folder replaces the old one and ancestors take the difference")
    func replacesSubtree() async throws {
        let home = try FakeHome()
        try home.file("A/B/old.bin", bytes: 8 * Self.kilobyte)
        try home.file("C/big.bin", bytes: 64 * Self.kilobyte)
        let root = try await scan(home)
        let folderA = try #require(root.children.first { $0.name == "A" })
        let folderB = try #require(folderA.children.first { $0.name == "B" })
        #expect(root.children.map(\.name) == ["C", "A"])

        try home.file("A/B/new.bin", bytes: 256 * Self.kilobyte)
        let fresh = try await FileSystemDiskUsageScanner().scan(folderB.url) { _ in }
        let updated = root.replacing(folderB.id, with: fresh)

        let grown = fresh.sizeInBytes - folderB.sizeInBytes
        #expect(grown > 0)
        #expect(updated.sizeInBytes == root.sizeInBytes + grown)
        #expect(updated.fileCount == 3)
        // A outgrew C, so the order flips.
        #expect(updated.children.map(\.name) == ["A", "C"])
        #expect(updated.path(to: folderB.id)?.last?.fileCount == 2)
    }

    @Test("replacing the root returns the replacement")
    func replacesRoot() async throws {
        let home = try FakeHome()
        try home.file("x.bin", bytes: 4 * Self.kilobyte)
        let root = try await scan(home)
        let fresh = DiskUsageNode(url: root.url, name: root.name, kind: .folder, sizeInBytes: 1, fileCount: 1)

        #expect(root.replacing(root.id, with: fresh).sizeInBytes == 1)
    }
}
