import Foundation
import os

/// Runs a system tool (no shell) and returns its standard output, killing it after a timeout.
enum ToolOutputRunner {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "ToolOutputRunner")

    /// Wraps the non-Sendable `Process` so the timeout closure can reach it.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    /// Nil when the tool could not be started.
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async -> String? {
        let box = ProcessBox()
        let pipe = Pipe()
        let name = executable.lastPathComponent
        box.process.executableURL = executable
        box.process.arguments = arguments
        box.process.standardOutput = pipe
        box.process.standardError = FileHandle.nullDevice
        do {
            try box.process.run()
        } catch {
            logger.error("\(name, privacy: .public) failed to start: \(error.localizedDescription)")
            return nil
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard box.process.isRunning else { return }
            logger.warning("\(name, privacy: .public) timed out; terminating")
            box.process.terminate()
        }
        let handle = pipe.fileHandleForReading
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = handle.readDataToEndOfFile()
                box.process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
