import Darwin
import Foundation

/// App-side helpers for handing a verified package to the privileged helper as an
/// open descriptor instead of a path.
enum PackageFileHandle {
    /// Opens `url` read-only without following a final symlink; the file must be regular.
    static func openForReading(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw UpdaterError.installFailed("Cannot open package \(url.lastPathComponent) (errno \(errno))")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw UpdaterError.installFailed("Package \(url.lastPathComponent) is not a regular file")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// True while `url` still names the inode behind `handle` (it was not swapped).
    static func refersToSameFile(_ handle: FileHandle, as url: URL) -> Bool {
        var opened = stat()
        var current = stat()
        guard fstat(handle.fileDescriptor, &opened) == 0, lstat(url.path, &current) == 0 else { return false }
        return opened.st_dev == current.st_dev && opened.st_ino == current.st_ino
    }
}
