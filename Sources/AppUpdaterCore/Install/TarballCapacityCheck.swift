import Foundation

/// Tar-bomb / disk-full / path guard run before extracting a tarball with bsdtar (L-3).
///
/// `tar -tvf` lists every entry without writing anything (it decompresses the stream to read
/// the headers). The summed entry sizes go through the same limits as zip archives
/// (`ArchiveCapacityCheck.validate`), and any absolute or `..` path is refused outright even
/// though bsdtar would also strip or skip it. An unreadable listing fails closed.
struct TarballCapacityCheck: Sendable {
    let commandRunner: any CommandRunner
    var limits: ArchiveCapacityCheck

    init(commandRunner: any CommandRunner) {
        self.commandRunner = commandRunner
        self.limits = ArchiveCapacityCheck(commandRunner: commandRunner)
    }

    func check(_ archiveURL: URL, extractingInto directory: URL) async throws {
        let output: String
        do {
            output = try await commandRunner.run(SystemTool.tar, arguments: ["-tvf", archiveURL.path])
        } catch {
            throw UpdaterError.installFailed("Cannot read archive \(archiveURL.lastPathComponent)")
        }
        let summary = try Self.parse(output)
        try limits.validate(summary, extractingInto: directory)
    }

    /// Sums the size column of a bsdtar verbose listing
    /// (`-rw-r--r--  0 user staff  1234 Jan  1  2024 App.app/Contents/Info.plist`).
    static func parse(_ output: String) throws -> ArchiveCapacityCheck.Summary {
        var count = 0
        var bytes: Int64 = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 9, let size = Int64(fields[4]), size >= 0 else {
                throw UpdaterError.installFailed("Cannot determine the size of the archive")
            }
            let path = fields[8...].joined(separator: " ").components(separatedBy: " -> ")[0]
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw UpdaterError.installFailed("Archive contains an unsafe path: \(path)")
            }
            count += 1
            let (sum, overflow) = bytes.addingReportingOverflow(size)
            guard !overflow else { throw UpdaterError.installFailed("Archive is too large") }
            bytes = sum
        }
        guard count > 0 else { throw UpdaterError.installFailed("The archive is empty") }
        return ArchiveCapacityCheck.Summary(fileCount: count, uncompressedBytes: bytes)
    }
}
