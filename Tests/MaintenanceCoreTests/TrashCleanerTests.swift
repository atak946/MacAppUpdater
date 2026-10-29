import Foundation
import Testing
@testable import MaintenanceCore

@Suite("Trash cleaner")
struct TrashCleanerTests {
    private func item(_ url: URL, _ category: CleanupCategory = .userCaches) -> CleanupItem {
        CleanupItem(url: url, category: category, displayName: url.lastPathComponent, sizeInBytes: 100)
    }

    // MARK: Removal

    @Test("regular items go to the Trash, trash items are deleted permanently")
    func movesOrDeletes() async throws {
        let home = try FakeHome()
        let cache = try home.file("Library/Caches/com.example.App/x").deletingLastPathComponent()
        let trashed = try home.file(".Trash/old.txt")
        let remover = RecordingRemover()

        let result = await TrashCleaner(homeDirectory: home.url, remover: remover)
            .clean([item(cache), item(trashed, .trash)])

        #expect(remover.trashed == [cache])
        #expect(remover.deleted == [trashed])
        #expect(result.removed.count == 2)
        #expect(result.failed.isEmpty)
        #expect(result.reclaimedBytes == 200)
    }

    @Test("remover errors become failures with a reason")
    func collectsFailures() async throws {
        let home = try FakeHome()
        let good = try home.file("Downloads/a.dmg")
        let bad = try home.file("Downloads/b.dmg")
        let remover = RecordingRemover(failingNames: ["b.dmg"])

        let result = await TrashCleaner(homeDirectory: home.url, remover: remover)
            .clean([item(good, .oldInstallers), item(bad, .oldInstallers)])

        #expect(result.removed.map(\.url) == [good])
        #expect(result.failed.map(\.item.url) == [bad])
        #expect(result.failed.first?.reason == "Simulated failure")
    }

    // MARK: Refusals

    @Test("protected folders, home and outside paths are refused", arguments: [
        "", "Library", "Library/Caches", "Downloads", "Documents", "Desktop", ".Trash", "Library/Caches/",
    ])
    func refusesProtected(relativePath: String) async throws {
        let home = try FakeHome()
        let remover = RecordingRemover()
        let url = relativePath.isEmpty ? home.url : home.url.appendingPathComponent(relativePath)

        let result = await TrashCleaner(homeDirectory: home.url, remover: remover).clean([item(url)])

        #expect(result.removed.isEmpty)
        #expect(result.failed.count == 1)
        #expect(remover.trashed.isEmpty)
    }

    @Test("paths outside home or escaping with .. are refused")
    func refusesOutside() async throws {
        let home = try FakeHome()
        let remover = RecordingRemover()
        let outside = URL(fileURLWithPath: "/tmp/elsewhere.txt")
        let escaping = home.url.appendingPathComponent("Library/../../escape.txt")
        let cleaner = TrashCleaner(homeDirectory: home.url, remover: remover)

        let result = await cleaner.clean([item(outside), item(escaping)])

        #expect(result.failed.count == 2)
        #expect(result.failed.first?.reason == CleanupPathError.outsideHome.errorDescription)
        #expect(remover.trashed.isEmpty)
    }

    @Test("permanent deletion is refused outside the Trash")
    func refusesPermanentOutsideTrash() async throws {
        let home = try FakeHome()
        let file = try home.file("Documents/keep.txt")
        let remover = RecordingRemover()

        let result = await TrashCleaner(homeDirectory: home.url, remover: remover).clean([item(file, .trash)])

        #expect(result.failed.first?.reason == CleanupPathError.permanentDeletionOutsideTrash.errorDescription)
        #expect(remover.deleted.isEmpty)
    }

    @Test("error descriptions are human readable")
    func errorDescriptions() {
        #expect(CleanupPathError.homeDirectory.errorDescription?.isEmpty == false)
        #expect(CleanupPathError.protectedFolder("Library").errorDescription?.contains("Library") == true)
    }

    // MARK: File manager remover

    @Test("file manager remover deletes and trashes real files in a temp home")
    func fileManagerRemover() throws {
        let home = try FakeHome()
        let file = try home.file("victim.txt")
        let remover = FileManagerItemRemover()

        try remover.removePermanently(file)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(throws: (any Error).self) { try remover.moveToTrash(file) }
    }
}
