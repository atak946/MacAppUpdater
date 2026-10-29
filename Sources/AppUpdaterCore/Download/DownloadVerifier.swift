import CryptoKit
import Foundation
import os

/// Shared post-download pipeline used by every downloader:
/// HTTPS check, relocation into a private (0700) directory, quarantine (M-4),
/// SHA-256 and EdDSA verification.
///
/// On any verification failure the relocated file (and its directory) is deleted
/// before the error is rethrown, so a rejected download never lingers on disk.
struct DownloadVerifier: Sendable {

    static let directoryPrefix = "AppUpdater-"

    private static let logger = Logger(subsystem: "com.macappupdater", category: "DownloadVerifier")
    private static let hashChunkSize = 1 << 20

    let publicEDKey: PublicKeyLookup

    init(publicEDKey: @escaping PublicKeyLookup = { _ in nil }) {
        self.publicEDKey = publicEDKey
    }

    /// Throws unless the update's download URL uses HTTPS.
    static func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw UpdaterError.network("Refusing non-HTTPS download URL: \(url.absoluteString)")
        }
    }

    /// Moves `temporaryURL` into its own directory with a meaningful name and verifies it.
    /// `expected` defaults to the update's `sha256` field. Returns the final file location.
    func finalize(
        _ temporaryURL: URL,
        for update: AvailableUpdate,
        expected: ExpectedChecksum? = nil
    ) throws -> URL {
        let fileURL = try relocate(temporaryURL, named: Self.fileName(for: update))
        do {
            try Quarantine.apply(to: fileURL)
            try verify(fileURL, for: update, expected: expected ?? ExpectedChecksum(sha256Of: update))
        } catch {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            throw error
        }
        return fileURL
    }

    // MARK: - File placement

    private func relocate(_ source: URL, named name: String) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("\(Self.directoryPrefix)\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let destination = directory.appendingPathComponent(name)
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }

    static func fileName(for update: AvailableUpdate) -> String {
        let candidate = update.downloadURL.lastPathComponent
        let isUsable = !candidate.isEmpty && candidate != "/" && !candidate.hasPrefix(".")
        return isUsable ? candidate : "\(update.app.name)-\(update.newVersion)"
    }

    // MARK: - Verification

    func verify(_ fileURL: URL, for update: AvailableUpdate, expected: ExpectedChecksum? = nil) throws {
        if let expected = expected ?? ExpectedChecksum(sha256Of: update) {
            let actual = try Self.digest(of: fileURL, algorithm: expected.algorithm)
            guard expected.matches(actual) else {
                Self.logger.error(
                    "\(expected.algorithm.rawValue, privacy: .public) mismatch for \(update.id, privacy: .public)"
                )
                throw UpdaterError.checksumMismatch
            }
        }
        try verifyEdSignatureIfRequired(fileURL, for: update)
    }

    /// M-1: when the installed app ships `SUPublicEDKey`, a Sparkle update must carry a valid
    /// EdDSA signature (fail closed, like Sparkle itself). Other sources are verified when they
    /// happen to provide a signature.
    private func verifyEdSignatureIfRequired(_ fileURL: URL, for update: AvailableUpdate) throws {
        let key = publicEDKey(update.app)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { return }
        let signature = update.edSignature?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature, !signature.isEmpty else {
            guard update.source != .sparkle else {
                Self.logger.error("Missing EdDSA signature for \(update.id, privacy: .public)")
                throw UpdaterError.signatureInvalid("Missing EdDSA signature (the app ships SUPublicEDKey)")
            }
            return
        }
        try Self.verifyEdSignature(signature, publicKey: key, fileURL: fileURL)
    }

    static func sha256Hex(of fileURL: URL) throws -> String {
        try digest(of: fileURL, algorithm: .sha256).map { String(format: "%02x", $0) }.joined()
    }

    /// Raw digest bytes of the file, hashed in chunks.
    static func digest(of fileURL: URL, algorithm: ExpectedChecksum.Algorithm) throws -> Data {
        switch algorithm {
        case .sha256: try digest(of: fileURL, using: SHA256())
        case .sha512: try digest(of: fileURL, using: SHA512())
        }
    }

    private static func digest<H: HashFunction>(of fileURL: URL, using initial: H) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = initial
        while let chunk = try handle.read(upToCount: hashChunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    static func verifyEdSignature(_ signature: String, publicKey: String, fileURL: URL) throws {
        guard let keyData = Data(base64Encoded: publicKey),
              let signatureData = Data(base64Encoded: signature) else {
            throw UpdaterError.signatureInvalid("Malformed EdDSA key or signature")
        }
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        } catch {
            throw UpdaterError.signatureInvalid("Invalid SUPublicEDKey")
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard key.isValidSignature(signatureData, for: data) else {
            throw UpdaterError.signatureInvalid("EdDSA signature does not match download")
        }
    }
}

