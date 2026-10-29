import Foundation
import Testing
@testable import AppUpdaterCore

enum PkgutilFixtures {
    static let developerID = """
    Package "Example-2.0.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Signed with a trusted timestamp on: 2024-05-01 10:00:00 +0000
       Certificate Chain:
        1. Developer ID Installer: Example Software Inc. (ABCDE12345)
           Expires: 2027-02-01 22:12:15 +0000
           SHA256 Fingerprint:
               AA BB CC DD EE FF 00 11 22 33 44 55 66 77 88 99 AA BB CC DD EE FF
           ------------------------------------------------------------------------
        2. Developer ID Certification Authority
           Expires: 2031-09-17 00:00:00 +0000
           ------------------------------------------------------------------------
        3. Apple Root CA
           Expires: 2035-02-09 21:40:36 +0000

    """

    /// Valid Developer ID Installer signature without a notarization ticket.
    static let developerIDNotNotarized = """
    Package "Example-2.0.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Signed with a trusted timestamp on: 2024-05-01 10:00:00 +0000
       Certificate Chain:
        1. Developer ID Installer: Example Software Inc. (ABCDE12345)
           Expires: 2027-02-01 22:12:15 +0000
        2. Developer ID Certification Authority
        3. Apple Root CA

    """

    static let apple = """
    Package "Safari.pkg":
       Status: signed Apple Software
       Certificate Chain:
        1. Software Update
           Expires: 2026-10-24 17:39:41 +0000
        2. Apple Software Update Certification Authority
        3. Apple Root CA

    """

    static let unsigned = """
    Package "Unsigned.pkg":
       Status: no signature

    """

    static let untrusted = """
    Package "SelfSigned.pkg":
       Status: signed by untrusted certificate
       Certificate Chain:
        1. My Self Signed Cert
    """

    static let wrongLeaf = """
    Package "Weird.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Certificate Chain:
        1. Developer ID Application: Example Software Inc. (ABCDE12345)
    """
}

/// Returns a fixed output, or throws `commandFailed` with that output when `exitStatus != 0`.
struct PkgutilStubRunner: CommandRunner {
    let output: String
    var exitStatus: Int32 = 0

    func run(_ executable: String, arguments: [String]) async throws -> String {
        guard exitStatus == 0 else {
            throw UpdaterError.commandFailed(command: executable, status: exitStatus, output: output)
        }
        return output
    }
}

@Suite("PackageSignatureChecker")
struct PackageSignatureCheckerTests {
    @Test("parses a notarized Developer ID Installer signature")
    func parsesDeveloperID() throws {
        let signature = try PackageSignatureChecker.parse(PkgutilFixtures.developerID)
        #expect(signature == PackageSignature(
            kind: .developerID,
            teamIdentifier: "ABCDE12345",
            signerName: "Developer ID Installer: Example Software Inc. (ABCDE12345)",
            isNotarized: true
        ))
    }

    @Test("accepts Apple software without a team id")
    func parsesApple() throws {
        let signature = try PackageSignatureChecker.parse(PkgutilFixtures.apple)
        #expect(signature.kind == .appleSoftware)
        #expect(signature.teamIdentifier == nil)
        #expect(signature.isNotarized == false)
    }

    @Test("rejects unsigned, untrusted, wrong-leaf and garbage output",
          arguments: [PkgutilFixtures.unsigned, PkgutilFixtures.untrusted, PkgutilFixtures.wrongLeaf, "garbage"])
    func rejects(output: String) {
        #expect(throws: UpdaterError.self) { try PackageSignatureChecker.parse(output) }
    }

    @Test("extracts only well-formed team ids")
    func teamIdentifierExtraction() {
        #expect(PackageSignatureChecker.teamIdentifier(fromCertificateName: "Developer ID Installer: A (Z9Y8X7W6V5)") == "Z9Y8X7W6V5")
        #expect(PackageSignatureChecker.teamIdentifier(fromCertificateName: "Developer ID Installer: A (short)") == nil)
        #expect(PackageSignatureChecker.teamIdentifier(fromCertificateName: "Developer ID Installer: A") == nil)
    }

    @Test("parses output of a failing pkgutil run and rejects it")
    func nonZeroExitIsParsed() async {
        let checker = PackageSignatureChecker(commandRunner: PkgutilStubRunner(output: PkgutilFixtures.unsigned, exitStatus: 1))
        await #expect(throws: UpdaterError.signatureInvalid("Package not accepted (no signature)")) {
            try await checker.check(URL(fileURLWithPath: "/tmp/Unsigned.pkg"))
        }
    }

    @Test("check returns the parsed signature")
    func checkSucceeds() async throws {
        let checker = PackageSignatureChecker(commandRunner: PkgutilStubRunner(output: PkgutilFixtures.developerID))
        let signature = try await checker.check(URL(fileURLWithPath: "/tmp/Example.pkg"))
        #expect(signature.teamIdentifier == "ABCDE12345")
    }

    @Test("parses a non-notarized Developer ID signature as not notarized")
    func parsesNotNotarized() throws {
        let signature = try PackageSignatureChecker.parse(PkgutilFixtures.developerIDNotNotarized)
        #expect(signature.kind == .developerID)
        #expect(signature.isNotarized == false)
    }

    @Test("release requirement pins the team and forbids get-task-allow")
    func releaseRequirement() {
        #expect(HelperCodeSigning.peerRequirement(identifier: "com.x", teamIdentifier: "ABCDE12345", mode: .release)
            == "anchor apple generic and identifier \"com.x\" and certificate leaf[subject.OU] = \"ABCDE12345\""
            + " and !(entitlement[\"com.apple.security.get-task-allow\"] exists)")
    }

    @Test("release requirement fails closed without a valid team id",
          arguments: [nil, "", "bad\" or true", "abcde12345"] as [String?])
    func releaseFailsClosed(team: String?) {
        #expect(HelperCodeSigning.peerRequirement(identifier: "com.x", teamIdentifier: team, mode: .release) == nil)
    }

    @Test("development requirement falls back to identifier only")
    func developmentRequirement() {
        #expect(HelperCodeSigning.peerRequirement(identifier: "com.x", teamIdentifier: "ABCDE12345", mode: .development)
            == "anchor apple generic and identifier \"com.x\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
        #expect(HelperCodeSigning.peerRequirement(identifier: "com.x", teamIdentifier: nil, mode: .development)
            == "identifier \"com.x\"")
        #expect(HelperCodeSigning.peerRequirement(identifier: "com.x", teamIdentifier: "bad\" or true", mode: .development)
            == "identifier \"com.x\"")
    }

    @Test("the identifier-only mode is compiled in only for DEBUG builds")
    func modeMatchesBuildConfiguration() {
        #if DEBUG
        #expect(HelperCodeSigning.currentMode == .development)
        #else
        #expect(HelperCodeSigning.currentMode == .release)
        #endif
    }

    @Test("app-side helper requirement uses the helper identifier and fails closed in release")
    func helperRequirement() {
        #expect(HelperClient.helperRequirement(teamIdentifier: nil, mode: .release) == nil)
        #expect(HelperClient.helperRequirement(teamIdentifier: "ABCDE12345", mode: .release)?
            .contains("identifier \"\(HelperConstants.helperCodeSigningIdentifier)\"") == true)
    }
}
