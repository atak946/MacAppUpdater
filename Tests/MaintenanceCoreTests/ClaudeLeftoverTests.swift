import Foundation
import Testing
@testable import MaintenanceCore

@Suite("Claude leftovers category")
struct ClaudeLeftoverTests {
    private static let support = "Library/Application Support/Claude"

    @Test("old CLI builds are offered; the one `claude` points to and the newest are kept")
    func keepsCLIInUseAndNewest() async throws {
        let home = try FakeHome()
        for version in ["2.1.9", "2.1.99", "2.1.300", "2.1.310"] {
            try home.file(".local/share/claude/versions/\(version)", bytes: 4_096)
        }
        // An older build is in use (e.g. pinned): it must survive too.
        try home.folder(".local/bin")
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent(".local/bin/claude"),
            withDestinationURL: home.url.appendingPathComponent(".local/share/claude/versions/2.1.99")
        )

        let names = try await home.scan([.claudeLeftovers]).items(.claudeLeftovers).map(\.displayName)

        #expect(Set(names) == ["Claude Code 2.1.9", "Claude Code 2.1.300"])
    }

    @Test("desktop Claude Code copies, the Cowork VM and desktop caches are listed; the newest copy is kept")
    func listsDesktopItems() async throws {
        let home = try FakeHome()
        try home.file("\(Self.support)/claude-code/2.1.309/claude", bytes: 4_096)
        try home.file("\(Self.support)/claude-code/2.1.290/claude", bytes: 4_096)
        try home.file("\(Self.support)/vm_bundles/warm/disk.img", bytes: 8_192)
        try home.file("\(Self.support)/Cache/data_0", bytes: 4_096)
        try home.file("\(Self.support)/Code Cache/js/index", bytes: 4_096)
        try home.file("\(Self.support)/Partitions/preview/GPUCache/data_1", bytes: 4_096)
        // Settings and sessions are never touched.
        try home.file("\(Self.support)/Local Storage/leveldb/000003.log", bytes: 4_096)
        try home.file("\(Self.support)/config.json", bytes: 64)

        let items = try await home.scan([.claudeLeftovers]).items(.claudeLeftovers)

        #expect(Set(items.map(\.displayName)) == [
            "Claude Desktop — Claude Code 2.1.290",
            "Cowork VM — warm",
            "Claude Desktop — Cache",
            "Claude Desktop — Code Cache",
            "Claude Desktop — preview/GPUCache",
        ])
        #expect(!CleanupCategory.claudeLeftovers.isSelectedByDefault)
    }

    @Test("nothing is found without Claude installed")
    func emptyWithoutClaude() async throws {
        let home = try FakeHome()

        #expect(try await home.scan([.claudeLeftovers]).items(.claudeLeftovers).isEmpty)
    }
}
