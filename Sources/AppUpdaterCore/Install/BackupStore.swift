import Foundation
import os

/// Keeps copies of replaced app bundles so updates can be rolled back.
///
/// Layout: `<baseDirectory>/<bundleID>/<version>/<Name>.app` plus a `backup.json`
/// metadata file. Metadata is written last, so a half-copied backup is never listed
/// and gets cleaned up on the next prune. Bundles are copied with `ditto`, which
/// preserves code signatures, extended attributes and resource forks.
///
/// The base directory is kept at mode 0700 and must be owned by the current user. Backups are
/// still writable by same-user processes, so `restore` treats them as untrusted (H-2): the copy
/// that is swapped in must pass the same Apple-anchored team requirement and Gatekeeper policy
/// as an install, is re-verified right before the swap, and the restored bundle is verified
/// afterwards (automatic rollback on failure).
///
/// Serialised as an actor so concurrent backups/prunes of one app cannot interleave.
public actor BackupStore: AppBackupStoring {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "BackupStore")
    private static let metadataName = "backup.json"

    private struct Metadata: Codable {
        let bundleIdentifier: String
        let appName: String
        let version: String
        let createdAt: Date
        let appFileName: String
    }

    public nonisolated let baseDirectory: URL
    private let retention: BackupRetentionPolicy
    private let commandRunner: any CommandRunner
    private let signatureVerifier: any SignatureVerifying
    private let terminator: any RunningAppTerminating
    private let relauncher: any AppRelaunching
    private let relaunchAfterRestore: Bool
    private let notarizationGate: NotarizationGate
    private let now: @Sendable () -> Date
    private let fileManager = FileManager.default

    /// `~/Library/Application Support/MacAppUpdater/Backups`
    public static var defaultBaseDirectory: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("MacAppUpdater", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    public init(
        baseDirectory: URL = BackupStore.defaultBaseDirectory,
        retention: BackupRetentionPolicy = .default,
        commandRunner: any CommandRunner = ProcessCommandRunner(),
        signatureVerifier: any SignatureVerifying = CodeSignatureVerifier(),
        terminator: any RunningAppTerminating = RunningAppTerminator(),
        relauncher: any AppRelaunching = WorkspaceAppRelauncher(),
        relaunchAfterRestore: Bool = true,
        gatekeeperAssessor: any GatekeeperAssessing = SpctlGatekeeperAssessor(),
        notarizationPolicy: @escaping @autoclosure @Sendable () -> NotarizationPolicy = .require,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseDirectory = baseDirectory
        self.retention = retention
        self.commandRunner = commandRunner
        self.signatureVerifier = signatureVerifier
        self.terminator = terminator
        self.relauncher = relauncher
        self.relaunchAfterRestore = relaunchAfterRestore
        self.notarizationGate = NotarizationGate(assessor: gatekeeperAssessor, policy: notarizationPolicy)
        self.now = now
    }

    // MARK: - Backup

    @discardableResult
    public func backUp(_ app: InstalledApp) async throws -> AppBackup {
        let directory = appDirectory(for: app.bundleIdentifier)
            .appendingPathComponent(Self.safeComponent(app.shortVersion), isDirectory: true)
        let bundleURL = directory.appendingPathComponent(app.url.lastPathComponent)
        do {
            try prepareBaseDirectory()
            try? fileManager.removeItem(at: directory)
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try await commandRunner.run(SystemTool.ditto, arguments: [app.url.path, bundleURL.path])
            let draft = AppBackup(
                bundleIdentifier: app.bundleIdentifier, appName: app.name,
                version: app.shortVersion, createdAt: now(), bundleURL: bundleURL
            )
            try writeMetadata(for: draft, in: directory)
            // Re-read so the returned value equals what `backups(for:)` lists later.
            let backup = readBackup(in: directory) ?? draft
            Self.logger.info("Backed up \(app.bundleIdentifier, privacy: .public) \(app.shortVersion, privacy: .public)")
            prune(app.bundleIdentifier, keeping: backup)
            return backup
        } catch {
            try? fileManager.removeItem(at: directory)
            throw UpdaterError.installFailed("Backup of \(app.name) failed: \(error.localizedDescription)")
        }
    }

    public func backups(for bundleIdentifier: String) async throws -> [AppBackup] {
        listBackups(in: appDirectory(for: bundleIdentifier))
    }

    // MARK: - Restore

    public func restore(_ backup: AppBackup, over app: InstalledApp) async throws {
        try ensureManaged(backup.bundleURL)
        try BundleReplacer.securePrivateDirectory(baseDirectory, fileManager: fileManager)
        guard backup.bundleIdentifier == app.bundleIdentifier,
              AppBundleLocator.bundleIdentifier(of: backup.bundleURL) == app.bundleIdentifier else {
            throw UpdaterError.installFailed("Backup does not belong to \(app.bundleIdentifier)")
        }
        let team = try await verifyTeam(of: backup, matches: app)

        let replacer = BundleReplacer(fileManager: fileManager)
        let workDirectory = try replacer.makeWorkDirectory(near: app.url)
        defer { try? fileManager.removeItem(at: workDirectory) }
        let staged = workDirectory.appendingPathComponent(app.url.lastPathComponent)
        try await commandRunner.run(SystemTool.ditto, arguments: [backup.bundleURL.path, staged.path])

        // Gates run on the private copy, not on the user-writable backup (TOCTOU).
        try await verifyStaged(staged, bundleIdentifier: app.bundleIdentifier, team: team)
        try await notarizationGate.check(staged, bundleIdentifier: app.bundleIdentifier)

        let wasRunning = try await terminator.quitRunningInstances(of: app.bundleIdentifier)
        try await signatureVerifier.verifyTeam(of: staged, expected: team)
        try await replacer.replace(app.url, with: staged) { restored in
            try await verifyStaged(restored, bundleIdentifier: app.bundleIdentifier, team: team)
        }
        Self.logger.info("Restored \(app.bundleIdentifier, privacy: .public) \(backup.version, privacy: .public)")
        try? await delete(backup)
        if wasRunning && relaunchAfterRestore {
            await relauncher.relaunchLoggingFailure(app.url, logger: Self.logger)
        }
    }

    /// The backup must be validly signed (Apple-anchored) by the same team as the installed app.
    /// When the installed bundle is gone or unsigned, the backup's own anchored team is used.
    /// Returns the team the restored bundle is pinned to.
    private func verifyTeam(of backup: AppBackup, matches app: InstalledApp) async throws -> String {
        let backupTeam = try await signatureVerifier.teamIdentifier(of: backup.bundleURL)
        guard fileManager.fileExists(atPath: app.url.path) else { return backupTeam }
        let installedTeam = try await signatureVerifier.teamIdentifier(of: app.url)
        guard installedTeam == backupTeam else {
            throw UpdaterError.teamIdentifierMismatch(expected: installedTeam, actual: backupTeam)
        }
        return installedTeam
    }

    private nonisolated func verifyStaged(_ bundleURL: URL, bundleIdentifier: String, team: String) async throws {
        guard AppBundleLocator.bundleIdentifier(of: bundleURL) == bundleIdentifier else {
            throw UpdaterError.installFailed("Backup changed while it was being restored")
        }
        try await signatureVerifier.verifyTeam(of: bundleURL, expected: team)
    }

    /// Creates the base directory with mode 0700 (or tightens it) and checks its owner.
    private func prepareBaseDirectory() throws {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try fileManager.createDirectory(
                at: baseDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        try BundleReplacer.securePrivateDirectory(baseDirectory, fileManager: fileManager)
    }

    // MARK: - Deletion & retention

    public func delete(_ backup: AppBackup) async throws {
        try ensureManaged(backup.bundleURL)
        let versionDirectory = backup.bundleURL.deletingLastPathComponent()
        try fileManager.removeItem(at: versionDirectory)
        removeIfEmpty(versionDirectory.deletingLastPathComponent())
    }

    public func pruneAll() async throws {
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return }
        let appDirectories = try fileManager.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        for directory in appDirectories {
            prune(directory: directory, keeping: nil)
        }
    }

    private func prune(_ bundleIdentifier: String, keeping kept: AppBackup) {
        prune(directory: appDirectory(for: bundleIdentifier), keeping: kept)
    }

    /// Keeps the newest `maxBackupsPerApp` backups, drops expired ones and incomplete leftovers.
    /// `kept` (the backup just made) is never removed.
    private func prune(directory: URL, keeping kept: AppBackup?) {
        let cutoff = now().addingTimeInterval(-retention.maxAge)
        let backups = listBackups(in: directory)
        let doomed = backups.enumerated().filter { index, backup in
            guard backup.bundleURL.path != kept?.bundleURL.path else { return false }
            return index >= retention.maxBackupsPerApp || backup.createdAt < cutoff
        }
        for (_, backup) in doomed {
            try? fileManager.removeItem(at: backup.bundleURL.deletingLastPathComponent())
            Self.logger.info("Pruned backup \(backup.bundleIdentifier, privacy: .public) \(backup.version, privacy: .public)")
        }
        removeIncomplete(in: directory)
        removeIfEmpty(directory)
    }

    private func removeIncomplete(in directory: URL) {
        for versionDirectory in subdirectories(of: directory) {
            let metadataURL = versionDirectory.appendingPathComponent(Self.metadataName)
            if !fileManager.fileExists(atPath: metadataURL.path) {
                try? fileManager.removeItem(at: versionDirectory)
            }
        }
    }

    private func removeIfEmpty(_ directory: URL) {
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? ["?"]
        if contents.allSatisfy({ $0 == ".DS_Store" }) {
            try? fileManager.removeItem(at: directory)
        }
    }

    // MARK: - Metadata

    private func writeMetadata(for backup: AppBackup, in directory: URL) throws {
        let metadata = Metadata(
            bundleIdentifier: backup.bundleIdentifier, appName: backup.appName,
            version: backup.version, createdAt: backup.createdAt,
            appFileName: backup.bundleURL.lastPathComponent
        )
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: directory.appendingPathComponent(Self.metadataName), options: .atomic)
    }

    private func listBackups(in appDirectory: URL) -> [AppBackup] {
        subdirectories(of: appDirectory)
            .compactMap(readBackup(in:))
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func readBackup(in versionDirectory: URL) -> AppBackup? {
        let metadataURL = versionDirectory.appendingPathComponent(Self.metadataName)
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else {
            return nil
        }
        let bundleURL = versionDirectory.appendingPathComponent(metadata.appFileName)
        guard fileManager.fileExists(atPath: bundleURL.path) else { return nil }
        return AppBackup(
            bundleIdentifier: metadata.bundleIdentifier, appName: metadata.appName,
            version: metadata.version, createdAt: metadata.createdAt, bundleURL: bundleURL
        )
    }

    // MARK: - Paths

    private func subdirectories(of directory: URL) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        // Rebuild from `directory` so paths stay in the caller's form (e.g. /var vs /private/var).
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { directory.appendingPathComponent($0.lastPathComponent, isDirectory: true) }
    }

    private func appDirectory(for bundleIdentifier: String) -> URL {
        baseDirectory.appendingPathComponent(Self.safeComponent(bundleIdentifier), isDirectory: true)
    }

    /// Refuses to touch anything outside the backup area (AppBackup is Codable and could be forged).
    private func ensureManaged(_ bundleURL: URL) throws {
        let base = baseDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let candidate = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate.hasPrefix(base), bundleURL.pathExtension.lowercased() == "app" else {
            throw UpdaterError.installFailed("\(bundleURL.path) is not a managed backup")
        }
    }

    /// Makes an untrusted string (bundle id, version) safe as a single path component.
    static func safeComponent(_ value: String) -> String {
        let cleaned = value.map { $0 == "/" || $0 == ":" || $0.isNewline ? "_" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty else { return "_" }
        return result.hasPrefix(".") ? "_" + result : result
    }
}
