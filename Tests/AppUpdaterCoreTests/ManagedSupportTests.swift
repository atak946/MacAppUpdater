import Foundation
@testable import AppUpdaterCore

/// In-memory managed domain: every stored value counts as forced.
struct FakeManagedReader: ManagedPreferencesReading, @unchecked Sendable {
    let values: [String: Any]

    init(_ values: [ManagedKey: Any] = [:]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    func forcedValue(forKey key: String) -> Any? { values[key] }
}

final class ManagedFakeExclusionStore: ExclusionRulesStoring, @unchecked Sendable {
    private(set) var stored: ExclusionRules

    init(_ rules: ExclusionRules = ExclusionRules()) { stored = rules }

    func load() -> ExclusionRules { stored }
    func save(_ rules: ExclusionRules) throws { stored = rules }
}

final class ManagedFakePoliciesStore: UpdatePoliciesStoring, @unchecked Sendable {
    private(set) var stored: UpdatePolicies

    init(_ policies: UpdatePolicies = UpdatePolicies()) { stored = policies }

    func load() -> UpdatePolicies { stored }
    func save(_ policies: UpdatePolicies) throws { stored = policies }
}
