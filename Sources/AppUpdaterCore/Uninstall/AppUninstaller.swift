import Foundation
import os

/// Two-step uninstall: `scan` (dry run) then `uninstall` of a user-selected subset.
/// Everything goes to the Trash; nothing is deleted permanently.
public struct AppUninstaller: Sendable {
    public static let updaterBundleIdentifier = "com.macappupdater.app"

    private let scanner: LeftoverScanner
    private let runningChecker: any RunningAppChecking
    private let trasher: any Trashing
    private let protectedBundleIdentifiers: Set<String>
    private let signatureVerifier: any SignatureVerifying
    private let duplicateFinder: any DuplicateBundleFinding
    private let bundleReader = BundleInfoReader()
    private static let logger = Logger(subsystem: "com.macappupdater", category: "AppUninstaller")

    public init(
        scanner: LeftoverScanner = LeftoverScanner(),
        runningChecker: any RunningAppChecking = WorkspaceRunningAppChecker(),
        trasher: any Trashing = FileManagerTrasher(),
        protectedBundleIdentifiers: Set<String> = AppUninstaller.defaultProtectedIdentifiers,
        signatureVerifier: any SignatureVerifying = CodeSignatureVerifier(),
        duplicateFinder: any DuplicateBundleFinding = AppScanner()
    ) {
        self.scanner = scanner
        self.runningChecker = runningChecker
        self.trasher = trasher
        self.protectedBundleIdentifiers = protectedBundleIdentifiers
        self.signatureVerifier = signatureVerifier
        self.duplicateFinder = duplicateFinder
    }

    public static var defaultProtectedIdentifiers: Set<String> {
        Set([updaterBundleIdentifier, Bundle.main.bundleIdentifier].compactMap { $0 })
    }

    /// Why this app may never be uninstalled, or nil if it is eligible. Cheap; use it to disable UI.
    public func refusal(for app: InstalledApp) -> UninstallError? {
        let id = app.bundleIdentifier
        if id.hasPrefix("com.apple.") || app.url.standardizedFileURL.path.hasPrefix("/System/") {
            return .systemApp(name: app.name)
        }
        if protectedBundleIdentifiers.contains(id) { return .protectedApp(name: app.name) }
        if !LeftoverRules.isSafeComponent(id) { return .invalidBundleIdentifier(id) }
        return nil
    }

    public func isRunning(_ app: InstalledApp) async -> Bool {
        await runningChecker.isRunning(bundleIdentifier: app.bundleIdentifier)
    }

    /// Dry run. Throws only for refused apps (system / protected / invalid id).
    public func scan(_ app: InstalledApp) async throws(UninstallError) -> UninstallPlan {
        if let refusal = refusal(for: app) { throw refusal }
        let scanner = scanner
        async let integrity = integrity(of: app)
        let (bundle, leftovers) = await Task.detached(priority: .userInitiated) {
            let bundle = LeftoverItem(
                url: app.url.standardizedFileURL,
                kind: .appBundle,
                sizeInBytes: LeftoverScanner.size(of: app.url),
                confidence: .exact
            )
            return (bundle, scanner.scan(bundleIdentifier: app.bundleIdentifier, appName: app.name))
        }.value
        return UninstallPlan(app: app, bundle: bundle, leftovers: leftovers, integrity: await integrity)
    }

    /// Signature/Team ID of the bundle and other bundles claiming the same identifier (L-11).
    func integrity(of app: InstalledApp) async -> BundleIntegrity {
        let ownPath = app.url.standardizedFileURL.path
        let duplicates = await duplicateFinder.bundles(withIdentifier: app.bundleIdentifier)
            .filter { $0.standardizedFileURL.path != ownPath }
        do {
            let team = try await signatureVerifier.teamIdentifier(of: app.url)
            return BundleIntegrity(teamIdentifier: team, signatureProblem: nil, duplicateBundles: duplicates)
        } catch {
            Self.logger.notice(
                "No valid signature for \(app.url.lastPathComponent, privacy: .public) (\(app.url.path, privacy: .private))"
            )
            return BundleIntegrity(
                teamIdentifier: nil, signatureProblem: error.localizedDescription, duplicateBundles: duplicates
            )
        }
    }

