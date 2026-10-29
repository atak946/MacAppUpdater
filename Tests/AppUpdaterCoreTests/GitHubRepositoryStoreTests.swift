import Foundation
import os
import Testing
@testable import AppUpdaterCore

/// In-memory `TokenStoring` so tests never touch the real Keychain.
final class InMemoryTokenStore: TokenStoring {
    private let token = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let failure: TokenStoreError?

    init(token initial: String? = nil, failure: TokenStoreError? = nil) {
        self.failure = failure
        token.withLock { $0 = initial }
    }

    func readToken() throws -> String? {
        if let failure { throw failure }
        return token.withLock { $0 }
    }

    func saveToken(_ value: String) throws {
        guard let sanitized = KeychainTokenStore.sanitized(value) else { throw TokenStoreError.invalidToken }
        token.withLock { $0 = sanitized }
    }

    func deleteToken() throws {
        token.withLock { $0 = nil }
    }
}

/// Fresh, isolated UserDefaults suite per test.
func makeIsolatedDefaults() -> UserDefaults {
    let name = "MacAppUpdaterTests.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(named: name)!
    defaults.removePersistentDomain(forName: TestDefaults.prefix + name)
    return defaults
}

struct GitHubRepositoryStoreTests {
    @Test(arguments: [
        ("owner/repo", "owner/repo"),
        ("  https://github.com/owner/repo.git ", "owner/repo"),
        ("github.com/owner/repo/", "owner/repo"),
        ("www.github.com/a-b/c.d_e", "a-b/c.d_e"),
    ])
    func normalizesValidInput(input: String, expected: String) {
        #expect(GitHubRepositoryMappings.normalizedRepository(input) == expected)
    }

    @Test(arguments: ["", "owner", "owner/repo/extra", "../repo", "owner/re po", "owner/repo?x=1", "ownér/repo"])
    func rejectsInvalidInput(input: String) {
        #expect(GitHubRepositoryMappings.normalizedRepository(input) == nil)
    }

    @Test func addAndRemoveReturnNewValues() throws {
        let empty = GitHubRepositoryMappings()
        let added = try empty.adding(repository: "https://github.com/a/b", for: "com.x")
        #expect(empty.repositories.isEmpty)
        #expect(added.repository(for: "com.x") == "a/b")
        let replaced = try added.adding(repository: "c/d", for: "com.x")
        #expect(replaced.repositories == ["com.x": "c/d"])
        #expect(replaced.removing(bundleIdentifier: "com.x").repositories.isEmpty)
        #expect(added.repository(for: "com.x") == "a/b")
    }

    @Test func addRejectsInvalidValues() {
        #expect(throws: GitHubMappingError.invalidRepository("nope")) {
            try GitHubRepositoryMappings().adding(repository: "nope", for: "com.x")
        }
        #expect(throws: GitHubMappingError.emptyBundleIdentifier) {
            try GitHubRepositoryMappings().adding(repository: "a/b", for: "  ")
        }
    }

    @Test func storeRoundTripsAndDropsInvalidEntries() throws {
        let defaults = makeIsolatedDefaults()
        let store = GitHubRepositoryStore(defaults: defaults)
        #expect(store.load().repositories.isEmpty)
        try store.save(GitHubRepositoryMappings(repositories: ["com.a": "a/b"]))
        #expect(GitHubRepositoryStore(defaults: defaults).load().repositories == ["com.a": "a/b"])

        let tampered = #"{"repositories":{"com.a":"a/b","com.bad":"../../etc"}}"#
        defaults.set(Data(tampered.utf8), forKey: GitHubRepositoryStore.defaultsKey)
        #expect(store.load().repositories == ["com.a": "a/b"])
    }

    @Test func suggestionsAreValid() {
        #expect(!GitHubRepositoryMappings.suggestions.isEmpty)
        #expect(GitHubRepositoryMappings.suggestions.values.allSatisfy(GitHubReleasesSource.isValidRepository))
        #expect(GitHubRepositoryMappings.suggestion(for: "com.knollsoft.Rectangle") == "rxhanson/Rectangle")
    }
}

struct GitHubTokenStoreTests {
    @Test func sanitizesTokens() {
        #expect(KeychainTokenStore.sanitized("  ghp_abc123 \n") == "ghp_abc123")
        #expect(KeychainTokenStore.sanitized("") == nil)
        #expect(KeychainTokenStore.sanitized(nil) == nil)
        #expect(KeychainTokenStore.sanitized("abc\r\nX-Evil: 1") == nil)
    }

    @Test func inMemoryStoreFeedsTokenProvider() throws {
        let store = InMemoryTokenStore()
        #expect(store.tokenProvider() == nil)
        try store.saveToken("tok")
        #expect(store.tokenProvider() == "tok")
        try store.deleteToken()
        #expect(store.tokenProvider() == nil)
        #expect(throws: TokenStoreError.invalidToken) { try store.saveToken("   ") }
    }

    @Test func providerDegradesToAnonymousOnReadFailure() {
        #expect(InMemoryTokenStore(token: "x", failure: .keychain(-25300)).tokenProvider() == nil)
    }
}

struct BetaChannelStoreTests {
    @Test func roundTripsOptIns() {
        let defaults = makeIsolatedDefaults()
        let store = BetaChannelStore(defaults: defaults)
        #expect(store.load().isEmpty)
        #expect(store.setOptedIn(true, for: "com.a") == ["com.a"])
        store.setOptedIn(true, for: "com.b")
        #expect(BetaChannelStore(defaults: defaults).load() == ["com.a", "com.b"])
        store.setOptedIn(false, for: "com.a")
        #expect(store.load() == ["com.b"])
        #expect(store.isOptedIn("com.b"))
    }

    @Test func channelProviderReflectsLatestOptIns() {
        let store = BetaChannelStore(defaults: makeIsolatedDefaults())
        let provider = store.channelProvider
        let app = TestApps.make(bundleIdentifier: "com.a")
        #expect(provider(app).isEmpty)
        store.setOptedIn(true, for: "com.a")
        #expect(provider(app) == [BetaChannelStore.betaChannel])
    }

    @Test func updatingIsPure() {
        let original: Set<String> = ["a"]
        #expect(BetaChannelStore.updating(original, bundleIdentifier: "b", isOptedIn: true) == ["a", "b"])
        #expect(BetaChannelStore.updating(original, bundleIdentifier: "a", isOptedIn: false).isEmpty)
        #expect(original == ["a"])
    }
}
