import Foundation
import os

/// Installs `.pkg` updates through the privileged helper.
///
/// Before handing the package to the helper it:
/// 1. resolves the expected Team ID: the installed app's team; when the installed app is
///    unsigned or its signature is broken, the update's curated `expectedTeamID`; when
///    neither exists the install is refused (no "any Developer ID" fallback),
/// 2. opens the package read-only (`O_NOFOLLOW`) and verifies it with
///    `pkgutil --check-signature` against `PackageTrustPolicy` (notarized Developer ID
///    Installer of the expected team; Apple-signed packages are never accepted),
/// 3. checks the path still names the opened inode, and passes the open descriptor plus
///    the expected team to the helper, which re-verifies its own root-only copy.
public struct PackageInstaller: UpdateInstalling {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "PackageInstaller")

    private let signatureChecker: PackageSignatureChecker
    private let appSignatureVerifier: (any SignatureVerifying)?
    private let installService: any PackageInstallService
    private let terminator: any RunningAppTerminating

    public init(
        installService: any PackageInstallService = HelperClient(),
        commandRunner: any CommandRunner = ProcessCommandRunner(),
        appSignatureVerifier: (any SignatureVerifying)? = CodeSignatureVerifier(),
        terminator: any RunningAppTerminating = RunningAppTerminator()
    ) {
        self.installService = installService
        self.signatureChecker = PackageSignatureChecker(commandRunner: commandRunner)
        self.appSignatureVerifier = appSignatureVerifier
        self.terminator = terminator
    }

    public func install(_ update: AvailableUpdate, from packageURL: URL) async throws {
        guard update.source != .appStore else {
            throw UpdaterError.unsupportedFormat("appStore")
        }
        guard PackageFormat(fileURL: packageURL) == .pkg else {
            throw UpdaterError.unsupportedFormat(packageURL.pathExtension.isEmpty ? "unknown" : packageURL.pathExtension)
        }
        let expectedTeam = try TeamPin.resolve(
            installedTeam: await installedTeamIdentifier(of: update.app),
            pinnedTeam: update.expectedTeamID,
            appName: update.app.name
        )
        let handle = try PackageFileHandle.openForReading(packageURL)
        defer { try? handle.close() }

        let signature = try await signatureChecker.check(packageURL)
        try PackageTrustPolicy.validate(signature, expectedTeamID: expectedTeam)
        try Self.requireUnchanged(handle, packageURL)
        try await terminator.terminateRunningInstances(of: update.app.bundleIdentifier)
        try Self.requireUnchanged(handle, packageURL)

        do {
            try await installService.installPackage(from: handle, expectedTeamID: expectedTeam)
        } catch let error as UpdaterError {
            throw error
        } catch HelperClientError.untrustedBuild {
            throw HelperClientError.untrustedBuild
        } catch {
            throw UpdaterError.installFailed(error.localizedDescription)
        }
        Self.logger.info("Installed package update \(update.id, privacy: .public)")
    }

    /// Same rule as `AppInstaller.pinnedTeam(for:)`: see `TeamPin.resolve`.
    static func resolveExpectedTeam(installedTeam: String?, updateTeam: String?) throws -> String {
        try TeamPin.resolve(installedTeam: installedTeam, pinnedTeam: updateTeam, appName: "The installed app")
    }

    private static func requireUnchanged(_ handle: FileHandle, _ url: URL) throws {
        guard PackageFileHandle.refersToSameFile(handle, as: url) else {
            throw UpdaterError.signatureInvalid("Package file was replaced during verification")
        }
    }

    /// Nil when no verifier is configured or the installed app is unsigned/ad-hoc/invalid.
    private func installedTeamIdentifier(of app: InstalledApp) async -> String? {
        guard let appSignatureVerifier else { return nil }
        do {
            return try await appSignatureVerifier.teamIdentifier(of: app.url)
        } catch {
            Self.logger.notice("No team id for \(app.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }
}
