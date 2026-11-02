import Foundation
import Testing
@testable import MaintenanceCore

@Suite("Update backups category")
struct UpdateBackupsCategoryTests {
    private static let backups = "Library/Application Support/MacAppUpdater/Backups"

    @Test("lists one item per kept version, named after the app and owned by its bundle id")
    func listsBackups() async throws {
        let home = try FakeHome()
        let folder = "\(Self.backups)/com.example.Big/2.1"
        try home.file("\(folder)/Big.app/Contents/MacOS/Big", bytes: 8 * FakeHome.megabyte)
        let metadata = #"{"bundleIdentifier":"com.example.Big","appName":"Big","version":"2.1","createdAt":0,"appFileName":"Big.app"}"#
        try Data(metadata.utf8).write(to: home.url.appendingPathComponent("\(folder)/backup.json"))
        // No metadata (a half-written backup): still listed, named from its folders.
        try home.file("\(Self.backups)/com.example.Half/1.0/Half.app/x", bytes: 1_024)

        let items = try await home.scan([.updateBackups]).items(.updateBackups)

        #expect(Set(items.map(\.displayName)) == ["Big 2.1", "com.example.Half 1.0"])
        let big = try #require(items.first { $0.displayName == "Big 2.1" })
        #expect(big.url.lastPathComponent == "2.1")
        #expect(big.ownerBundleIdentifier == "com.example.Big")
        #expect(big.sizeInBytes >= Int64(8 * FakeHome.megabyte))
        #expect(!CleanupCategory.updateBackups.isSelectedByDefault)
    }

    @Test("finds nothing when App Updater never made a backup")
    func emptyWithoutFolder() async throws {
        let home = try FakeHome()

        #expect(try await home.scan([.updateBackups]).items(.updateBackups).isEmpty)
    }
}
