import Foundation
import Security

/// A verifier that can check a bundle against an explicit, Apple-anchored team requirement.
/// `SignatureVerifying.verifyTeam(of:expected:)` prefers this over comparing `teamIdentifier(of:)`.
public protocol TeamPinnedSignatureVerifying: SignatureVerifying {
    /// Throws unless `bundleURL` is validly signed (nested code included) by an Apple-issued
    /// Developer ID / Mac App Store certificate whose leaf OU is `expectedTeam`.
    func verify(bundleURL: URL, expectedTeam: String) async throws
}

/// Signature state of a downloaded disk image.
public enum DiskImageSignatureStatus: Sendable, Hashable {
    /// The image carries no code signature (most DMGs); the app inside is verified later.
    case unsigned
    /// The image is signed by an Apple-anchored Developer ID identity of this team.
    case verified(teamIdentifier: String)
}

/// Verifies a `.dmg`'s own signature before it is mounted (L-3).
public protocol DiskImageSignatureVerifying: Sendable {
    /// Returns `.unsigned` for unsigned images; throws when a signature exists but is invalid,
    /// not Apple-anchored, or (when `expectedTeam` is set) issued to another team.
    func verifyDiskImage(at imageURL: URL, expectedTeam: String?) async throws -> DiskImageSignatureStatus
}

extension SignatureVerifying {
    /// Team check used by the install and restore pipelines.
    /// Uses the anchored requirement when available, otherwise compares `teamIdentifier(of:)`.
    func verifyTeam(of bundleURL: URL, expected: String) async throws {
        if let pinned = self as? any TeamPinnedSignatureVerifying {
            try await pinned.verify(bundleURL: bundleURL, expectedTeam: expected)
            return
        }
        let actual = try await teamIdentifier(of: bundleURL)
        guard actual == expected else {
            throw UpdaterError.teamIdentifierMismatch(expected: expected, actual: actual)
        }
    }
}

