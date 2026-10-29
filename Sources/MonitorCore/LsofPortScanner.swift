import Foundation
import os

/// Lists listening TCP sockets and bound UDP sockets by running `lsof` (no shell).
/// Without root, only the current user's processes are visible.
public struct LsofPortScanner: PortScanning {
    static let executable = URL(fileURLWithPath: "/usr/sbin/lsof")
    static let arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-iUDP", "-FpPn"]
    static let timeout: TimeInterval = 3
    private static let logger = Logger(subsystem: "com.macappupdater", category: "LsofPortScanner")

    public init() {}

    public func listeningPorts() async -> [ListeningPort] {
        guard let output = await Self.runLsof() else { return [] }
        return LsofOutputParser.parse(output)
    }

    // MARK: - Process

    /// Wraps the non-Sendable `Process` so the timeout closure can reach it.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    private static func runLsof() async -> String? {
        let box = ProcessBox()
        let pipe = Pipe()
        box.process.executableURL = executable
        box.process.arguments = arguments
        box.process.standardOutput = pipe
        box.process.standardError = FileHandle.nullDevice
        do {
            try box.process.run()
        } catch {
            logger.error("lsof failed to start: \(error.localizedDescription)")
            return nil
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard box.process.isRunning else { return }
            logger.warning("lsof timed out; terminating")
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
