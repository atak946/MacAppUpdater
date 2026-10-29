import Darwin
import Foundation

/// Reasons the helper refuses an install request.
public enum HelperInstallRequestError: Error, Sendable, Equatable, LocalizedError {
    case invalidTeamIdentifier
    case unreadableDescriptor(errno: Int32)
    case notRegularFile
    case ownerMismatch(expected: uid_t, actual: uid_t)
    case multipleLinks(Int)
    case empty
    case tooLarge(size: UInt64, limit: UInt64)
    case notFlatPackage
    case sizeChanged
    case stagingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTeamIdentifier: "Expected Team ID is missing or malformed"
        case .unreadableDescriptor(let code): "Cannot read package descriptor (errno \(code))"
        case .notRegularFile: "Not a regular file (only flat packages are supported)"
        case .ownerMismatch(let expected, let actual): "File owned by uid \(actual), expected \(expected)"
        case .multipleLinks(let count): "Refusing file with \(count) hard links"
        case .empty: "Package file is empty"
        case .tooLarge(let size, let limit): "Package is too large (\(size) bytes, limit \(limit))"
        case .notFlatPackage: "File is not a flat installer package"
        case .sizeChanged: "Package changed while it was being copied"
        case .stagingFailed(let message): "Could not stage package: \(message)"
        }
    }
}

/// Validates an install request received over XPC before the helper touches it as root.
///
/// The request carries an open file descriptor, not a path, so there is nothing to
/// canonicalize and no path/symlink TOCTOU: the checks run on the inode behind the fd
/// (`fstat`) and the helper copies from that same fd.
public struct HelperInstallRequestValidator: Sendable {
    /// Upper bound for a package copied into root-owned staging (4 GiB).
    public static let defaultMaxPackageBytes: UInt64 = 4 << 30

    public let maxPackageBytes: UInt64

    public init(maxPackageBytes: UInt64 = HelperInstallRequestValidator.defaultMaxPackageBytes) {
        self.maxPackageBytes = maxPackageBytes
    }

    /// The Team ID is interpolated into nothing, but must still be well formed.
    public func validate(expectedTeamID: String) throws(HelperInstallRequestError) {
        guard HelperCodeSigning.isValidTeamIdentifier(expectedTeamID) else { throw .invalidTeamIdentifier }
    }

    /// Returns the file size when the descriptor refers to an acceptable package file:
    /// a regular, non-empty, single-link file owned by the caller and within the size limit.
    public func validate(fileDescriptor: Int32, callerUID: uid_t) throws(HelperInstallRequestError) -> UInt64 {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else { throw .unreadableDescriptor(errno: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegularFile }
        guard info.st_uid == callerUID else { throw .ownerMismatch(expected: callerUID, actual: info.st_uid) }
        guard info.st_nlink == 1 else { throw .multipleLinks(Int(info.st_nlink)) }
        guard info.st_size > 0 else { throw .empty }
        let size = UInt64(info.st_size)
        guard size <= maxPackageBytes else { throw .tooLarge(size: size, limit: maxPackageBytes) }
        return size
    }
}
