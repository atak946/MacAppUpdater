import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("TeamPin and InstallBlockReason")
struct TeamPinTests {
    private static let team = "ABCDE12345"

    @Test("the installed team wins and must agree with the pin")
    func installedTeam() throws {
        #expect(try TeamPin.resolve(installedTeam: Self.team, pinnedTeam: nil, appName: "Foo") == Self.team)
        #expect(try TeamPin.resolve(installedTeam: Self.team, pinnedTeam: " \(Self.team) ", appName: "Foo") == Self.team)
        #expect(throws: UpdaterError.teamIdentifierMismatch(expected: "ZZZZZ99999", actual: Self.team)) {
            try TeamPin.resolve(installedTeam: Self.team, pinnedTeam: "ZZZZZ99999", appName: "Foo")
        }
    }

    @Test("an unverifiable installed app needs a well-formed pin")
    func unsignedInstalledApp() throws {
        #expect(try TeamPin.resolve(installedTeam: nil, pinnedTeam: Self.team, appName: "Foo") == Self.team)
        for pin in [nil, "", "  "] {
            #expect {
                try TeamPin.resolve(installedTeam: nil, pinnedTeam: pin, appName: "Foo")
            } throws: { InstallBlockReason(error: $0) == .unverifiablePublisher }
        }
    }

    @Test("a malformed pin fails closed even when the installed app is signed")
    func malformedPin() {
        #expect {
            try TeamPin.resolve(installedTeam: Self.team, pinnedTeam: "bad\" or anchor", appName: "Foo")
        } throws: { InstallBlockReason(error: $0) == .unverifiablePublisher }
    }

    @Test("block reasons are derived from the thrown errors")
    func blockReasons() {
        #expect(throws: (any Error).self) {
            try NotarizationGate.enforce(.unknown(reason: "offline"), policy: .require, bundleIdentifier: "x")
        }
        do {
            try NotarizationGate.enforce(.unknown(reason: "offline"), policy: .require, bundleIdentifier: "x")
        } catch {
            #expect(InstallBlockReason(error: error) == .notarizationUnconfirmed)
        }
        do {
            try NotarizationGate.enforce(.developerIDNotNotarized, policy: .require, bundleIdentifier: "x")
        } catch {
            #expect(InstallBlockReason(error: error) == .notNotarized)
        }
        #expect(InstallBlockReason(error: UpdaterError.signatureInvalid(UpdaterError.gatekeeperRejectedPrefix + "revoked"))
            == .gatekeeperRejected)
        #expect(InstallBlockReason(error: HelperClientError.untrustedBuild) == .untrustedHelperBuild)
        #expect(InstallBlockReason(error: HelperClientError.timedOut) == nil)
        #expect(InstallBlockReason(error: UpdaterError.checksumMismatch) == nil)
    }
}
