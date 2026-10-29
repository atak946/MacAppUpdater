import Foundation

/// The single trust rule for installing a `.pkg` as root, applied identically by the
/// app (before terminating the target app) and by the helper (on its root-only copy).
///
/// A package is accepted only when:
/// 1. an expected Team ID is known (no "any Developer ID" fallback),
/// 2. it is signed with a Developer ID Installer certificate (Apple-signed packages are
///    never third-party updates),
/// 3. pkgutil reports it notarized by Apple, and
/// 4. the leaf certificate's team equals the expected team.
public enum PackageTrustPolicy {
    public static func validate(_ signature: PackageSignature, expectedTeamID: String?) throws {
        guard let expectedTeamID, HelperCodeSigning.isValidTeamIdentifier(expectedTeamID) else {
            throw UpdaterError.signatureInvalid("Cannot verify the package publisher: no trusted Team ID is known for this app")
        }
        guard signature.kind != .appleSoftware else {
            throw UpdaterError.signatureInvalid("Apple-signed packages are not accepted for third-party updates")
        }
        guard signature.kind == .developerID,
              signature.signerName?.hasPrefix(PackageSignatureChecker.developerIDLeafPrefix) == true,
              let packageTeam = signature.teamIdentifier else {
            throw UpdaterError.signatureInvalid("Package must be signed with a Developer ID Installer certificate")
        }
        guard signature.isNotarized else {
            throw UpdaterError.signatureInvalid("Package is not notarized by Apple")
        }
        guard packageTeam == expectedTeamID else {
            throw UpdaterError.teamIdentifierMismatch(expected: expectedTeamID, actual: packageTeam)
        }
    }
}
