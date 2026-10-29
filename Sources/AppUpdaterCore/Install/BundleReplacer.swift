import AppKit
import Darwin
import Foundation
import os

/// File operations shared by install and restore: private staging near the target,
/// atomic swap, and post-swap verification with rollback (M-6).
struct BundleReplacer: Sendable {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "BundleReplacer")

    /// FileManager is documented as thread-safe but not annotated `Sendable` (same pattern as
    /// `AppInstaller`: scope the unchecked escape to this one property).
    nonisolated(unsafe) let fileManager: FileManager
    /// Moves a replaced bundle the user cannot delete (root-owned) to the Trash via the Finder.
    var recycler: @Sendable (URL) async throws -> Void = { url in
        _ = try await NSWorkspace.shared.recycle([url])
    }

    /// A directory on the same volume as `targetURL`, so the final swap is atomic.
    /// It is owned by the current user and has mode 0700, so other users cannot read or
    /// modify staged bundles. (Same-user processes can; see the re-verification in `replace`.)
    func makeWorkDirectory(near targetURL: URL) throws -> URL {
        let anchor = fileManager.fileExists(atPath: targetURL.path) ? targetURL : targetURL.deletingLastPathComponent()
        let directory: URL
        do {
            directory = try fileManager.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: anchor, create: true
            )
        } catch {
            throw UpdaterError.installFailed("Cannot create staging directory: \(error.localizedDescription)")
        }
        do {
            try Self.securePrivateDirectory(directory, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return directory
    }

    /// Ensures `directory` is a real directory (not a symlink) owned by the current user
    /// with mode 0700, tightening the mode when needed.
    static func securePrivateDirectory(_ directory: URL, fileManager: FileManager = .default) throws {
        var info = stat()
        let status = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &info)
        }
        guard status == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw UpdaterError.installFailed("\(directory.lastPathComponent) is not a private directory")
        }
        guard info.st_uid == geteuid() else {
            throw UpdaterError.installFailed("\(directory.lastPathComponent) is owned by another user")
        }
        if info.st_mode & 0o077 != 0 {
            do {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            } catch {
                throw UpdaterError.installFailed("Cannot restrict \(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Swaps the bundle atomically, then runs `verifyInstalled` on the bundle now at `targetURL`.
    /// When that verification fails the previous bundle is swapped back and the error rethrown.
    /// A missing target is simply created (and removed again if verification fails).
    func replace(
        _ targetURL: URL,
        with stagedApp: URL,
        verifyingInstalled verifyInstalled: @Sendable (URL) async throws -> Void
    ) async throws {
        guard fileManager.fileExists(atPath: targetURL.path) else {
            try move(stagedApp, to: targetURL)
            do {
                try await verifyInstalled(targetURL)
            } catch {
                try? fileManager.removeItem(at: targetURL)
                throw error
            }
            return
        }
        let backupName = targetURL.deletingPathExtension().lastPathComponent + "-AppUpdaterBackup.app"
        let previous = targetURL.deletingLastPathComponent().appendingPathComponent(backupName)
        try? fileManager.removeItem(at: previous)
        try swap(targetURL, with: stagedApp, previous: previous)
        do {
            try await verifyInstalled(targetURL)
        } catch {
            rollBack(targetURL, from: previous)
            throw error
        }
        await discard(previous)
    }

    /// `replaceItemAt` first. A root-owned bundle (installed from a .pkg, e.g. AlDente) cannot be
    /// moved to another folder by the user, but /Applications is admin-writable, so it can be
    /// renamed in place: old → `previous` (same folder), staged → target. No admin prompt is
    /// needed, and macOS App Management forbids changing the bundle's contents even as root.
    private func swap(_ targetURL: URL, with stagedApp: URL, previous: URL) throws {
        do {
            _ = try fileManager.replaceItemAt(
                targetURL, withItemAt: stagedApp,
                backupItemName: previous.lastPathComponent, options: .withoutDeletingBackupItem
            )
            return
        } catch where Self.isPermissionDenied(error) {
            Self.logger.notice("\(targetURL.lastPathComponent, privacy: .public) is not movable; renaming in place")
        } catch {
            throw UpdaterError.installFailed("Could not replace \(targetURL.path): \(error.localizedDescription)")
        }
        do {
            try fileManager.moveItem(at: targetURL, to: previous)
        } catch {
            throw UpdaterError.installFailed("Could not replace \(targetURL.path): \(error.localizedDescription)")
        }
        do {
            try fileManager.moveItem(at: stagedApp, to: targetURL)
        } catch {
            try? fileManager.moveItem(at: previous, to: targetURL)
            throw UpdaterError.installFailed("Could not replace \(targetURL.path): \(error.localizedDescription)")
        }
    }

    /// Deletes the replaced bundle. A root-owned one cannot be deleted by the user: it goes to
    /// the Trash through the Finder when possible, otherwise it is hidden next to the app.
    private func discard(_ previous: URL) async {
        guard fileManager.fileExists(atPath: previous.path) else { return }
        if (try? fileManager.removeItem(at: previous)) != nil { return }
        do {
            try await recycler(previous)
            return
        } catch {
            Self.logger.notice("Could not trash \(previous.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        let hidden = previous.deletingLastPathComponent().appendingPathComponent("." + previous.lastPathComponent)
        try? fileManager.removeItem(at: hidden)
        do {
            try fileManager.moveItem(at: previous, to: hidden)
        } catch {
            Self.logger.error("Left \(previous.path, privacy: .public) behind: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func isPermissionDenied(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(nsError.code) { return true }
        return (nsError.userInfo[NSUnderlyingErrorKey] as? any Error).map(isPermissionDenied) ?? false
    }

    private func move(_ source: URL, to destination: URL) throws {
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            throw UpdaterError.installFailed("Could not install \(destination.path): \(error.localizedDescription)")
        }
    }

    private func rollBack(_ targetURL: URL, from previous: URL) {
        guard fileManager.fileExists(atPath: previous.path) else {
            Self.logger.fault("No previous bundle to roll back to for \(targetURL.lastPathComponent, privacy: .public)")
            return
        }
        do {
            if (try? fileManager.replaceItemAt(targetURL, withItemAt: previous)) == nil {
                // Root-owned previous bundle: drop the (user-owned) new one, rename the old back.
                try fileManager.removeItem(at: targetURL)
                try fileManager.moveItem(at: previous, to: targetURL)
            }
            Self.logger.error("Installed bundle failed verification; rolled back \(targetURL.lastPathComponent, privacy: .public)")
        } catch {
            Self.logger.fault(
                "Rollback of \(targetURL.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
