import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("PackageSniffer")
struct PackageSnifferTests {
    private func file(named name: String, bytes: Data) throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SnifferTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        return (folder, url)
    }

    private static let zip = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 600)
    private static let xar = Data("xar!".utf8) + Data(repeating: 0, count: 600)
    private static let dmg: Data = {
        var trailer = Data("koly".utf8)
        trailer.append(Data(repeating: 0, count: 508))
        return Data(repeating: 0xAB, count: 4096) + trailer
    }()

    @Test("detects zip, xar (pkg) and UDIF (dmg) by their bytes", arguments: [
        (zip, PackageFormat.zip), (xar, .pkg), (dmg, .dmg),
        (Data("<html>not a package</html>".utf8), .unknown), (Data(), .unknown),
    ])
    func detects(bytes: Data, expected: PackageFormat) throws {
        let (folder, url) = try file(named: "download", bytes: bytes)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(PackageSniffer.detect(url) == expected)
    }

    @Test("an extension-less download gets its detected extension")
    func labelsExtensionlessFile() throws {
        let (folder, url) = try file(named: "download", bytes: Self.dmg)
        defer { try? FileManager.default.removeItem(at: folder) }
        let labelled = try PackageSniffer.labelling(url)
        #expect(labelled.lastPathComponent == "download.dmg")
        #expect(PackageFormat(fileURL: labelled) == .dmg)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("unrecognised bytes and already-typed names are left alone")
    func leavesOthersAlone() throws {
        let (folder, html) = try file(named: "get.php", bytes: Data("<html>".utf8))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try PackageSniffer.labelling(html) == html)

        let typed = folder.appendingPathComponent("App.zip")
        try Self.dmg.write(to: typed)
        #expect(try PackageSniffer.labelling(typed) == typed)
    }
}
