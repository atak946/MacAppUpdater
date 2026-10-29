import Foundation
import os

/// Exit status and merged stdout/stderr of a finished command.
public struct SecurityCommandOutput: Sendable, Hashable {
    public let status: Int32
    public let text: String

    public init(status: Int32, text: String) {
        self.status = status
        self.text = text
    }
}

/// Runs a system tool. Returns nil when it can't be launched or times out.
public protocol SecurityCommandRunning: Sendable {
    func run(_ executable: String, arguments: [String]) async -> SecurityCommandOutput?
}

/// `Process`-based runner: no shell, merged output drained off-thread, killed after `timeout`.
public struct ProcessSecurityCommandRunner: SecurityCommandRunning {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "SecurityCommand")
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 8) {
        self.timeout = timeout
    }

    public func run(_ executable: String, arguments: [String]) async -> SecurityCommandOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let gate = OneShot()
        let timeout = self.timeout

        return await withCheckedContinuation { continuation in
            let resume: @Sendable (SecurityCommandOutput?) -> Void = { output in
                if gate.claim() { continuation.resume(returning: output) }
            }
            do {
                try process.run()
            } catch {
                Self.logger.error("Launching \(executable, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                resume(nil)
                return
            }
            try? pipe.fileHandleForWriting.close()
            let reader = pipe.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                let data = reader.readDataToEndOfFile()
                process.waitUntilExit()
                resume(SecurityCommandOutput(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self)))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                Self.logger.notice("\(executable, privacy: .public) timed out")
                process.terminate()
                resume(nil)
            }
        }
    }
}

/// Lets exactly one caller through.
private final class OneShot: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func claim() -> Bool {
        state.withLock { done in
            guard !done else { return false }
            done = true
            return true
        }
    }
}
