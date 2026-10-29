import Foundation
import os

/// Runs command-line tools via `Foundation.Process` without blocking the caller.
///
/// stdout and stderr are merged into one pipe that is drained on a background
/// queue while the process runs, so a chatty tool can never fill the pipe buffer
/// and deadlock. The call resumes only after both EOF and termination are observed.
public struct ProcessCommandRunner: CommandRunner {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "CommandRunner")

    public init() {}

    @discardableResult
    public func run(_ executable: String, arguments: [String]) async throws -> String {
        let commandLine = ([executable] + arguments).joined(separator: " ")
        Self.logger.debug("Running \(commandLine, privacy: .public)")

        let (status, output) = try await execute(executable, arguments: arguments)
        guard status == 0 else {
            Self.logger.error("\(commandLine, privacy: .public) failed with status \(status)")
            throw UpdaterError.commandFailed(command: commandLine, status: status, output: output)
        }
        return output
    }

    private func execute(_ executable: String, arguments: [String]) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let reader = pipe.fileHandleForReading

        return try await withCheckedThrowingContinuation { continuation in
            let collector = CompletionCollector(continuation: continuation)
            process.terminationHandler = { finished in
                collector.finish(status: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                collector.fail(UpdaterError.commandFailed(
                    command: executable, status: -1, output: error.localizedDescription
                ))
                return
            }
            // The parent's write end must be closed so the reader sees EOF on exit.
            try? pipe.fileHandleForWriting.close()
            DispatchQueue.global(qos: .utility).async {
                let data = reader.readDataToEndOfFile()
                collector.finish(output: String(decoding: data, as: UTF8.self))
            }
        }
    }
}

/// Resumes the continuation exactly once, after both output and exit status are known.
private final class CompletionCollector: Sendable {
    private struct State {
        var status: Int32?
        var output: String?
        var isResumed = false
    }

    private let continuation: CheckedContinuation<(Int32, String), any Error>
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(continuation: CheckedContinuation<(Int32, String), any Error>) {
        self.continuation = continuation
    }

    func finish(status: Int32) {
        resumeIfReady { $0.status = status }
    }

    func finish(output: String) {
        resumeIfReady { $0.output = output }
    }

    func fail(_ error: any Error) {
        let shouldResume = state.withLock { state -> Bool in
            guard !state.isResumed else { return false }
            state.isResumed = true
            return true
        }
        if shouldResume { continuation.resume(throwing: error) }
    }

    private func resumeIfReady(_ update: @Sendable (inout State) -> Void) {
        let result = state.withLock { state -> (Int32, String)? in
            update(&state)
            guard !state.isResumed, let status = state.status, let output = state.output else {
                return nil
            }
            state.isResumed = true
            return (status, output)
        }
        if let result { continuation.resume(returning: result) }
    }
}

/// Absolute paths of system tools shared by several components.
enum SystemTool {
    static let ditto = "/usr/bin/ditto"
}
