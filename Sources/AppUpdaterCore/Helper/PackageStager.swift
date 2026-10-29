import Darwin
import Foundation

/// Copies a package from a caller-supplied descriptor into a private staging directory
/// owned by the running user (root in the helper) with mode 0700.
///
/// The caller can no longer modify the copy, so the signature checked on it is the
/// signature of the bytes `installer` receives.
public struct PackageStager: Sendable {
    /// Fixed name: no caller-controlled path components reach the staging directory.
    public static let stagedFileName = "package.pkg"
    /// Flat packages are xar archives.
    static let xarMagic: [UInt8] = Array("xar!".utf8)
    private static let chunkSize = 1 << 20

    private let parentDirectory: URL

    public init(parentDirectory: URL = FileManager.default.temporaryDirectory) {
        self.parentDirectory = parentDirectory
    }

    /// Atomically creates a fresh 0700 directory (`mkdtemp`) and verifies it is ours.
    public func makeStagingDirectory() throws(HelperInstallRequestError) -> URL {
        var template = Array(
            parentDirectory.appendingPathComponent("\(HelperConstants.machServiceName).XXXXXXXX").path.utf8CString
        )
        let created: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let path = created else { throw .stagingFailed("mkdtemp failed (errno \(errno))") }
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o700 else {
            throw .stagingFailed("staging directory has unexpected ownership or mode")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Copies exactly `expectedSize` bytes from `source` (read with `pread`, independent
    /// of the shared file offset) into `directory/package.pkg`, then `fsync`s it.
    public func copy(
        from source: Int32,
        expectedSize: UInt64,
        into directory: URL
    ) throws(HelperInstallRequestError) -> URL {
        let destination = directory.appendingPathComponent(Self.stagedFileName)
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw .stagingFailed("cannot create staged file (errno \(errno))") }
        defer { close(output) }

        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        var offset: UInt64 = 0
        while offset < expectedSize {
            let wanted = Int(min(UInt64(Self.chunkSize), expectedSize - offset))
            let count = try Self.read(source, into: &buffer, count: wanted, at: offset)
            guard count > 0 else { throw .sizeChanged }
            if offset == 0, !buffer.starts(with: Self.xarMagic) { throw .notFlatPackage }
            try Self.writeAll(output, buffer, count: count)
            offset += UInt64(count)
        }
        // The file must end where fstat said it ends (it was not grown during the copy).
        guard try Self.read(source, into: &buffer, count: 1, at: offset) == 0 else { throw .sizeChanged }
        guard fsync(output) == 0 else { throw .stagingFailed("fsync failed (errno \(errno))") }
        return destination
    }

    private static func read(
        _ fd: Int32, into buffer: inout [UInt8], count: Int, at offset: UInt64
    ) throws(HelperInstallRequestError) -> Int {
        while true {
            let result = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
            if result >= 0 { return result }
            if errno != EINTR { throw .unreadableDescriptor(errno: errno) }
        }
    }

    private static func writeAll(_ fd: Int32, _ buffer: [UInt8], count: Int) throws(HelperInstallRequestError) {
        var written = 0
        while written < count {
            let result = buffer.withUnsafeBytes { write(fd, $0.baseAddress! + written, count - written) }
            if result < 0 {
                if errno == EINTR { continue }
                throw .stagingFailed("write failed (errno \(errno))")
            }
            written += result
        }
    }
}
