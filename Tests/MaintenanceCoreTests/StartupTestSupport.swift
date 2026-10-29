import Foundation
@testable import MaintenanceCore

/// Records every command and answers from a canned table keyed by the joined arguments.
final class FakeCommandRunner: StartupCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let responses: [String: CommandOutput]
    private let fallback: CommandOutput

    init(_ responses: [String: CommandOutput] = [:], fallback: CommandOutput = CommandOutput(status: 113, standardOutput: "")) {
        self.responses = responses
        self.fallback = fallback
    }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandOutput {
        lock.withLock { recorded.append(arguments) }
        return responses[arguments.joined(separator: " ")] ?? fallback
    }
}

/// Returns a fixed signature for every executable.
struct FixedSignatureReader: StartupSignatureReading {
    var result: StartupSignature?
    func signature(of executable: URL) -> StartupSignature? { result }
}

func plistData(_ dictionary: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
}

func makeItem(
    label: String = "com.example.agent",
    kind: StartupItemKind = .userAgent,
    isEnabled: Bool = true,
    isLoaded: Bool = true,
    signature: StartupSignature? = nil
) -> StartupItem {
    StartupItem(
        plistURL: URL(fileURLWithPath: "/Users/me/Library/LaunchAgents/\(label).plist"), label: label, kind: kind,
        executableURL: URL(fileURLWithPath: "/usr/local/bin/agent"), arguments: [], appName: nil, appBundleURL: nil,
        signature: signature, runAtLoad: true, keepAlive: false, schedule: nil, isEnabled: isEnabled, isLoaded: isLoaded
    )
}

/// Records administrator batches instead of prompting.
final class FakeAdminRunner: PrivilegedCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[LaunchctlCommand]] = []
    private let result: CommandOutput

    init(result: CommandOutput = CommandOutput(status: 0, standardOutput: "")) {
        self.result = result
    }

    var batches: [[LaunchctlCommand]] { lock.withLock { recorded } }

    func runAsAdministrator(_ commands: [LaunchctlCommand]) async throws -> CommandOutput {
        lock.withLock { recorded.append(commands) }
        return result
    }
}
