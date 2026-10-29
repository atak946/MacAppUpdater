import Darwin
import Foundation
import os
import Testing
@testable import AppUpdaterCore

/// Answers pkgutil with a fixture and records `installer` runs together with the staged bytes.
private final class HelperStubRunner: CommandRunner, Sendable {
    struct InstallerRun: Equatable {
        let stagedPath: String
        let stagedBytes: Data
    }

    private let pkgutilOutput: String
    private let installerDelay: Duration
    private let state = OSAllocatedUnfairLock(initialState: (runs: [InstallerRun](), active: 0, maxActive: 0))

    init(pkgutilOutput: String, installerDelay: Duration = .zero) {
        self.pkgutilOutput = pkgutilOutput
        self.installerDelay = installerDelay
    }

    var installerRuns: [InstallerRun] { state.withLock { $0.runs } }
    var maxConcurrentInstalls: Int { state.withLock { $0.maxActive } }

    func run(_ executable: String, arguments: [String]) async throws -> String {
        guard executable == HelperPackageInstallCoordinator.installerPath else { return pkgutilOutput }
        let path = arguments[1]
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        state.withLock {
            $0.active += 1
            $0.maxActive = max($0.maxActive, $0.active)
        }
        try await Task.sleep(for: installerDelay)
        state.withLock {
            $0.active -= 1
            $0.runs.append(InstallerRun(stagedPath: path, stagedBytes: bytes))
        }
        return "installer: The install was successful."
    }
}

@Suite("HelperPackageInstallCoordinator")
struct HelperPackageInstallCoordinatorTests {
    private static let bytes = Data("xar!signed-package".utf8)
    private let directory: HelperTestDirectory
    private let uid = getuid()

    init() throws {
        directory = try HelperTestDirectory()
    }

    private func makeCoordinator(_ runner: HelperStubRunner) -> HelperPackageInstallCoordinator {
        HelperPackageInstallCoordinator(
            stager: PackageStager(parentDirectory: directory.root),
            commandRunner: runner
        )
    }

    private func makeHandle(_ name: String = "Update.pkg") throws -> FileHandle {
        try directory.openHandle(directory.makeFile(name, contents: Self.bytes))
    }

    @Test("installs the staged copy containing exactly the caller's bytes, then removes it")
    func installsStagedCopy() async throws {
        let runner = HelperStubRunner(pkgutilOutput: PkgutilFixtures.developerID)
        try await makeCoordinator(runner).install(from: makeHandle(), expectedTeamID: "ABCDE12345", callerUID: uid)

        let run = try #require(runner.installerRuns.first)
        #expect(run.stagedBytes == Self.bytes)
        #expect(run.stagedPath.hasPrefix(directory.root.path))
        #expect(run.stagedPath.hasSuffix("/" + PackageStager.stagedFileName))
        #expect(!FileManager.default.fileExists(atPath: run.stagedPath))
    }

