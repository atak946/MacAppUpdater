import Testing
import Foundation
@testable import AppUpdaterCore

@Suite struct LeftoverScannerTests {
    private let id = "com.foo.app"

    @Test func findsExactMatchesInAllowlistedFolders() async throws {
        try await UninstallSandbox.run { box in
            try box.make("Application Support/\(id)")
            try box.make("Caches/\(id)")
            try box.make("Preferences/\(id).plist", directory: false)
            try box.make("Preferences/ByHost/\(id).12345678-ABCD-ABCD-ABCD-1234567890AB.plist", directory: false)
            try box.make("Containers/\(id)")
            try box.make("Saved Application State/\(id).savedState")
            try box.make("Logs/\(id)")
            try box.make("HTTPStorages/\(id)")
            try box.make("WebKit/\(id)")
            try box.make("Cookies/\(id).binarycookies", directory: false)
            try box.makePlist("LaunchAgents/\(id).plist", ["Label": id])

            let items = box.scanner.scan(bundleIdentifier: id, appName: "Foo")

            #expect(items.count == 11)
            #expect(items.allSatisfy { $0.confidence == .exact })
            #expect(Set(items.map(\.kind)).count == 11)
            #expect(items.allSatisfy { $0.sizeInBytes > 0 })
        }
    }

    @Test func noSubstringOrPrefixFalsePositives() async throws {
        try await UninstallSandbox.run { box in
            try box.make("Application Support/com.foo.app2")
            try box.make("Application Support/com.foo")
            try box.make("Caches/com.foo.app.helper")
            try box.make("Caches/xcom.foo.app")
            try box.make("Preferences/com.foo.app2.plist", directory: false)
            try box.make("Preferences/ByHost/com.foo.app.helper.12345678-ABCD-ABCD-ABCD-1234567890AB.plist", directory: false)
            try box.make("Group Containers/group.com.foo.app")
            try box.make("Group Containers/ABCDE12345.com.foo.app2")
            try box.make("Containers/com.foo.app2")
            try box.make("Application Support/Foo Pro")

            let items = box.scanner.scan(bundleIdentifier: id, appName: "Foo")

            #expect(items.isEmpty)
        }
    }

    @Test func nameAndTeamGroupMatchesArePossibleOnly() async throws {
        try await UninstallSandbox.run { box in
            try box.make("Application Support/Foo")
            try box.make("Group Containers/ABCDE12345.\(id)")

            let items = box.scanner.scan(bundleIdentifier: id, appName: "Foo")

            #expect(items.count == 2)
            #expect(items.allSatisfy { $0.confidence == .possible })
        }
    }

    @Test func launchAgentRequiresExactLabel() async throws {
        try await UninstallSandbox.run { box in
            try box.makePlist("LaunchAgents/\(id).plist", ["Label": "com.foo.app.other"])
            try box.makePlist("LaunchAgents/\(id).helper.plist", ["Label": id])

            let items = box.scanner.scan(bundleIdentifier: id, appName: "Foo")

            #expect(items.map(\.url.lastPathComponent) == ["\(id).helper.plist"])
        }
    }

    @Test func ignoresFoldersOutsideAllowlist() async throws {
        try await UninstallSandbox.run { box in
            try box.make("Mail/\(id)")
            try box.make("Keychains/\(id)")
            try box.make("Caches/nested/\(id)")
            try FileManager.default.createDirectory(
                at: box.home.appendingPathComponent("Documents/\(id)"), withIntermediateDirectories: true
            )

            #expect(box.scanner.scan(bundleIdentifier: id, appName: "Foo").isEmpty)
        }
    }

    @Test func validateRejectsPathsOutsideAllowlist() async throws {
        try await UninstallSandbox.run { box in
            let mail = try box.make("Mail/\(id)")
            let traversal = box.library.appendingPathComponent("Caches/../Mail/\(id)")
            let wrongName = try box.make("Caches/com.foo.app2")

            for url in [mail, traversal, wrongName, box.outside] {
                #expect(throws: UninstallError.self) {
                    try box.scanner.validate(url, bundleIdentifier: id, appName: "Foo")
                }
            }
        }
    }

    @Test func rejectsSymlinkPointingOutside() async throws {
        try await UninstallSandbox.run { box in
            let target = box.outside.appendingPathComponent("precious")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let link = box.library.appendingPathComponent("Caches/\(id)")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            #expect(box.scanner.scan(bundleIdentifier: id, appName: "Foo").isEmpty)
            #expect(throws: UninstallError.symlinkEscape(link.standardizedFileURL)) {
                try box.scanner.validate(link, bundleIdentifier: id, appName: "Foo")
            }
        }
    }

    @Test func rejectsSymlinkedAllowlistFolderEscapingLibrary() async throws {
        try await UninstallSandbox.run { box in
            try FileManager.default.createDirectory(
                at: box.outside.appendingPathComponent(id), withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: box.library.appendingPathComponent("Logs"), withDestinationURL: box.outside
            )

            #expect(box.scanner.scan(bundleIdentifier: id, appName: "Foo").isEmpty)
        }
    }

    @Test(arguments: ["", "../evil", "a/b", ".hidden"])
    func unsafeBundleIdentifierScansNothing(badID: String) async throws {
        try await UninstallSandbox.run { box in
            try box.make("Caches/evil")
            #expect(box.scanner.scan(bundleIdentifier: badID, appName: "evil").isEmpty)
        }
    }
}
