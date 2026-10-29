import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("ProcessCommandRunner")
struct ProcessCommandRunnerTests {
    let runner = ProcessCommandRunner()

    @Test("returns stdout of a successful command")
    func echoReturnsOutput() async throws {
        let output = try await runner.run("/bin/echo", arguments: ["hello", "world"])
        #expect(output == "hello world\n")
    }

    @Test("throws commandFailed on non-zero exit")
    func falseThrows() async {
        await #expect(throws: UpdaterError.commandFailed(command: "/usr/bin/false", status: 1, output: "")) {
            try await runner.run("/usr/bin/false", arguments: [])
        }
    }

    @Test("captures stderr output")
    func capturesStandardError() async throws {
        let output = try await runner.run("/bin/sh", arguments: ["-c", "echo oops 1>&2"])
        #expect(output == "oops\n")
    }

    @Test("drains large output without deadlocking")
    func largeOutput() async throws {
        let output = try await runner.run("/bin/sh", arguments: ["-c", "head -c 1000000 /dev/zero | tr '\\0' 'a'"])
        #expect(output.utf8.count == 1_000_000)
    }

    @Test("throws when the executable does not exist")
    func missingExecutableThrows() async {
        await #expect(throws: UpdaterError.self) {
            try await runner.run("/nonexistent/tool", arguments: [])
        }
    }
}
