import Foundation

/// Identifies a downloaded package by its bytes when the URL carries no usable extension
/// (redirect endpoints such as `…/download?platform=mac`, `…/latest`, `get.php`).
///
/// Only the install allowlist is recognised (security review H-1); everything else stays
/// `.unknown` and is never opened:
/// - zip: local file header `PK\u{3}\u{4}` at offset 0;
/// - pkg: xar archive magic `xar!` at offset 0;
/// - dmg: UDIF trailer `koly` in the last 512 bytes (checked before the compression magics);
/// - tarball: gzip `1F 8B`, bzip2 `BZh`, xz `FD 37 7A 58 5A 00`, or `ustar` at offset 257.
///   A compressed stream that is not a tar fails later, when bsdtar lists it.
enum PackageSniffer {
    private static let zipMagic = Data([0x50, 0x4B, 0x03, 0x04])
    private static let xarMagic = Data("xar!".utf8)
    private static let gzipMagic = Data([0x1F, 0x8B])
    private static let bzip2Magic = Data("BZh".utf8)
    private static let xzMagic = Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
    private static let ustarMagic = Data("ustar".utf8)
    private static let ustarOffset: UInt64 = 257
    private static let udifMagic = Data("koly".utf8)
    private static let udifTrailerSize: UInt64 = 512

    static func detect(_ fileURL: URL) -> PackageFormat {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return .unknown }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 6), head.count >= 4 else { return .unknown }
        if head.starts(with: zipMagic) { return .zip }
        if head.starts(with: xarMagic) { return .pkg }
        // Before the compression magics: a bzip2/xz-compressed disk image (UDBZ, ULMO) starts
        // with the same bytes as a compressed tarball; only its trailer tells them apart.
        if hasDiskImageTrailer(handle) { return .dmg }
        if head.starts(with: gzipMagic) || head.starts(with: bzip2Magic) || head.starts(with: xzMagic) { return .tarball }
        if (try? handle.seek(toOffset: ustarOffset)) != nil,
           let marker = try? handle.read(upToCount: 5), marker == ustarMagic {
            return .tarball
        }
        return .unknown
    }

    private static func hasDiskImageTrailer(_ handle: FileHandle) -> Bool {
        guard let size = try? handle.seekToEnd(), size >= udifTrailerSize,
              (try? handle.seek(toOffset: size - udifTrailerSize)) != nil,
              let trailer = try? handle.read(upToCount: 4)
        else { return false }
        return trailer == udifMagic
    }

    /// Gives an extension-less (or unknown-extension) download the extension of its detected
    /// format so every later `PackageFormat(fileURL:)` check sees the real type. Returns the
    /// file unchanged when the name already has a known format or the bytes match none.
    static func labelling(_ fileURL: URL, fileManager: FileManager = .default) throws -> URL {
        guard PackageFormat(fileURL: fileURL) == .unknown else { return fileURL }
        guard let label = detect(fileURL).labelExtension else { return fileURL }
        let labelled = fileURL.appendingPathExtension(label)
        try fileManager.moveItem(at: fileURL, to: labelled)
        return labelled
    }
}
