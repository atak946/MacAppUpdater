import Foundation
import os

/// Changes whether a startup item runs.
public protocol StartupControlling: Sendable {
    /// Persistently enables or disables `item`; returns the item with its new state.
    func setEnabled(_ enabled: Bool, for item: StartupItem) async throws -> StartupItem
}

public enum StartupControlError: Error, Equatable, LocalizedError {
    /// Apple's own jobs are never modified.
    case appleItemProtected(label: String)
    /// The label contains characters that aren't valid in a launchd label.
    case invalidLabel(String)
    /// The administrator password prompt was dismissed.
    case cancelled
    case commandFailed(arguments: [String], status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .appleItemProtected(let label):
            "\(label) is part of macOS and can't be changed."
        case .invalidLabel(let label):
            "\(label) isn't a valid launchd label, so it wasn't changed."
        case .cancelled:
            "The change was cancelled."
        case .commandFailed(let arguments, let status, let message):
            "launchctl \(arguments.joined(separator: " ")) failed (\(status)): \(message)"
        }
    }
}

/// One `launchctl` invocation; `toleratesFailure` steps may fail without aborting the change.
public struct LaunchctlCommand: Sendable, Equatable {
    public let arguments: [String]
    public let toleratesFailure: Bool

    public init(_ arguments: [String], toleratesFailure: Bool = false) {
        self.arguments = arguments
        self.toleratesFailure = toleratesFailure
    }
}

/// Toggles launchd jobs with `launchctl bootout/bootstrap` plus a persistent `disable/enable`.
/// Agents run in the user's gui domain directly; daemons go through one administrator prompt.
public struct LaunchctlStartupController: StartupControlling {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "StartupController")

    private let runner: any StartupCommandRunning
    private let adminRunner: any PrivilegedCommandRunning
    private let uid: uid_t

    public init(
        runner: any StartupCommandRunning = ProcessCommandRunner(),
        adminRunner: any PrivilegedCommandRunning = OsascriptAdministratorRunner(),
        uid: uid_t = getuid()
    ) {
        self.runner = runner
        self.adminRunner = adminRunner
        self.uid = uid
    }

    public func setEnabled(_ enabled: Bool, for item: StartupItem) async throws -> StartupItem {
        let commands = try Self.commands(enabling: enabled, item: item, uid: uid)
        if item.requiresAdmin {
            return try await setEnabledAsAdministrator(enabled, item: item, commands: commands)
        }
        var isLoaded = item.isLoaded
        for command in commands {
            let output = try await runner.run(LaunchdDomain.launchctl, command.arguments)
            if output.succeeded {
                if command.arguments.first == "bootstrap" { isLoaded = true }
                if command.arguments.first == "bootout" { isLoaded = false }
                continue
            }
            let message = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            guard command.toleratesFailure else {
                throw StartupControlError.commandFailed(arguments: command.arguments, status: output.status, message: message)
            }
            Self.logger.notice("Tolerated launchctl failure \(output.status): \(message, privacy: .public)")
        }
        Self.logger.info("\(item.label, privacy: .public) is now \(enabled ? "enabled" : "disabled", privacy: .public)")
        return item.with(isEnabled: enabled, isLoaded: isLoaded)
    }

    /// Runs the whole batch after one password prompt; tolerated steps can't abort it.
    private func setEnabledAsAdministrator(
        _ enabled: Bool, item: StartupItem, commands: [LaunchctlCommand]
    ) async throws -> StartupItem {
        let output = try await adminRunner.runAsAdministrator(commands)
        if AdministratorScript.isUserCancellation(output) { throw StartupControlError.cancelled }
        guard output.succeeded else {
            let message = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw StartupControlError.commandFailed(arguments: commands.last?.arguments ?? [], status: output.status, message: message)
        }
        Self.logger.info("\(item.label, privacy: .public) is now \(enabled ? "enabled" : "disabled", privacy: .public) (admin)")
        return item.with(isEnabled: enabled, isLoaded: enabled ? true : false)
    }

    /// The command sequence for a change, after the safety checks.
    ///
    /// Disabling unloads first (only if loaded) and then records the persistent override;
    /// enabling records the override first so `bootstrap` isn't refused for a disabled job.
    public static func commands(enabling enabled: Bool, item: StartupItem, uid: uid_t) throws -> [LaunchctlCommand] {
        guard !item.isAppleItem else { throw StartupControlError.appleItemProtected(label: item.label) }
        guard isValidLabel(item.label) else { throw StartupControlError.invalidLabel(item.label) }
        let domain = LaunchdDomain.domain(for: item.kind, uid: uid)
        let service = LaunchdDomain.service(item.label, kind: item.kind, uid: uid)
        if enabled {
            var commands = [LaunchctlCommand(["enable", service])]
            if !item.isLoaded {
                // A job without RunAtLoad still gets loaded so its schedule or triggers apply.
                commands.append(LaunchctlCommand(["bootstrap", domain, item.plistURL.path], toleratesFailure: true))
            }
            return commands
        }
        var commands: [LaunchctlCommand] = []
        if item.isLoaded {
            commands.append(LaunchctlCommand(["bootout", domain, item.plistURL.path], toleratesFailure: true))
        }
        commands.append(LaunchctlCommand(["disable", service]))
        return commands
    }
}

/// launchd labels are reverse-DNS style; anything else is refused before a command is built.
private func isValidLabel(_ label: String) -> Bool {
    !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
}
