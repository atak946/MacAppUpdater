import Foundation
import os

/// Installs a downloaded update by staging the new bundle, verifying it, and
/// atomically swapping it in place of the installed app.
///
/// Supported formats:
/// - `.dmg`: mounted read-only with `hdiutil`, the app is copied out with `ditto`,
///   and the image is always detached.
///   A signed image must satisfy the pinned team requirement before it is mounted (L-3).
/// - `.zip`: size-checked with `unzip -Zt`, then extracted with `ditto -x -k`.
/// - `.pkg`: handled by `PackageInstaller` through the privileged helper, not here.
///
/// Security pipeline (H-2, M-2, M-3, M-4, M-5, M-6):
/// 1. Resolve the pinned team: the installed app's Apple-anchored team, and/or the source's
///    `expectedTeamID`. They must agree; with neither, the install is refused.
/// 2. Stage into a 0700 directory and quarantine the staged bundle.
/// 3. Validate: bundle id, staged version > installed (and == advertised when comparable),
///    anchored team requirement (nested code), Gatekeeper/notarization policy.
/// 4. Clear quarantine only after a `.notarized` verdict; otherwise Gatekeeper still assesses
///    the app on first launch.
/// 5. Back up, quit the app, re-verify the staged signature, swap, verify the installed bundle
///    and roll back automatically when that fails.
///
/// App Store updates are rejected; the UI opens the App Store instead.
public struct AppInstaller: UpdateInstalling {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "Installer")

    private let commandRunner: any CommandRunner
    private let signatureVerifier: any SignatureVerifying
    private let terminator: any RunningAppTerminating
    /// `nil` disables backups (and therefore rollback).
    private let backupStore: (any AppBackupStoring)?
    private let relauncher: any AppRelaunching
    private let relaunchAfterInstall: Bool
    private let replacer: BundleReplacer
    private let notarizationGate: NotarizationGate
    /// When set, the download host is recorded after every successful install (B3).
    private let downloadHostStore: (any DownloadHostStoring)?
    /// `nil` skips the disk-image signature check (verifiers without DMG support, e.g. test stubs).
    private let diskImageVerifier: (any DiskImageSignatureVerifying)?
    private let versionCheck = StagedVersionCheck()
    /// FileManager is documented as thread-safe but not annotated `Sendable`.
    nonisolated(unsafe) private let fileManager: FileManager

    public init(
        commandRunner: any CommandRunner = ProcessCommandRunner(),
        signatureVerifier: any SignatureVerifying = CodeSignatureVerifier(),
        terminator: any RunningAppTerminating = RunningAppTerminator(),
        fileManager: FileManager = .default,
        backupStore: (any AppBackupStoring)? = BackupStore(),
        relauncher: any AppRelaunching = WorkspaceAppRelauncher(),
        relaunchAfterInstall: Bool = true,
        gatekeeperAssessor: any GatekeeperAssessing = SpctlGatekeeperAssessor(),
        notarizationPolicy: @escaping @autoclosure @Sendable () -> NotarizationPolicy = .require,
        downloadHostStore: (any DownloadHostStoring)? = nil,
        diskImageVerifier: (any DiskImageSignatureVerifying)? = nil
    ) {
        self.commandRunner = commandRunner
        self.signatureVerifier = signatureVerifier
        self.terminator = terminator
        self.fileManager = fileManager
        self.backupStore = backupStore
        self.relauncher = relauncher
        self.relaunchAfterInstall = relaunchAfterInstall
        self.replacer = BundleReplacer(fileManager: fileManager)
        self.notarizationGate = NotarizationGate(assessor: gatekeeperAssessor, policy: notarizationPolicy)
        self.downloadHostStore = downloadHostStore
        self.diskImageVerifier = diskImageVerifier ?? (signatureVerifier as? any DiskImageSignatureVerifying)
    }

    /// Steps: pin team → stage → validate (bundle id, version, team, Gatekeeper) →
    /// back up → quit app → re-verify → atomic swap → verify installed (rollback) → relaunch.
    /// A failed check or backup aborts the install before the running app is touched.
    public func install(_ update: AvailableUpdate, from packageURL: URL) async throws {
        guard update.source != .appStore else {
            throw UpdaterError.unsupportedFormat("appStore")
        }
        let installedURL = update.app.url
        let team = try await pinnedTeam(for: update)
        let workDirectory = try replacer.makeWorkDirectory(near: installedURL)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let stagedApp = try await stage(packageURL, for: update, team: team, in: workDirectory)
        AppBundleLocator.unhide(stagedApp)
        try Quarantine.apply(to: stagedApp)
        let verdict = try await validate(stagedApp, for: update, team: team)
        if verdict == .notarized {
            Quarantine.removeRecursively(from: stagedApp, fileManager: fileManager)
        }
        try await backUp(update.app)
        let wasRunning = try await terminator.quitRunningInstances(of: update.app.bundleIdentifier)
        do {
            // M-6: re-verify after the (slow) backup and quit, immediately before the swap.
            try await signatureVerifier.verifyTeam(of: stagedApp, expected: team)
            try await replacer.replace(installedURL, with: stagedApp) { installed in
                try await verifyInstalled(installed, bundleIdentifier: update.app.bundleIdentifier, team: team)
            }
        } catch {
            // The swap failed or was rolled back: the previous version is still in place, so
            // reopen it instead of leaving the user's app quit.
            if wasRunning { await relauncher.relaunchLoggingFailure(installedURL, logger: Self.logger) }
            throw error
        }
        Self.logger.info("Installed \(update.id, privacy: .public)")
        downloadHostStore?.record(update)
        if wasRunning && relaunchAfterInstall {
            await relauncher.relaunchLoggingFailure(installedURL, logger: Self.logger)
        }
    }

    /// M-5: the team the update must be signed by.
    /// - installed team (anchored) and `expectedTeamID` present → they must match;
    /// - only one of them → that one;
    /// - neither → refused: without a trusted publisher there is nothing to pin the update to.
    func pinnedTeam(for update: AvailableUpdate) async throws -> String {
        let installedTeam: String?
        let problem: String?
        do {
            installedTeam = try await signatureVerifier.teamIdentifier(of: update.app.url)
            problem = nil
        } catch {
            installedTeam = nil
            problem = (error as? UpdaterError)?.errorDescription ?? error.localizedDescription
            if update.expectedTeamID != nil {
                Self.logger.notice("Installed \(update.app.bundleIdentifier, privacy: .public) has no valid team; pinning to the source's team")
            }
        }
        return try TeamPin.resolve(
            installedTeam: installedTeam, pinnedTeam: update.expectedTeamID,
            appName: update.app.name, installedProblem: problem
        )
    }

    private func verifyInstalled(_ installed: URL, bundleIdentifier: String, team: String) async throws {
        guard AppBundleLocator.bundleIdentifier(of: installed) == bundleIdentifier else {
            throw UpdaterError.installFailed("Installed bundle changed after verification; rolled back")
        }
        do {
            try await signatureVerifier.verifyTeam(of: installed, expected: team)
        } catch {
            Self.logger.error("Post-install verification failed for \(bundleIdentifier, privacy: .public)")
            throw error
        }
    }

    private func backUp(_ app: InstalledApp) async throws {
        guard let backupStore else { return }
        do {
            try await backupStore.backUp(app)
        } catch let error as UpdaterError {
            throw error
        } catch {
            throw UpdaterError.installFailed("Backup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Staging

    private func stage(
        _ packageURL: URL, for update: AvailableUpdate, team: String, in workDirectory: URL
    ) async throws -> URL {
        let extractDirectory = workDirectory.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractDirectory, withIntermediateDirectories: true)

        switch PackageFormat(fileURL: packageURL) {
        case .zip:
            try await ArchiveCapacityCheck(commandRunner: commandRunner).check(packageURL, extractingInto: extractDirectory)
            try await commandRunner.run(SystemTool.ditto, arguments: ["-x", "-k", packageURL.path, extractDirectory.path])
            return try locateApp(in: extractDirectory, for: update.app)
        case .dmg:
            try await verifyDiskImageSignature(packageURL, team: team)
            return try await stageFromDiskImage(packageURL, for: update.app, in: workDirectory)
        case .pkg:
            throw UpdaterError.unsupportedFormat("pkg requires privileged helper")
        case .unknown:
            throw UpdaterError.unsupportedFormat(packageURL.pathExtension.isEmpty ? "unknown" : packageURL.pathExtension)
        }
    }

    /// L-3: a signed image must be signed by the pinned team before the kernel parses it.
    private func verifyDiskImageSignature(_ imageURL: URL, team: String) async throws {
        guard let diskImageVerifier else { return }
        let pinned = CodeSigningRequirement.isValidTeamIdentifier(team) ? team : nil
        let status = try await diskImageVerifier.verifyDiskImage(at: imageURL, expectedTeam: pinned)
        Self.logger.info("Disk image signature: \(String(describing: status), privacy: .public)")
    }

    private func stageFromDiskImage(_ imageURL: URL, for app: InstalledApp, in workDirectory: URL) async throws -> URL {
        // The work directory is an item-replacement directory (…/TemporaryItems/NSIRD_*); macOS
        // denies reading a volume mounted there ("Operation not permitted"), so the image would
        // look empty. Mount under the plain temporary directory instead; only the copy needs
        // to land next to the target.
        let mountRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AppUpdater-mount-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: mountRoot) }
        try BundleReplacer.securePrivateDirectory(mountRoot, fileManager: fileManager)
        let mountPoint = mountRoot.appendingPathComponent("mount", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let mounter = DiskImageMounter(commandRunner: commandRunner)

        return try await mounter.withMountedImage(at: imageURL, mountPoint: mountPoint) { volume in
            let sourceApp = try locateApp(in: volume, for: app)
            let destination = workDirectory
                .appendingPathComponent("extracted", isDirectory: true)
                .appendingPathComponent(sourceApp.lastPathComponent)
            try await commandRunner.run(SystemTool.ditto, arguments: [sourceApp.path, destination.path])
            return destination
        }
    }

    private func locateApp(in directory: URL, for app: InstalledApp) throws -> URL {
        try AppBundleLocator().locateApp(
            in: directory,
            bundleIdentifier: app.bundleIdentifier,
            preferredName: app.url.lastPathComponent
        )
    }

    // MARK: - Validation

    /// Returns the Gatekeeper verdict (`nil` when the policy is `.off`).
    private func validate(_ stagedApp: URL, for update: AvailableUpdate, team: String) async throws -> GatekeeperVerdict? {
        let app = update.app
        guard let newIdentifier = AppBundleLocator.bundleIdentifier(of: stagedApp) else {
            throw UpdaterError.invalidBundle(stagedApp)
        }
        guard newIdentifier == app.bundleIdentifier else {
            throw UpdaterError.installFailed(
                "Bundle identifier mismatch (expected \(app.bundleIdentifier), got \(newIdentifier))"
            )
        }
        guard let stagedVersion = AppBundleLocator.version(of: stagedApp) else {
            throw UpdaterError.installFailed("The downloaded app has no version number")
        }
        try versionCheck.validate(
            staged: stagedVersion,
            installed: (app.shortVersion, app.buildVersion),
            advertised: update.newVersion
        )
        try await signatureVerifier.verifyTeam(of: stagedApp, expected: team)
        return try await notarizationGate.check(stagedApp, bundleIdentifier: app.bundleIdentifier)
    }
}
