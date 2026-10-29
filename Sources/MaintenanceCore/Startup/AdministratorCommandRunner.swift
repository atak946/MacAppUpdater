import Foundation
import os

/// Runs a batch of `launchctl` commands as root after one administrator prompt.
public protocol PrivilegedCommandRunning: Sendable {
    func runAsAdministrator(_ commands: [LaunchctlCommand]) async throws -> CommandOutput
}

/// Builds the root shell command and its AppleScript wrapper. Every argument is single-quoted,
/// so labels and paths are never interpreted by the shell.
public enum AdministratorScript {
    public static func shellCommand(for commands: [LaunchctlCommand]) -> String {
        commands.map { command in
            let line = ([LaunchdDomain.launchctl] + command.arguments).map(quoted).joined(separator: " ")
            return command.toleratesFailure ? "(\(line) || true)" : line
        }
        .joined(separator: " && ")
    }

    public static func appleScriptSource(for shellCommand: String) -> String {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    /// `osascript` reports a dismissed password prompt as error -128.
    public static func isUserCancellation(_ output: CommandOutput) -> Bool {
        !output.succeeded && output.standardError.contains("-128")
    }

    private static func quoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Prompts with the standard macOS administrator dialog via `osascript`, off the main thread.
public struct OsascriptAdministratorRunner: PrivilegedCommandRunning {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "AdministratorRunner")
    private static let osascript = "/usr/bin/osascript"

    private let runner: any StartupCommandRunning

    public init(runner: any StartupCommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func runAsAdministrator(_ commands: [LaunchctlCommand]) async throws -> CommandOutput {
        let source = AdministratorScript.appleScriptSource(for: AdministratorScript.shellCommand(for: commands))
        let output = try await runner.run(Self.osascript, ["-e", source])
        if !output.succeeded {
            Self.logger.notice("Administrator batch failed (\(output.status)): \(output.standardError, privacy: .public)")
        }
        return output
    }
}
