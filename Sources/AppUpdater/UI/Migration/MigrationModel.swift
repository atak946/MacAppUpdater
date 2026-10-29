import AppUpdaterCore
import Foundation
import Observation
import os

/// Drives "migrate to a new Mac": exports the app list and diffs an imported one.
///
/// Import never installs anything itself: the app has no fresh-install path for casks (only
/// updates), so the sheet offers validated commands to copy and App Store links instead.
@MainActor
@Observable
final class MigrationModel {
    enum ExportFormat: CaseIterable {
        case brewfile, json

        var defaultFileName: String {
            switch self {
            case .brewfile: "Brewfile"
            case .json: "AppList.json"
            }
        }
    }

    struct ImportResult: Identifiable {
        let id = UUID()
        let fileURL: URL
        let manifest: MigrationManifest
        let missing: [MigrationEntry]

        var caskInstallCommand: String? { MigrationCommands.caskInstallCommand(for: missing) }
        var bundleCommand: String { MigrationCommands.bundleCommand(fileURL: fileURL) }
    }

    private(set) var isWorking = false
    var importResult: ImportResult?
    var errorMessage: String?

    private let resolver: any MigrationResolving
    private let logger = Logger(subsystem: "com.macappupdater", category: "MigrationModel")

    init(resolver: any MigrationResolving) {
        self.resolver = resolver
    }

    func export(_ apps: [InstalledApp], as format: ExportFormat, to url: URL) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let sorted = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Installed formulae are not tracked (only outdated ones), so the list holds apps only.
        let manifest = MigrationManifest(apps: await resolver.entries(for: sorted), exportedAt: .now)
        do {
            let data = switch format {
            case .brewfile: Data(Brewfile.render(manifest).utf8)
            case .json: try MigrationFile.encodeJSON(manifest)
            }
            try data.write(to: url, options: .atomic)
            logger.info("Exported \(manifest.apps.count, privacy: .public) apps")
        } catch {
            logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func importList(from url: URL, installed: [InstalledApp]) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let manifest = try MigrationFile.decode(try Self.readBounded(url))
            let needsTokens = manifest.apps.contains { $0.caskToken != nil }
            let tokens = needsTokens ? await resolver.installedCaskTokens(for: installed) : []
            let missing = MigrationDiff.missing(manifest.apps, installed: installed, installedCaskTokens: tokens)
            importResult = ImportResult(fileURL: url, manifest: manifest, missing: missing)
        } catch {
            logger.error("Import failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    /// Checks the size before reading so a huge file picked by mistake is never loaded.
    private static func readBounded(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= MigrationFile.maxBytes else { throw MigrationFileError.tooLarge }
        return try Data(contentsOf: url)
    }
}
