import Foundation

/// Abstraction over HTTP so sources and downloader are testable.
public protocol HTTPClient: Sendable {
    func data(from url: URL) async throws -> Data
}

/// Abstraction over running command-line tools (hdiutil, codesign, ditto, ...).
public protocol CommandRunner: Sendable {
    @discardableResult
    func run(_ executable: String, arguments: [String]) async throws -> String
}

public protocol AppScanning: Sendable {
    func scan() async throws -> [InstalledApp]
}

/// A provider that knows how to find updates for some subset of apps.
public protocol UpdateSource: Sendable {
    var kind: UpdateSourceKind { get }
    /// Whether this source is applicable to the given app.
    func canHandle(_ app: InstalledApp) -> Bool
    /// Returns an update if a newer version exists, otherwise nil.
    func checkForUpdate(_ app: InstalledApp) async throws -> AvailableUpdate?
}

public protocol VersionComparing: Sendable {
    /// Returns true when `candidate` is newer than `current`.
    func isNewer(_ candidate: String, than current: String) -> Bool
}

public protocol UpdateDownloading: Sendable {
    /// Downloads and verifies integrity (checksum when provided). Returns local file URL.
    func download(_ update: AvailableUpdate) async throws -> URL
}

public protocol SignatureVerifying: Sendable {
    /// Returns Team Identifier of a signed bundle, throws if signature is invalid.
    func teamIdentifier(of bundleURL: URL) async throws -> String
}

public protocol UpdateInstalling: Sendable {
    /// Installs the downloaded package, replacing `update.app`.
    func install(_ update: AvailableUpdate, from packageURL: URL) async throws
}