/// Validates code signatures with the Security framework, always against an explicit
/// requirement anchored to Apple's CA (H-2). A self-signed or ad-hoc signature that claims
/// a Team ID in its CodeDirectory therefore fails.
public struct CodeSignatureVerifier: TeamPinnedSignatureVerifying, DiskImageSignatureVerifying {
    /// Validation without nested code: used to *read* the team of an installed app.
    static let readFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
    /// Signature and certificate chain only, without hashing every resource file; a full read
    /// of a large app (Xcode, Office) hashes gigabytes.
    static let inspectFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSDoNotValidateResources)
    /// Full validation: used for bundles that are about to be installed or restored.
    static let verifyFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode
    )

    public init() {}

    /// Team of a bundle signed by an Apple-issued identity (Developer ID Application or
    /// Mac App Store). The CodeDirectory team is bound to the certificate's leaf OU.
    public func teamIdentifier(of bundleURL: URL) async throws -> String {
        try Self.anchoredTeam(of: bundleURL, flags: Self.readFlags)
    }

    /// Same Apple-anchored team check as `teamIdentifier(of:)`, without resource hashing.
    public func signingTeam(of bundleURL: URL) async throws -> String {
        try Self.anchoredTeam(of: bundleURL, flags: Self.inspectFlags)
    }

    public func isApplePlatformCode(_ bundleURL: URL) async -> Bool {
        guard let code = try? Self.staticCode(at: bundleURL) else { return false }
        return (try? Self.check(code, requirement: "anchor apple", flags: Self.inspectFlags)) != nil
    }

    private static func anchoredTeam(of bundleURL: URL, flags: SecCSFlags) throws -> String {
        let code = try staticCode(at: bundleURL)
        try check(code, requirement: CodeSigningRequirement.trustedOrigin, flags: flags)
        let teamID = try unverifiedTeamIdentifier(of: code)
        try checkPinned(code, team: teamID, flags: flags)
        return teamID
    }

    /// The pinned requirement plus the CodeDirectory team. A Mac App Store leaf is Apple's own
    /// certificate and carries no developer OU, so for those the team comes from the CodeDirectory
    /// that Apple signed; for Developer ID both must name `team`.
    private static func checkPinned(_ code: SecStaticCode, team: String, flags: SecCSFlags) throws {
        try check(code, requirement: CodeSigningRequirement.pinned(team: team), flags: flags)
        let actual = try unverifiedTeamIdentifier(of: code)
        guard actual == team else {
            throw UpdaterError.teamIdentifierMismatch(expected: team, actual: actual)
        }
    }

    public func verify(bundleURL: URL, expectedTeam: String) async throws {
        let code = try Self.staticCode(at: bundleURL)
        do {
            try Self.checkPinned(code, team: expectedTeam, flags: Self.verifyFlags)
        } catch {
            // Report a plain team mismatch as such; anything else stays a signature error.
            if let actual = try? Self.unverifiedTeamIdentifier(of: code), actual != expectedTeam {
                throw UpdaterError.teamIdentifierMismatch(expected: expectedTeam, actual: actual)
            }
            throw error
        }
    }

    public func verifyDiskImage(at imageURL: URL, expectedTeam: String?) async throws -> DiskImageSignatureStatus {
        let code = try Self.staticCode(at: imageURL)
        do {
            if let expectedTeam {
                try Self.checkPinned(code, team: expectedTeam, flags: Self.readFlags)
            } else {
                try Self.check(code, requirement: CodeSigningRequirement.trustedOrigin, flags: Self.readFlags)
            }
        } catch UpdaterError.signatureInvalid(let message) where message == Self.unsignedMessage {
            return .unsigned
        }
        return .verified(teamIdentifier: try Self.unverifiedTeamIdentifier(of: code))
    }

    // MARK: - Security framework

    static let unsignedMessage = "code object is not signed at all"

    private static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw UpdaterError.signatureInvalid("Cannot read code at \(url.lastPathComponent) (\(describe(status)))")
        }
        return code
    }

    private static func check(_ code: SecStaticCode, requirement text: String, flags: SecCSFlags) throws {
        var requirement: SecRequirement?
        let created = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard created == errSecSuccess, let requirement else {
            throw UpdaterError.signatureInvalid("Invalid code requirement (\(describe(created)))")
        }
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        switch status {
        case errSecSuccess:
            return
        case errSecCSUnsigned:
            throw UpdaterError.signatureInvalid(unsignedMessage)
        case errSecCSReqFailed:
            throw UpdaterError.signatureInvalid(
                "Signature is not from an Apple-issued Developer ID / App Store identity of the expected team"
            )
        default:
            throw UpdaterError.signatureInvalid(describe(status))
        }
    }

    /// Team from the CodeDirectory. Only meaningful after an anchored requirement check.
    private static func unverifiedTeamIdentifier(of code: SecStaticCode) throws -> String {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess, let dictionary = info as? [String: Any] else {
            throw UpdaterError.signatureInvalid("Cannot read signing information (\(describe(status)))")
        }
        guard let teamID = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !teamID.isEmpty else {
            throw UpdaterError.signatureInvalid("Bundle has no team identifier (ad-hoc or unsigned)")
        }
        return teamID
    }

    private static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return message ?? "OSStatus \(status)"
    }
}

/// Pure builder for the code requirements used by `CodeSignatureVerifier`.
public enum CodeSigningRequirement {
    /// Leaf issued by Apple's "Mac App Store" / "Apple Mac OS Application Signing" CA.
    static let macAppStoreLeaf = "certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */"
    /// Developer ID CA intermediate plus a Developer ID Application leaf.
    static let developerIDChain = "certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */"

    /// Apple's own code, Mac App Store code, or Developer ID Application code. Rejects ad-hoc,
    /// self-signed, Apple Development and any non-Apple-anchored identities.
    public static let trustedOrigin =
        "anchor apple or (anchor apple generic and (\(macAppStoreLeaf) or (\(developerIDChain))))"

    /// Apple-anchored Mac App Store signature, or Developer ID signature whose leaf OU is `team`.
    /// The Mac App Store leaf has no developer OU, so callers must also match the CodeDirectory
    /// team (`CodeSignatureVerifier.checkPinned`). Throws for malformed Team IDs, so the value
    /// can never alter the requirement's structure.
    public static func pinned(team: String) throws -> String {
        guard isValidTeamIdentifier(team) else {
            throw UpdaterError.signatureInvalid("Malformed Team ID \"\(team.prefix(32))\"")
        }
        return "anchor apple generic and (\(macAppStoreLeaf)"
            + " or (\(developerIDChain) and certificate leaf[subject.OU] = \"\(team)\"))"
    }

    /// Apple Team IDs are 10 upper-case letters or digits.
    public static func isValidTeamIdentifier(_ team: String) -> Bool {
        team.count == 10 && team.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar))
        }
    }
}
