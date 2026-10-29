import Darwin
import Foundation
import os

/// Root-side install pipeline of the privileged helper, shared by all connections.
///
/// Installs are serialized: a request starts only after the previous one finished,
/// so two `installer` runs never overlap.
///
/// Per request: validate team id and descriptor → copy into a root-only 0700 staging
/// directory → `pkgutil --check-signature` on the copy → `PackageTrustPolicy` (notarized
/// Developer ID Installer of `expectedTeamID`) → `installer -pkg <copy> -target /`.
public actor HelperPackageInstallCoordinator {
    private static let logger = Logger(subsystem: HelperConstants.machServiceName, category: "InstallCoordinator")
    public static let installerPath = "/usr/sbin/installer"

    private let validator: HelperInstallRequestValidator
    private let stager: PackageStager
    private let signatureChecker: PackageSignatureChecker
    private let commandRunner: any CommandRunner
    private var tail: Task<Void, Never>?

    public init(
        validator: HelperInstallRequestValidator = HelperInstallRequestValidator(),
        stager: PackageStager = PackageStager(),
        commandRunner: any CommandRunner = ProcessCommandRunner()
    ) {
        self.validator = validator
        self.stager = stager
        self.signatureChecker = PackageSignatureChecker(commandRunner: commandRunner)
        self.commandRunner = commandRunner
    }

    public func install(from fileHandle: FileHandle, expectedTeamID: String, callerUID: uid_t) async throws {
        let previous = tail
        let work = Task {
            await previous?.value
            try await self.performInstall(from: fileHandle, expectedTeamID: expectedTeamID, callerUID: callerUID)
        }
        tail = Task { _ = await work.result }
        try await work.value
    }

    private nonisolated func performInstall(
        from fileHandle: FileHandle, expectedTeamID: String, callerUID: uid_t
    ) async throws {
        try validator.validate(expectedTeamID: expectedTeamID)
        let descriptor = fileHandle.fileDescriptor
        let size = try validator.validate(fileDescriptor: descriptor, callerUID: callerUID)
        Self.logger.info("Install requested by uid \(callerUID): \(size) bytes, team \(expectedTeamID, privacy: .public)")

        let stagingDirectory = try stager.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let stagedURL = try stager.copy(from: descriptor, expectedSize: size, into: stagingDirectory)

        let signature = try await signatureChecker.check(stagedURL)
        try PackageTrustPolicy.validate(signature, expectedTeamID: expectedTeamID)
        Self.logger.info("Package signer: \(signature.signerName ?? "?", privacy: .public)")

        let output = try await commandRunner.run(Self.installerPath, arguments: ["-pkg", stagedURL.path, "-target", "/"])
        Self.logger.info("installer finished: \(output, privacy: .public)")
    }
}