    @Test("rejects a package signed by another team")
    func rejectsTeamMismatch() async throws {
        let runner = HelperStubRunner(pkgutilOutput: PkgutilFixtures.developerID)
        await #expect(throws: UpdaterError.teamIdentifierMismatch(expected: "ZZZZZ99999", actual: "ABCDE12345")) {
            try await makeCoordinator(runner).install(from: makeHandle(), expectedTeamID: "ZZZZZ99999", callerUID: uid)
        }
        #expect(runner.installerRuns.isEmpty)
    }

    @Test("rejects Apple-signed, non-notarized and unsigned packages",
          arguments: [PkgutilFixtures.apple, PkgutilFixtures.developerIDNotNotarized, PkgutilFixtures.unsigned])
    func rejectsUntrustedSignatures(output: String) async throws {
        let runner = HelperStubRunner(pkgutilOutput: output)
        await #expect(throws: UpdaterError.self) {
            try await makeCoordinator(runner).install(from: makeHandle(), expectedTeamID: "ABCDE12345", callerUID: uid)
        }
        #expect(runner.installerRuns.isEmpty)
    }

    @Test("rejects a missing or malformed expected team")
    func rejectsNoExpectedTeam() async throws {
        let runner = HelperStubRunner(pkgutilOutput: PkgutilFixtures.developerID)
        await #expect(throws: HelperInstallRequestError.invalidTeamIdentifier) {
            try await makeCoordinator(runner).install(from: makeHandle(), expectedTeamID: "", callerUID: uid)
        }
        #expect(runner.installerRuns.isEmpty)
    }

    @Test("rejects files not owned by the caller")
    func rejectsForeignOwner() async throws {
        let runner = HelperStubRunner(pkgutilOutput: PkgutilFixtures.developerID)
        await #expect(throws: HelperInstallRequestError.self) {
            try await makeCoordinator(runner).install(from: makeHandle(), expectedTeamID: "ABCDE12345", callerUID: uid + 1)
        }
        #expect(runner.installerRuns.isEmpty)
    }

    @Test("serializes concurrent installs")
    func serializesInstalls() async throws {
        let runner = HelperStubRunner(pkgutilOutput: PkgutilFixtures.developerID, installerDelay: .milliseconds(50))
        let coordinator = makeCoordinator(runner)
        let handles = try (0..<3).map { try makeHandle("Update\($0).pkg") }
        let uid = uid
        try await withThrowingTaskGroup(of: Void.self) { group in
            for handle in handles {
                group.addTask { try await coordinator.install(from: handle, expectedTeamID: "ABCDE12345", callerUID: uid) }
            }
            try await group.waitForAll()
        }
        #expect(runner.installerRuns.count == 3)
        #expect(runner.maxConcurrentInstalls == 1)
    }
}

@Suite("PackageTrustPolicy")
struct PackageTrustPolicyTests {
    private func signature(
        kind: PackageSignature.Kind = .developerID, team: String? = "ABCDE12345", notarized: Bool = true
    ) -> PackageSignature {
        PackageSignature(
            kind: kind, teamIdentifier: team,
            signerName: kind == .developerID ? "Developer ID Installer: Example (\(team ?? ""))" : "Software Update",
            isNotarized: notarized
        )
    }

    @Test("accepts a notarized Developer ID Installer package of the expected team")
    func accepts() throws {
        try PackageTrustPolicy.validate(signature(), expectedTeamID: "ABCDE12345")
    }

    @Test("rejects when no expected team is known")
    func rejectsNoTeam() {
        #expect(throws: UpdaterError.self) { try PackageTrustPolicy.validate(signature(), expectedTeamID: nil) }
    }

    @Test("rejects Apple software, missing notarization and team mismatch")
    func rejects() {
        #expect(throws: UpdaterError.signatureInvalid("Apple-signed packages are not accepted for third-party updates")) {
            try PackageTrustPolicy.validate(signature(kind: .appleSoftware, team: nil), expectedTeamID: "ABCDE12345")
        }
        #expect(throws: UpdaterError.signatureInvalid("Package is not notarized by Apple")) {
            try PackageTrustPolicy.validate(signature(notarized: false), expectedTeamID: "ABCDE12345")
        }
        #expect(throws: UpdaterError.teamIdentifierMismatch(expected: "ZZZZZ99999", actual: "ABCDE12345")) {
            try PackageTrustPolicy.validate(signature(), expectedTeamID: "ZZZZZ99999")
        }
    }
}

@Suite("HelperIdleMonitor")
struct HelperIdleMonitorTests {
    private final class Counter: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: 0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    @Test("fires after the idle timeout when nothing is active")
    func firesWhenIdle() async throws {
        let counter = Counter()
        let monitor = HelperIdleMonitor(timeout: 0.05) { counter.increment() }
        monitor.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.count == 1)
    }

    @Test("does not fire while activity is ongoing, fires once it ends")
    func waitsForActivity() async throws {
        let counter = Counter()
        let monitor = HelperIdleMonitor(timeout: 0.05) { counter.increment() }
        monitor.start()
        monitor.begin()
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.count == 0)
        monitor.end()
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.count == 1)
        #expect(monitor.activeCount == 0)
    }
}
