import Foundation

/// Zip-bomb / disk-full guard run before `ditto -x -k` (L-3).
///
/// `/usr/bin/unzip -Zt` prints the archive's declared totals from the central directory
/// without extracting anything, e.g. `17 files, 3795 bytes uncompressed, 1428 bytes compressed:  62.4%`.
/// The declared uncompressed size must stay below `maxUncompressedBytes` and fit in the free
/// space of the staging volume (plus `freeSpaceMargin`). An unreadable listing fails closed.
struct ArchiveCapacityCheck: Sendable {
    struct Summary: Sendable, Equatable {
        let fileCount: Int
        let uncompressedBytes: Int64
    }

    static let unzip = "/usr/bin/unzip"
    static let defaultMaxUncompressedBytes: Int64 = 32 << 30
    static let defaultMaxEntries = 1_000_000
    static let defaultFreeSpaceMargin: Int64 = 512 << 20

    let commandRunner: any CommandRunner
    var maxUncompressedBytes: Int64 = Self.defaultMaxUncompressedBytes
    var maxEntries: Int = Self.defaultMaxEntries
    var freeSpaceMargin: Int64 = Self.defaultFreeSpaceMargin
    /// Free bytes on the volume holding the URL; nil when unknown (the free-space check is skipped).
    var availableCapacity: @Sendable (URL) -> Int64? = ArchiveCapacityCheck.volumeAvailableCapacity

    func check(_ archiveURL: URL, extractingInto directory: URL) async throws {
        let output: String
        do {
            output = try await commandRunner.run(Self.unzip, arguments: ["-Zt", archiveURL.path])
        } catch {
            throw UpdaterError.installFailed("Cannot read zip archive \(archiveURL.lastPathComponent)")
        }
        guard let summary = Self.parse(output) else {
            throw UpdaterError.installFailed("Cannot determine the size of zip archive \(archiveURL.lastPathComponent)")
        }
        try validate(summary, extractingInto: directory)
    }

    func validate(_ summary: Summary, extractingInto directory: URL) throws {
        guard summary.fileCount <= maxEntries else {
            throw UpdaterError.installFailed("Zip archive has too many entries (\(summary.fileCount))")
        }
        guard summary.uncompressedBytes <= maxUncompressedBytes else {
            throw UpdaterError.installFailed("Zip archive expands to \(Self.format(summary.uncompressedBytes)), over the limit")
        }
        if let available = availableCapacity(directory),
           summary.uncompressedBytes > available - freeSpaceMargin {
            throw UpdaterError.installFailed(
                "Not enough free space to extract the update (needs \(Self.format(summary.uncompressedBytes)))"
            )
        }
    }

    /// Parses the last summary line of `unzip -Zt`. Nil when it is missing or malformed.
    static func parse(_ output: String) -> Summary? {
        let line = output.split(whereSeparator: \.isNewline).last { $0.contains("bytes uncompressed") }
        guard let line else { return nil }
        let words = line.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        guard let filesIndex = words.firstIndex(where: { $0 == "files" || $0 == "file" }), filesIndex > 0,
              let count = Int(words[filesIndex - 1]),
              let bytesIndex = words.indices.first(where: {
                  words[$0] == "bytes" && words.indices.contains($0 + 1) && words[$0 + 1] == "uncompressed"
              }), bytesIndex > 0,
              let bytes = Int64(words[bytesIndex - 1]), count >= 0, bytes >= 0
        else { return nil }
        return Summary(fileCount: count, uncompressedBytes: bytes)
    }

    static func volumeAvailableCapacity(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
