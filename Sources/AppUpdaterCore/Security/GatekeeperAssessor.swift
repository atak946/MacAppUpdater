import Foundation
import os

/// Assesses whether Gatekeeper would allow a bundle to run (notarization check).
public protocol GatekeeperAssessing: Sendable {
    /// Never throws: failures to assess are reported as `.unknown`.
    func assess(_ bundleURL: URL) async -> GatekeeperVerdict
}

/// Runs `/usr/sbin/spctl --assess --type execute -vv` and, as a secondary
/// signal, `stapler validate` when a real (non-shim) stapler binary exists.
///
/// `/usr/bin/stapler` and `/usr/bin/xcrun` are developer-tool shims: on Macs
/// without Xcode or the Command Line Tools they pop up an install dialog, so
/// only the binaries inside a developer directory are used.
///
/// The stapler result only upgrades `.developerIDNotNotarized` / `.unknown` to
/// `.notarized` (a stapled ticket proves notarization even when `spctl` could
/// not reach Apple). It never overrides `.rejected`.
public struct SpctlGatekeeperAssessor: GatekeeperAssessing {
    public static let spctlPath = "/usr/sbin/spctl"
    public static let staplerCandidates = [
        "/Library/Developer/CommandLineTools/usr/bin/stapler",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/stapler",
    ]

    private static let logger = Logger(subsystem: "com.macappupdater", category: "Gatekeeper")

    private let commandRunner: any CommandRunner
    private let staplerPath: String?

    /// - Parameter staplerPath: pass `nil` to disable the stapler check; defaults
    ///   to the first executable entry of `staplerCandidates`.
    public init(
        commandRunner: any CommandRunner = ProcessCommandRunner(),
        staplerPath: String? = SpctlGatekeeperAssessor.locateStapler()
    ) {
        self.commandRunner = commandRunner
        self.staplerPath = staplerPath
    }

    public static func locateStapler(fileManager: FileManager = .default) -> String? {
        staplerCandidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    public func assess(_ bundleURL: URL) async -> GatekeeperVerdict {
        let verdict = await runSpctl(on: bundleURL)
        switch verdict {
        case .notarized, .rejected:
            return verdict
        case .developerIDNotNotarized, .unknown:
            return await hasStapledTicket(bundleURL) ? .notarized : verdict
        }
    }

    private func runSpctl(on bundleURL: URL) async -> GatekeeperVerdict {
        let arguments = ["--assess", "--type", "execute", "-vv", bundleURL.path]
        do {
            let output = try await commandRunner.run(Self.spctlPath, arguments: arguments)
            return GatekeeperOutputParser.parseAssessment(output)
        } catch UpdaterError.commandFailed(_, let status, let output) {
            // spctl exits non-zero (3) on rejection; the verdict is still in the output.
            let verdict = GatekeeperOutputParser.parseAssessment(output)
            if case .unknown = verdict { return .unknown(reason: "spctl exited with \(status)") }
            return verdict
        } catch {
            Self.logger.error("spctl failed: \(error.localizedDescription, privacy: .public)")
            return .unknown(reason: error.localizedDescription)
        }
    }

    private func hasStapledTicket(_ bundleURL: URL) async -> Bool {
        guard let staplerPath else { return false }
        do {
            let output = try await commandRunner.run(staplerPath, arguments: ["validate", bundleURL.path])
            return GatekeeperOutputParser.staplerConfirmsTicket(output)
        } catch {
            // Exit 65 = no ticket stapled; that is the common case for online-only notarization.
            return false
        }
    }
}

/// Assessor that always returns a fixed verdict (tests, or to disable the check).
public struct FixedGatekeeperAssessor: GatekeeperAssessing {
    public let verdict: GatekeeperVerdict

    public init(_ verdict: GatekeeperVerdict) {
        self.verdict = verdict
    }

    public func assess(_ bundleURL: URL) async -> GatekeeperVerdict { verdict }
}
