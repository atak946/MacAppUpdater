import Foundation
import Testing
@testable import MaintenanceCore

@Suite("Cleanup scanner behavior")
struct CleanupScannerBehaviorTests {
    private let mb = FakeHome.megabyte

    /// Thread-safe progress collector.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CleanupScanProgress] = []
        func append(_ value: CleanupScanProgress) { lock.withLock { values.append(value) } }
        var all: [CleanupScanProgress] { lock.withLock { values } }
    }

    // MARK: Sizes

    @Test("folder sizes include nested files")
    func nestedSizes() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/com.example.App/a.bin", bytes: mb)
        try home.file("Library/Caches/com.example.App/sub/b.bin", bytes: mb)
        try home.file("Library/Caches/com.example.App/sub/deeper/c.bin", bytes: mb)

        let item = try #require(try await home.scan([.userCaches]).items(.userCaches).first)

        #expect(item.sizeInBytes >= Int64(3 * mb))
        #expect(item.sizeInBytes < Int64(4 * mb))
    }

    @Test("symbolic links are neither listed nor followed")
    func symlinksIgnored() async throws {
        let home = try FakeHome()
        let outside = try FakeHome()
        let target = try outside.file("big/data.bin", bytes: 2 * mb).deletingLastPathComponent()
        try home.folder("Library/Caches")
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Library/Caches/com.example.Link"), withDestinationURL: target)
        try home.file("Library/Caches/com.example.Real/x", bytes: 4_096)
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Library/Caches/com.example.Real/link"), withDestinationURL: target)

        let report = try await home.scan([.userCaches], configuration: CleanupScanConfiguration(minimumCacheSize: 1))

        #expect(report.names(.userCaches) == ["com.example.Real"])
        #expect(try #require(report.items(.userCaches).first).sizeInBytes < Int64(mb))
    }

    // MARK: Sorting and grouping

    @Test("groups and items are sorted by size and empty groups omitted")
    func sortingAndOmission() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/com.example.Small/x", bytes: 2 * mb)
        try home.file("Library/Caches/com.example.Large/x", bytes: 4 * mb)
        try home.file(".Trash/huge.bin", bytes: 8 * mb)

        let report = try await home.scan(Set(CleanupCategory.allCases))

        #expect(report.groups.map(\.category) == [.trash, .userCaches])
        #expect(report.names(.userCaches) == ["com.example.Large", "com.example.Small"])
        #expect(report.totalSize == report.groups.reduce(0) { $0 + $1.totalSize })
        #expect(report.scannedAt == FakeHome.now)
    }

    @Test("an empty home produces an empty report")
    func emptyHome() async throws {
        let home = try FakeHome()
        let report = try await home.scan(Set(CleanupCategory.allCases))
        #expect(report.groups.isEmpty)
    }

    @Test("only requested categories are scanned")
    func requestedOnly() async throws {
        let home = try FakeHome()
        try home.file(".Trash/a.bin", bytes: 4_096)
        try home.file("Library/Logs/App/a.log", bytes: 4_096)

        let report = try await home.scan([.logs])

        #expect(report.groups.map(\.category) == [.logs])
    }

    // MARK: Progress and cancellation

    @Test("progress is reported after each category and ends at 1")
    func progress() async throws {
        let home = try FakeHome()
        let log = ProgressLog()

        _ = try await home.scanner().scan(categories: [.trash, .logs, .userCaches]) { log.append($0) }

        #expect(log.all.map(\.category) == [.userCaches, .logs, .trash])
        #expect(log.all.last?.fractionCompleted == 1)
    }

    @Test("a cancelled scan throws CancellationError")
    func cancellation() async throws {
        let home = try FakeHome()
        try home.file(".Trash/a.bin", bytes: 4_096)
        let scanner = home.scanner()
        let task = Task {
            try await scanner.scan(categories: Set(CleanupCategory.allCases)) { _ in }
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("default initializer is usable")
    func defaultInit() {
        _ = FileSystemCleanupScanner()
        _ = TrashCleaner()
    }

    // MARK: Helpers

    @Test("bundle identifier heuristic", arguments: [
        ("com.example.App", true), ("org.swift.swiftpm", true), ("Yarn", false), ("a..b", false), ("my cache.x", false),
    ])
    func bundleIdentifier(name: String, expected: Bool) {
        #expect(CleanupCategoryScanner.looksLikeBundleIdentifier(name) == expected)
    }

    @Test("DerivedData name parsing", arguments: [
        ("MyApp-abcdefghijklmnopqrstuvwxyz", "MyApp"), ("My-App-abcdefghijklmnop", "My-App"),
        ("Foo-Bar", "Foo-Bar"), ("NoHash", "NoHash"), ("-abcdefghijklmnop", "-abcdefghijklmnop"),
    ])
    func derivedDataName(folder: String, expected: String) {
        #expect(CleanupCategoryScanner.derivedDataName(folder) == expected)
    }
}
