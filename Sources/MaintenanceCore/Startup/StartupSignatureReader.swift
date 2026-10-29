import Foundation
import os
import Security

/// Reads the code signature of an executable.
public protocol StartupSignatureReading: Sendable {
    /// Nil when the file can't be inspected (missing, unreadable).
    func signature(of executable: URL) -> StartupSignature?
}

/// `SecStaticCode`-based reader. Validation skips resources so large bundles stay fast.
public struct SecStaticCodeSignatureReader: StartupSignatureReading {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "StartupSignature")
    private static let appleRequirementText = "anchor apple"

    public init() {}

    public func signature(of executable: URL) -> StartupSignature? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            Self.logger.debug("No static code for \(executable.path, privacy: .public)")
            return nil
        }
        let basicFlags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSDoNotValidateExecutable)
        let validity = SecStaticCodeCheckValidity(code, basicFlags, nil)
        if validity == errSecCSUnsigned { return .unsigned }

        var info: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, infoFlags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else {
            return .unsigned
        }
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        guard let leaf = certificates.first, validity == errSecSuccess else {
            // Ad-hoc signatures carry no certificate; broken signatures prove nothing either.
            return .unsigned
        }
        return StartupSignature(
            signerName: SecCertificateCopySubjectSummary(leaf) as String?,
            teamID: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            isApple: Self.satisfiesAppleAnchor(code, flags: basicFlags),
            isSigned: true
        )
    }

    private static func satisfiesAppleAnchor(_ code: SecStaticCode, flags: SecCSFlags) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(appleRequirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