    /// Moves the selected plan items to the Trash. The app bundle goes first; if that fails,
    /// leftovers are kept so the user's data is not removed while the app remains.
    public func uninstall(_ plan: UninstallPlan, selected: Set<URL>) async throws(UninstallError) -> UninstallReport {
        if let refusal = refusal(for: plan.app) { throw refusal }
        guard !selected.isEmpty else { throw .nothingSelected }
        guard await !isRunning(plan.app) else { throw .appIsRunning(name: plan.app.name) }

        let selectedPaths = Set(selected.map(\.standardizedFileURL.path))
        let planPaths = Set(plan.items.map(\.url.path))
        let foreign = selectedPaths.subtracting(planPaths).sorted().map {
            UninstallReport.Failure(url: URL(fileURLWithPath: $0), error: .notInPlan(URL(fileURLWithPath: $0)))
        }
        let chosen = plan.items.filter { selectedPaths.contains($0.url.path) }

        let work = self
        let outcome = await Task.detached(priority: .userInitiated) { work.trash(chosen, plan: plan) }.value
        return UninstallReport(app: plan.app, trashed: outcome.trashed, failures: foreign + outcome.failures)
    }

    // MARK: Trashing

    private struct Outcome {
        var trashed: [UninstallReport.Trashed] = []
        var failures: [UninstallReport.Failure] = []
    }

    private func trash(_ items: [LeftoverItem], plan: UninstallPlan) -> Outcome {
        var outcome = Outcome()
        var bundleFailed = false
        for item in items.sorted(by: { ($0.kind == .appBundle ? 0 : 1) < ($1.kind == .appBundle ? 0 : 1) }) {
            if bundleFailed {
                outcome.failures.append(.init(url: item.url, error: .skippedBecauseBundleFailed(item.url)))
                continue
            }
            switch trashOne(item, plan: plan) {
            case .success(let trashed):
                outcome.trashed.append(trashed)
            case .failure(let error):
                outcome.failures.append(.init(url: item.url, error: error))
                bundleFailed = item.kind == .appBundle
            }
        }
        return outcome
    }

    private func trashOne(_ item: LeftoverItem, plan: UninstallPlan) -> Result<UninstallReport.Trashed, UninstallError> {
        do throws(UninstallError) {
            let verified = try revalidate(item, plan: plan)
            do {
                let trashURL = try trasher.trashItem(at: verified.url)
                Self.logger.info(
                    "Trashed \(verified.url.lastPathComponent, privacy: .public) (\(verified.url.path, privacy: .private))"
                )
                return .success(.init(item: verified, trashURL: trashURL))
            } catch {
                Self.logger.error(
                    """
                    Trash failed for \(verified.url.lastPathComponent, privacy: .public) \
                    (\(verified.url.path, privacy: .private)): \(error.localizedDescription, privacy: .private)
                    """
                )
                throw .trashFailed(url: verified.url, message: error.localizedDescription)
            }
        } catch {
            return .failure(error)
        }
    }

    private func revalidate(_ item: LeftoverItem, plan: UninstallPlan) throws(UninstallError) -> LeftoverItem {
        guard item.kind == .appBundle else {
            return try scanner.validate(item.url, bundleIdentifier: plan.app.bundleIdentifier, appName: plan.app.name)
        }
        return try revalidateBundle(item, app: plan.app)
    }

    private func revalidateBundle(_ item: LeftoverItem, app: InstalledApp) throws(UninstallError) -> LeftoverItem {
        let url = item.url.standardizedFileURL
        guard url.path == app.url.standardizedFileURL.path, url.pathExtension.lowercased() == "app" else {
            throw .bundleMismatch(url)
        }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values?.isSymbolicLink == true { throw .symlinkEscape(url) }
        guard values?.isDirectory == true else { throw .itemMissing(url) }
        guard url.resolvingSymlinksInPath().pathExtension.lowercased() == "app",
              !url.resolvingSymlinksInPath().path.hasPrefix("/System/"),
              (try? bundleReader.read(appAt: url))?.bundleIdentifier == app.bundleIdentifier
        else { throw .bundleMismatch(url) }
        return item
    }
}