// MARK: - Expected checksums

/// A digest the downloaded file must match. `value` may be hex or base64 (electron-builder `sha512`).
public struct ExpectedChecksum: Sendable, Hashable {
    public enum Algorithm: String, Sendable, Hashable, CaseIterable {
        case sha256
        case sha512

        var byteCount: Int {
            switch self {
            case .sha256: 32
            case .sha512: 64
            }
        }
    }

    public let algorithm: Algorithm
    public let value: String

    public init(algorithm: Algorithm, value: String) {
        self.algorithm = algorithm
        self.value = value
    }

    /// The update's own `sha256` field (Homebrew casks), if any.
    public init?(sha256Of update: AvailableUpdate) {
        guard let sha256 = update.sha256 else { return nil }
        self.init(algorithm: .sha256, value: sha256)
    }

    /// Decoded expected digest: hex of the right length first, then base64. Nil when malformed.
    public var digestBytes: Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == algorithm.byteCount * 2, let bytes = Self.hexBytes(trimmed) { return bytes }
        guard let bytes = Data(base64Encoded: trimmed), bytes.count == algorithm.byteCount else { return nil }
        return bytes
    }

    /// A malformed expected value never matches, so the download is rejected.
    func matches(_ digest: Data) -> Bool {
        guard let expected = digestBytes else { return false }
        return expected == digest
    }

    private static func hexBytes(_ hex: String) -> Data? {
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// Resolves the checksum a download must match. Default: `ExpectedChecksum.updateSHA256`.
/// Returns an app's Sparkle EdDSA public key (`SUPublicEDKey`, base64), or nil when it ships none.
public typealias PublicKeyLookup = @Sendable (InstalledApp) -> String?

public typealias ChecksumLookup = @Sendable (AvailableUpdate) async -> ExpectedChecksum?

extension ExpectedChecksum {
    /// Reads only `AvailableUpdate.sha256` (pre-SHA-512 behaviour).
    public static let updateSHA256: ChecksumLookup = { update in ExpectedChecksum(sha256Of: update) }
}

/// Digests that do not fit `AvailableUpdate` (e.g. electron-builder SHA-512), keyed by `AvailableUpdate.id`.
/// Share one instance between the sources that register digests and the downloaders that verify them.
public actor ChecksumStore {
    private var entries: [String: ExpectedChecksum] = [:]

    public init() {}

    public func register(_ checksum: ExpectedChecksum, forUpdateID id: String) {
        entries[id] = checksum
    }

    public func checksum(forUpdateID id: String) -> ExpectedChecksum? {
        entries[id]
    }

    public func removeChecksum(forUpdateID id: String) {
        entries[id] = nil
    }

    /// Registered digest first, then the update's `sha256` field.
    public nonisolated var lookup: ChecksumLookup {
        { [self] update in
            await checksum(forUpdateID: update.id) ?? ExpectedChecksum(sha256Of: update)
        }
    }
}
