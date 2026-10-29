import Foundation
import MaintenanceCore
import Testing
@testable import AppUpdater

private struct DiskError: Error {}

/// Scanner that always fails, for the error path of an unattended cleanup.
private struct FailingCleanupScanner: CleanupScanning {
    func scan(
        categories: Set<CleanupCategory>,
        progress: @escaping @Sendable (CleanupScanProgress) -> Void
    ) async throws -> CleanupScanReport {
        throw DiskError()
    }
}

@MainActor
@Suite("App Intents support")
struct AppIntentsSupportTests {
    private static func group(_ category: CleanupCategory, size: Int64) -> CleanupGroup {
        let item = CleanupItem(
            url: URL(fileURLWithPath: "/tmp/intents/\(category.rawValue)"),
            category: category, displayName: category.rawValue, sizeInBytes: size
        )
        return CleanupGroup(category: category, items: [item])
    }

    @Test("unattended cleanup is limited to default-selected caches, never Trash or logs")
    func unattendedCategories() {
        let categories = CleanupModel.unattendedCategories
        #expect(categories == [.userCaches, .xcodeDerivedData, .simulatorCaches, .packageManagerCaches])
        #expect(categories.allSatisfy { $0.isSelectedByDefault })
    }

    @Test("Clean Caches removes only unattended categories and reports the bytes freed")
    func cleanUnattended() async throws {
        let report = CleanupScanReport(
            groups: CleanupCategory.allCases.map { Self.group($0, size: 10) }, scannedAt: Date()
        )
        let cleaner = FakeCleanupCleaner()
        let model = CleanupModel(scanner: FakeCleanupScanner(reports: [report]), cleaner: cleaner)

        let result = try #require(try await model.cleanUnattended())

        #expect(Set(cleaner.cleaned.map(\.category)) == CleanupModel.unattendedCategories)
        #expect(result.reclaimedBytes == 40)
        #expect(model.state == .finished(result))
    }

    @Test("a failed scan cleans nothing and rethrows")
    func cleanUnattendedScanFailure() async {
        let cleaner = FakeCleanupCleaner()
        let model = CleanupModel(scanner: FailingCleanupScanner(), cleaner: cleaner)

        await #expect(throws: DiskError.self) { try await model.cleanUnattended() }
        #expect(cleaner.cleaned.isEmpty)
        #expect(model.state == .idle)
    }

    @Test("Update All from Shortcuts installs the Update All batch and names the rest as skipped")
    func installAllSummarized() async {
        let dmg = Fixtures.update("dmgapp")
        let store = Fixtures.update("storeapp", source: .appStore)
        let incompatible = Fixtures.update("newos", minimumSystemVersion: "99.0")
        let installer = RecordingInstaller()
        let viewModel = makeViewModel(
            updates: [dmg, store, incompatible], installer: installer,
            extras: ViewModelExtras(workspace: RecordingWorkspace())
        )
        await viewModel.refresh()

        let summary = await viewModel.installAllSummarized()

        #expect(await installer.installed == [dmg.id])
        #expect(summary.installed == [dmg.app.name])
        #expect(Set(summary.skipped) == [store.app.name, incompatible.app.name])
        #expect(summary.failed.isEmpty)
    }

    @Test("Update All summary lists each outcome, or says everything is current")
    func updateAllText() {
        let empty = UpdateAllAppsIntent.text(for: InstallAllSummary())
        #expect(empty == String(localized: "All your apps are up to date."))

        let text = UpdateAllAppsIntent.text(
            for: InstallAllSummary(installed: ["Arc", "Zoom"], failed: ["Slack"], skipped: ["Pages"])
        )
        #expect(text.contains("Arc"))
        #expect(text.contains("Slack"))
        #expect(text.contains("Pages"))
        #expect(text.split(separator: "\n").count == 3)
    }
}
