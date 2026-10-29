import Foundation
import os

/// Mounts a disk image for the duration of a closure and always detaches it afterwards.
///
/// The image is attached read-only, hidden from Finder, without auto-open, and with
/// hdiutil's checksum verification left on. Detaching (`-force`) is retried; a mount that
/// survives all attempts is logged as a fault but does not fail
/// the install, because the staged app has already been copied out of the volume.
struct DiskImageMounter: Sendable {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "DiskImage")
    private static let hdiutil = "/usr/bin/hdiutil"
    static let maxDetachAttempts = 3

    let commandRunner: any CommandRunner
    /// Pause between detach attempts (injectable so tests do not sleep).
    var detachRetryDelay: Duration = .milliseconds(500)

    func withMountedImage<T: Sendable>(
        at imageURL: URL,
        mountPoint: URL,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        try await commandRunner.run(Self.hdiutil, arguments: [
            "attach", "-nobrowse", "-readonly", "-noautoopen",
            "-mountpoint", mountPoint.path, imageURL.path,
        ])
        do {
            let result = try await body(mountPoint)
            await detach(mountPoint)
            return result
        } catch {
            await detach(mountPoint)
            throw error
        }
    }

    /// Returns true when the volume was detached.
    @discardableResult
    func detach(_ mountPoint: URL) async -> Bool {
        for attempt in 1...Self.maxDetachAttempts {
            do {
                try await commandRunner.run(Self.hdiutil, arguments: ["detach", "-force", mountPoint.path])
                return true
            } catch {
                Self.logger.error(
                    "Detach attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                if attempt < Self.maxDetachAttempts { try? await Task.sleep(for: detachRetryDelay) }
            }
        }
        Self.logger.fault("Disk image left mounted at \(mountPoint.path, privacy: .private)")
        return false
    }
}
