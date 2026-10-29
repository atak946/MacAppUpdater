import Darwin
import Foundation
import Testing
@testable import AppUpdaterCore

/// Temp directory with helpers to create files and open read-only descriptors.
final class HelperTestDirectory {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeFile(_ name: String, contents: Data = Data("xar!payload".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    func openHandle(_ url: URL) throws -> FileHandle {
        try FileHandle(forReadingFrom: url)
    }
}

@Suite("HelperInstallRequestValidator")
struct HelperInstallRequestValidatorTests {
    private let directory: HelperTestDirectory
    private let validator = HelperInstallRequestValidator()
    private let uid = getuid()

    init() throws {
        directory = try HelperTestDirectory()
    }

    @Test("accepts a regular caller-owned file and returns its size")
    func acceptsValidPackage() throws {
        let handle = try directory.openHandle(directory.makeFile("Update.pkg"))
        #expect(try validator.validate(fileDescriptor: handle.fileDescriptor, callerUID: uid) == 11)
    }

    @Test("rejects files owned by another user")
    func rejectsOwner() throws {
        let handle = try directory.openHandle(directory.makeFile("Update.pkg"))
        #expect(throws: HelperInstallRequestError.ownerMismatch(expected: uid + 1, actual: uid)) {
            try validator.validate(fileDescriptor: handle.fileDescriptor, callerUID: uid + 1)
        }
    }

    @Test("rejects directories (bundle packages)")
    func rejectsDirectory() throws {
        let bundle = directory.root.appendingPathComponent("Bundle.pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let descriptor = open(bundle.path, O_RDONLY)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(throws: HelperInstallRequestError.notRegularFile) {
            try validator.validate(fileDescriptor: descriptor, callerUID: uid)
        }
    }

    @Test("rejects hard-linked files")
    func rejectsHardLink() throws {
        let file = try directory.makeFile("Update.pkg")
        try FileManager.default.linkItem(at: file, to: directory.root.appendingPathComponent("Other.pkg"))
        let handle = try directory.openHandle(file)
        #expect(throws: HelperInstallRequestError.multipleLinks(2)) {
            try validator.validate(fileDescriptor: handle.fileDescriptor, callerUID: uid)
        }
    }

    @Test("rejects empty and oversized files")
    func rejectsSize() throws {
        let empty = try directory.openHandle(directory.makeFile("Empty.pkg", contents: Data()))
        #expect(throws: HelperInstallRequestError.empty) {
            try validator.validate(fileDescriptor: empty.fileDescriptor, callerUID: uid)
        }
        let small = HelperInstallRequestValidator(maxPackageBytes: 4)
        let handle = try directory.openHandle(directory.makeFile("Big.pkg"))
        #expect(throws: HelperInstallRequestError.tooLarge(size: 11, limit: 4)) {
            try small.validate(fileDescriptor: handle.fileDescriptor, callerUID: uid)
        }
    }

    @Test("rejects closed descriptors")
    func rejectsBadDescriptor() {
        #expect(throws: HelperInstallRequestError.self) {
            try validator.validate(fileDescriptor: -1, callerUID: uid)
        }
    }

    @Test("default limit is 4 GiB")
    func defaultLimit() {
        #expect(HelperInstallRequestValidator.defaultMaxPackageBytes == 4 * 1024 * 1024 * 1024)
    }

    @Test("every HelperInstallRequestError has a readable description", arguments: [
        (HelperInstallRequestError.invalidTeamIdentifier, "Expected Team ID is missing or malformed"),
        (.notRegularFile, "Not a regular file (only flat packages are supported)"),
        (.ownerMismatch(expected: 501, actual: 0), "File owned by uid 0, expected 501"),
        (.multipleLinks(2), "Refusing file with 2 hard links"),
        (.empty, "Package file is empty"),
        (.tooLarge(size: 9, limit: 4), "Package is too large (9 bytes, limit 4)"),
        (.notFlatPackage, "File is not a flat installer package"),
        (.sizeChanged, "Package changed while it was being copied"),
        (.stagingFailed("x"), "Could not stage package: x"),
    ])
    func errorDescriptions(error: HelperInstallRequestError, expected: String) {
        #expect(error.localizedDescription == expected)
    }

    @Test("validates expected team id format", arguments: ["", "abcde12345", "ABCDE1234", "ABCDE12345\""])
    func rejectsMalformedTeam(team: String) {
        #expect(throws: HelperInstallRequestError.invalidTeamIdentifier) {
            try validator.validate(expectedTeamID: team)
        }
    }
}

@Suite("PackageStager")
struct PackageStagerTests {
    private let directory: HelperTestDirectory
    private let stager: PackageStager

    init() throws {
        directory = try HelperTestDirectory()
        stager = PackageStager(parentDirectory: directory.root)
    }

    @Test("creates a private 0700 staging directory")
    func stagingDirectoryIsPrivate() throws {
        let staging = try stager.makeStagingDirectory()
        let attributes = try FileManager.default.attributesOfItem(atPath: staging.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        #expect((attributes[.ownerAccountID] as? Int).map { uid_t($0) } == geteuid())
    }

    @Test("copies exactly the bytes behind the descriptor, ignoring the shared offset")
    func copiesExactBytes() throws {
        var bytes = Data("xar!".utf8)
        bytes.append(Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        let source = try directory.makeFile("Big.pkg", contents: bytes)
        let handle = try directory.openHandle(source)
        try handle.seek(toOffset: 1234)

        let staged = try stager.copy(
            from: handle.fileDescriptor, expectedSize: UInt64(bytes.count), into: stager.makeStagingDirectory()
        )

        #expect(staged.lastPathComponent == PackageStager.stagedFileName)
        #expect(try Data(contentsOf: staged) == bytes)
        let mode = try FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("rejects files that are not xar archives")
    func rejectsNonXar() throws {
        let handle = try directory.openHandle(directory.makeFile("Evil.pkg", contents: Data("#!/bin/sh".utf8)))
        #expect(throws: HelperInstallRequestError.notFlatPackage) {
            try stager.copy(from: handle.fileDescriptor, expectedSize: 9, into: stager.makeStagingDirectory())
        }
    }

    @Test("rejects files that grew or shrank after fstat")
    func rejectsSizeChange() throws {
        let handle = try directory.openHandle(directory.makeFile("Update.pkg"))
        #expect(throws: HelperInstallRequestError.sizeChanged) {
            try stager.copy(from: handle.fileDescriptor, expectedSize: 5, into: stager.makeStagingDirectory())
        }
        #expect(throws: HelperInstallRequestError.sizeChanged) {
            try stager.copy(from: handle.fileDescriptor, expectedSize: 50, into: stager.makeStagingDirectory())
        }
    }
}
