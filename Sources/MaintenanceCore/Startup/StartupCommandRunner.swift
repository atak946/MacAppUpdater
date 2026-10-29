import Foundation
import os

/// Output of a finished command.
public struct CommandOutput: Sendable, Equatable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public init(status: Int32, standardOutput: String, standardError: String = "") {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { status == 0 }
}

/// Runs an executable with arguments; injected so tests never call launchctl.
public protocol StartupCommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandOutput
}

/// Runs commands with `Process` directly (no shell), off the caller's actor.
public struct ProcessCommandRunner: StartupCommandRunning {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "ProcessCommandRunner")

    public init() {}

    public func run(_ executable: String, _ arguments: [String]) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try Self.runBlocking(executable, arguments))
                } catch {
                    Self.logger.error("\(executable, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Drain stderr concurrently so neither pipe can fill up and block the child.
        let errorData = ErrorBuffer()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData.data = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return CommandOutput(
            status: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errorData.data, as: UTF8.self)
        )
    }

    /// Written by one reader thread, read after `group.wait()`.
    private final class ErrorBuffer: @unchecked Sendable {
        var data = Data()
    }
}
