import Foundation
import os

/// A Homebrew formula (command-line tool) with a newer version available.
public struct OutdatedFormula: Sendable, Hashable, Identifiable, Decodable {
    public var id: String { name }

    public let name: String
    public let installedVersions: [String]
    public let currentVersion: String
    public let pinned: Bool

    public init(name: String, installedVersions: [String], currentVersion: String, pinned: Bool) {
        self.name = name
        self.installedVersions = installedVersions
        self.currentVersion = currentVersion
        self.pinned = pinned
    }

    /// Latest installed version, for display ("1.2 → 1.3").
    public var installedVersion: String { installedVersions.last ?? "—" }

    private enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
        case pinned
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        installedVersions = try container.decodeIfPresent([String].self, forKey: .installedVersions) ?? []
        currentVersion = try container.decode(String.self, forKey: .currentVersion)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

public enum HomebrewError: Error, Sendable, Equatable, LocalizedError {
    case notInstalled
    case invalidFormulaName(String)
    case pinned(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: String(coreLocalized: "Homebrew is not installed")
        case .invalidFormulaName(let name): String(coreLocalized: "Invalid formula name: \(name)")
        case .pinned(let name): String(coreLocalized: "\(name) is pinned; unpin it with `brew unpin \(name)` to upgrade")
        }
    }
}

/// Abstraction over the Homebrew formula commands so UI models are testable.
public protocol HomebrewFormulaManaging: Sendable {
    var isAvailable: Bool { get }
    func outdatedFormulae() async throws -> [OutdatedFormula]
    func upgrade(_ name: String) async throws
}

/// Talks to the `brew` command-line tool for formulae (not casks).
///
/// brew is invoked through `/usr/bin/env HOMEBREW_NO_AUTO_UPDATE=1 …` so a check never
/// triggers a slow `brew update`, since `CommandRunner` has no environment support.
public struct HomebrewCLI: HomebrewFormulaManaging {
    public static let defaultBrewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    static let envPath = "/usr/bin/env"
    static let environment = ["HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_INSTALL_CLEANUP=1", "HOMEBREW_NO_ENV_HINTS=1"]
    private static let maxNameLength = 128
    private static let logger = Logger(subsystem: "com.macappupdater", category: "HomebrewCLI")

    private let runner: any CommandRunner
    private let candidatePaths: [String]
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        runner: any CommandRunner = ProcessCommandRunner(),
        candidatePaths: [String] = HomebrewCLI.defaultBrewPaths,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.runner = runner
        self.candidatePaths = candidatePaths
        self.isExecutable = isExecutable
    }

    /// First existing brew executable, Apple Silicon prefix first.
    public var brewPath: String? { candidatePaths.first(where: isExecutable) }

    public var isAvailable: Bool { brewPath != nil }

    public func outdatedFormulae() async throws -> [OutdatedFormula] {
        let output = try await runBrew(["outdated", "--json=v2", "--formula"])
        return try Self.parseOutdated(output)
    }

    public func upgrade(_ name: String) async throws {
        guard Self.isValidFormulaName(name) else {
            Self.logger.error("Rejected formula name \(name, privacy: .public)")
            throw HomebrewError.invalidFormulaName(name)
        }
        // "--" ends option parsing; the name is a separate argv entry (no shell involved).
        try await runBrew(["upgrade", "--formula", "--", name])
        Self.logger.info("Upgraded formula \(name, privacy: .public)")
    }

    @discardableResult
    private func runBrew(_ arguments: [String]) async throws -> String {
        guard let brew = brewPath else { throw HomebrewError.notInstalled }
        return try await runner.run(Self.envPath, arguments: Self.environment + [brew] + arguments)
    }

    // MARK: - Pure helpers

    /// Formula names: `name`, `name@1.2`, `c++-lib`, or tap-qualified `user/tap/name`.
    /// Each component must start with an alphanumeric, so nothing can look like an option.
    public static func isValidFormulaName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxNameLength else { return false }
        let pattern = #/[A-Za-z0-9][A-Za-z0-9@+._\-]*(/[A-Za-z0-9][A-Za-z0-9@+._\-]*){0,2}/#
        guard name.wholeMatch(of: pattern) != nil else { return false }
        return !name.split(separator: "/").contains { $0.contains("..") }
    }

    /// Parses `brew outdated --json=v2`. stderr is merged into the output by
    /// `ProcessCommandRunner`, so warnings around the JSON object are tolerated.
    public static func parseOutdated(_ output: String) throws -> [OutdatedFormula] {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else {
            throw UpdaterError.parsing("brew outdated returned no JSON")
        }
        let json = Data(output[start...end].utf8)
        do {
            return try JSONDecoder().decode(OutdatedResponse.self, from: json).formulae
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            throw UpdaterError.parsing("brew outdated JSON: \(error.localizedDescription)")
        }
    }

    private struct OutdatedResponse: Decodable {
        let formulae: [OutdatedFormula]
    }
}
