import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("RegistrableDomain")
struct RegistrableDomainTests {
    @Test("normalizes hosts", arguments: [
        ("WWW.Example.COM", "example.com"),
        ("downloads.example.com.", "downloads.example.com"),
        ("www.", nil),
        ("", nil),
    ] as [(String, String?)])
    func normalize(host: String, expected: String?) {
        #expect(RegistrableDomain.normalizedHost(host) == expected)
    }

    @Test("registrable domain heuristic", arguments: [
        ("example.com", "example.com"),
        ("dl.cdn.example.com", "example.com"),
        ("downloads.example.co.uk", "example.co.uk"),
        ("example.co.uk", "example.co.uk"),
        ("files.vendor.com.au", "vendor.com.au"),
        ("192.168.1.10", "192.168.1.10"),
        ("localhost", "localhost"),
    ])
    func registrable(host: String, expected: String) {
        #expect(RegistrableDomain.registrableDomain(of: host) == expected)
    }

    @Test("GitHub CDN hosts share a family")
    func githubFamily() {
        let hosts = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]
        #expect(Set(hosts.map(RegistrableDomain.familyKey)) == ["github"])
    }

    @Test("user-content githubusercontent.com hosts are not the github family", arguments: [
        "raw.githubusercontent.com", "gist.githubusercontent.com", "user-images.githubusercontent.com",
    ])
    func githubUserContentIsNotGitHub(host: String) {
        #expect(RegistrableDomain.familyKey(of: host) == host)
        #expect(RegistrableDomain.familyKey(of: host) != RegistrableDomain.familyKey(of: "github.com"))
        #expect(RegistrableDomain.familyKey(of: host) != RegistrableDomain.familyKey(of: "release-assets.githubusercontent.com"))
    }

    @Test("GitHub Pages hosts are user-controlled: never the github family, one site per user")
    func githubPagesIsNotGitHub() {
        #expect(RegistrableDomain.familyKey(of: "evil.github.io") == "evil.github.io")
        #expect(RegistrableDomain.familyKey(of: "evil.github.io") != RegistrableDomain.familyKey(of: "github.com"))
        #expect(RegistrableDomain.familyKey(of: "alice.github.io") != RegistrableDomain.familyKey(of: "bob.github.io"))
    }
}

@Suite("DownloadHostStore")
struct DownloadHostStoreTests {
    private static let bundleID = "com.example.hosts"
    private let suiteName = "DownloadHostStoreTests-\(UUID().uuidString)"

    private func withStore(_ body: (UserDefaultsDownloadHostStore, UserDefaults) throws -> Void) throws {
        let defaults = try #require(TestDefaults.suite(named: suiteName))
        defaults.removePersistentDomain(forName: TestDefaults.prefix + suiteName)
        defer { defaults.removePersistentDomain(forName: TestDefaults.prefix + suiteName) }
        try body(UserDefaultsDownloadHostStore(defaults: defaults), defaults)
    }

    private func update(_ url: String, bundleID: String = Self.bundleID) -> AvailableUpdate {
        let app = InstalledApp(
            bundleIdentifier: bundleID, name: "Foo", url: URL(fileURLWithPath: "/Applications/Foo.app"),
            shortVersion: "1.0", buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: false
        )
        return AvailableUpdate(app: app, newVersion: "2.0", downloadURL: URL(string: url)!, source: .sparkle)
    }

    @Test("no history means no change")
    func noHistory() throws {
        try withStore { store, _ in
            #expect(store.check(update("https://evil.xyz/Foo.zip")) == nil)
        }
    }

    @Test("records lowercased host without www")
    func recordsNormalized() throws {
        try withStore { store, _ in
            store.record(update("https://WWW.Example.com/Foo.zip"))
            #expect(store.lastKnownHost(for: Self.bundleID) == "example.com")
        }
    }

    @Test("subdomain changes within the same domain are not flagged")
    func subdomainOK() throws {
        try withStore { store, _ in
            store.record(update("https://downloads.example.com/Foo-1.zip"))
            #expect(store.check(update("https://cdn2.example.com/Foo-2.zip")) == nil)
            #expect(store.check(update("https://www.example.com/Foo-2.zip")) == nil)
        }
    }

    @Test("github.com to a GitHub Pages host is flagged")
    func githubPagesMoveIsFlagged() throws {
        try withStore { store, _ in
            store.record(update("https://github.com/o/r/releases/download/v1/Foo.zip"))
            let change = store.check(update("https://attacker.github.io/Foo.zip"))
            #expect(change?.current == "attacker.github.io")
        }
    }

    @Test("GitHub to its asset CDN is not flagged")
    func githubCDN() throws {
        try withStore { store, _ in
            store.record(update("https://github.com/o/r/releases/download/v1/Foo.zip"))
            #expect(store.check(update("https://objects.githubusercontent.com/x/Foo.zip")) == nil)
        }
    }

    @Test("a different registrable domain is flagged")
    func domainChangeFlagged() throws {
        try withStore { store, _ in
            store.record(update("https://github.com/o/r/releases/download/v1/Foo.zip"))
            let change = store.check(update("https://random-cdn.xyz/Foo.zip"))
            #expect(change == HostChange(bundleIdentifier: Self.bundleID, previous: "github.com", current: "random-cdn.xyz"))
        }
    }

    @Test("multi-part suffixes compare the full registrable domain")
    func multiPartSuffix() throws {
        try withStore { store, _ in
            store.record(update("https://dl.vendor.co.uk/Foo.zip"))
            #expect(store.check(update("https://cdn.vendor.co.uk/Foo.zip")) == nil)
            #expect(store.check(update("https://dl.other.co.uk/Foo.zip")) != nil)
        }
    }

    @Test("hosts are tracked per bundle and can be forgotten")
    func perBundleAndForget() throws {
        try withStore { store, defaults in
            store.record(update("https://a.com/x.zip"))
            store.record(update("https://b.com/x.zip", bundleID: "com.example.other"))
            #expect(store.lastKnownHost(for: Self.bundleID) == "a.com")
            store.forget(Self.bundleID)
            #expect(store.lastKnownHost(for: Self.bundleID) == nil)
            let reopened = UserDefaultsDownloadHostStore(defaults: defaults)
            #expect(reopened.lastKnownHost(for: "com.example.other") == "b.com")
        }
    }
}
