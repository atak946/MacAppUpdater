import Foundation
import os
import Testing
@testable import AppUpdaterCore

@Suite("HomebrewCLI")
struct HomebrewCLITests {
    /// Captured from `brew outdated --json=v2 --formula` (Homebrew 4.x).
    static let fixture = """
    {
      "formulae": [
        {
          "name": "simdutf",
          "installed_versions": ["9.3.2_1"],
          "current_version": "9.3.3",
          "pinned": false,
          "pinned_version": null
        },
        {
          "name": "cmake",
          "installed_versions": ["4.4.3", "4.4.4"],
          "current_version": "4.4.5",
          "pinned": true,
          "pinned_version": "4.4.4"
        }
      ],
      "casks": []
    }
    """

    private func makeCLI(output: String = HomebrewCLITests.fixture, brewInstalled: Bool = true) -> (HomebrewCLI, StubCommandRunner) {
        let runner = StubCommandRunner(output: output)
        let cli = HomebrewCLI(
            runner: runner,
            candidatePaths: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
            isExecutable: { path in brewInstalled && path == "/usr/local/bin/brew" }
        )
        return (cli, runner)
    }

    @Test func parsesFixtureSortedByName() throws {
        let formulae = try HomebrewCLI.parseOutdated(Self.fixture)
        #expect(formulae.map(\.name) == ["cmake", "simdutf"])
        #expect(formulae[0] == OutdatedFormula(
            name: "cmake", installedVersions: ["4.4.3", "4.4.4"], currentVersion: "4.4.5", pinned: true
        ))
        #expect(formulae[0].installedVersion == "4.4.4")
        #expect(formulae[1].pinned == false)
    }

    @Test func toleratesWarningsAroundJSON() throws {
        let noisy = "Warning: something on stderr\n\(Self.fixture)\n==> trailing note"
        #expect(try HomebrewCLI.parseOutdated(noisy).count == 2)
    }

    @Test func emptyListParses() throws {
        #expect(try HomebrewCLI.parseOutdated(#"{"formulae":[],"casks":[]}"#).isEmpty)
    }

    @Test(arguments: ["", "Error: not json", #"{"casks": []}"#])
    func invalidOutputThrowsParsingError(_ output: String) {
        #expect(throws: UpdaterError.self) { try HomebrewCLI.parseOutdated(output) }
    }

    @Test(arguments: ["git", "python@3.12", "c++-lib", "node_18", "gnu-sed", "homebrew/core/git", "user/tap/tool.x"])
    func acceptsValidNames(_ name: String) {
        #expect(HomebrewCLI.isValidFormulaName(name))
    }

    @Test(arguments: [
        "", "--force", "-v", "git; rm -rf ~", "git && ls", "$(whoami)", "`id`", "a b", "../etc",
        "a/../b", "/abs", "a/b/c/d", "name\n", "git|cat", String(repeating: "a", count: 200),
    ])
    func rejectsInvalidNames(_ name: String) {
        #expect(!HomebrewCLI.isValidFormulaName(name))
    }

    @Test func locatesFirstExistingBrew() {
        let (cli, _) = makeCLI()
        #expect(cli.isAvailable)
        #expect(cli.brewPath == "/usr/local/bin/brew")
    }

    @Test func outdatedRunsBrewThroughEnvWithoutAutoUpdate() async throws {
        let (cli, runner) = makeCLI()
        let formulae = try await cli.outdatedFormulae()

        #expect(formulae.count == 2)
        let call = try #require(runner.calls.first)
        #expect(call.executable == "/usr/bin/env")
        #expect(call.arguments.contains("HOMEBREW_NO_AUTO_UPDATE=1"))
        #expect(Array(call.arguments.suffix(4)) == ["/usr/local/bin/brew", "outdated", "--json=v2", "--formula"])
    }

    @Test func upgradePassesNameAsSeparateArgument() async throws {
        let (cli, runner) = makeCLI(output: "")
        try await cli.upgrade("python@3.12")

        let call = try #require(runner.calls.first)
        #expect(Array(call.arguments.suffix(5)) == ["/usr/local/bin/brew", "upgrade", "--formula", "--", "python@3.12"])
    }

    @Test func upgradeRejectsInjectionWithoutRunning() async {
        let (cli, runner) = makeCLI(output: "")
        await #expect(throws: HomebrewError.invalidFormulaName("git; rm -rf ~")) {
            try await cli.upgrade("git; rm -rf ~")
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func throwsNotInstalledWhenBrewMissing() async {
        let (cli, runner) = makeCLI(brewInstalled: false)
        #expect(!cli.isAvailable)
        await #expect(throws: HomebrewError.notInstalled) { try await cli.outdatedFormulae() }
        await #expect(throws: HomebrewError.notInstalled) { try await cli.upgrade("git") }
        #expect(runner.calls.isEmpty)
    }

    @Test func propagatesCommandFailure() async {
        let failure = UpdaterError.commandFailed(command: "brew", status: 1, output: "Error: boom")
        let runner = StubCommandRunner(output: "", error: failure)
        let cli = HomebrewCLI(runner: runner, candidatePaths: ["/brew"], isExecutable: { _ in true })
        await #expect(throws: failure) { try await cli.upgrade("git") }
    }
}

/// Records invocations and returns a canned output (or error).
private final class StubCommandRunner: CommandRunner {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
    }

    private let output: String
    private let error: UpdaterError?
    private let recorded = OSAllocatedUnfairLock(initialState: [Call]())

    init(output: String, error: UpdaterError? = nil) {
        self.output = output
        self.error = error
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func run(_ executable: String, arguments: [String]) async throws -> String {
        recorded.withLock { $0.append(Call(executable: executable, arguments: arguments)) }
        if let error { throw error }
        return output
    }
}
