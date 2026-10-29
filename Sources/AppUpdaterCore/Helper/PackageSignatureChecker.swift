import Foundation
import os

/// Result of a successful `pkgutil --check-signature` run.
public struct PackageSignature: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// "signed by a developer certificate issued by Apple for distribution" (Developer ID Installer).
        case developerID
        /// "signed Apple Software".
        case appleSoftware
    }

    public let kind: Kind
    /// Team id from the leaf certificate, e.g. `ABCDE12345`. Nil for Apple software.
    public let teamIdentifier: String?
    /// Leaf certificate common name, e.g. `Developer ID Installer: Example Inc (ABCDE12345)`.
    public let signerName: String?
    /// True when pkgutil reports "Notarization: trusted by the Apple notary service".
    public let isNotarized: Bool

    public init(kind: Kind, teamIdentifier: String?, signerName: String?, isNotarized: Bool) {
        self.kind = kind
        self.teamIdentifier = teamIdentifier
        self.signerName = signerName
        self.isNotarized = isNotarized
    }
}

/// Verifies installer package signatures with `/usr/sbin/pkgutil --check-signature`.
///
/// Parses Developer ID Installer and Apple software signatures; whether a parsed signature
/// may be installed is decided by `PackageTrustPolicy` (which rejects Apple software).
/// Unsigned packages, untrusted/self-signed, expired or revoked certificates are rejected.
public struct PackageSignatureChecker: Sendable {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "PackageSignature")
    static let pkgutil = "/usr/sbin/pkgutil"

    private static let developerIDStatus = "signed by a developer certificate issued by Apple for distribution"
    private static let appleStatus = "signed Apple Software"
    static let developerIDLeafPrefix = "Developer ID Installer:"
    private static let notarizedMarker = "trusted by the Apple notary service"

    private let commandRunner: any CommandRunner

    public init(commandRunner: any CommandRunner = ProcessCommandRunner()) {
        self.commandRunner = commandRunner
    }

    /// Runs pkgutil and parses its output. Throws `UpdaterError.signatureInvalid` when rejected.
    public func check(_ packageURL: URL) async throws -> PackageSignature {
        let output: String
        do {
            output = try await commandRunner.run(Self.pkgutil, arguments: ["--check-signature", packageURL.path])
        } catch UpdaterError.commandFailed(_, _, let failureOutput) {
            // pkgutil exits non-zero for unsigned/invalid packages; the output explains why.
            output = failureOutput
        }
        do {
            return try Self.parse(output)
        } catch {
            Self.logger.error("Rejected \(packageURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Parses `pkgutil --check-signature` output.
    public static func parse(_ output: String) throws -> PackageSignature {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let status = value(after: "Status:", in: lines) else {
            throw UpdaterError.signatureInvalid("pkgutil output has no status line")
        }
        let isNotarized = value(after: "Notarization:", in: lines)?.contains(notarizedMarker) ?? false
        let leaf = leafCertificateName(in: lines)

        if status == appleStatus {
            return PackageSignature(kind: .appleSoftware, teamIdentifier: nil, signerName: leaf, isNotarized: isNotarized)
        }
        guard status == developerIDStatus else {
            throw UpdaterError.signatureInvalid("Package not accepted (\(status))")
        }
        guard let leaf, leaf.hasPrefix(developerIDLeafPrefix) else {
            throw UpdaterError.signatureInvalid("Package is not signed with a Developer ID Installer certificate")
        }
        guard let team = teamIdentifier(fromCertificateName: leaf) else {
            throw UpdaterError.signatureInvalid("Cannot read team identifier from \(leaf)")
        }
        return PackageSignature(kind: .developerID, teamIdentifier: team, signerName: leaf, isNotarized: isNotarized)
    }

    /// Extracts `TEAMID` from `Developer ID Installer: Name (TEAMID)`.
    static func teamIdentifier(fromCertificateName name: String) -> String? {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return nil }
        let candidate = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
        return HelperCodeSigning.isValidTeamIdentifier(candidate) ? candidate : nil
    }

    private static func value(after prefix: String, in lines: [String]) -> String? {
        lines.first { $0.hasPrefix(prefix) }
            .map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
    }

    /// The first entry of the "Certificate Chain:" list (`1. <name>`) is the leaf.
    private static func leafCertificateName(in lines: [String]) -> String? {
        guard let chainStart = lines.firstIndex(of: "Certificate Chain:") else { return nil }
        return lines[(chainStart + 1)...]
            .first { $0.hasPrefix("1. ") }
            .map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
    }
}
