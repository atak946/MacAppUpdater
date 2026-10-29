import AppUpdaterCore
import Foundation
import MaintenanceCore
import MonitorCore
import os

extension UpdateChecker: UpdateChecking {}
extension HelperClient: HelperManaging {}
extension UpdateHistoryStore: UpdateHistoryRecording {}

/// Composition root: the only place that knows concrete core types.
@MainActor
final class AppEnvironment {
    let viewModel: UpdatesViewModel
    let formulaeModel: FormulaeModel
    let cleanupModel: CleanupModel
    let startupModel: StartupModel
    let securityModel: SecurityModel
    let monitorModel: MonitorModel
    let migrationModel: MigrationModel
    let selfUpdater: SelfUpdater
    let helperClient: HelperClient
    let githubStore: GitHubRepositoryStore
    let tokenStore: any TokenStoring
    let policyStore: any UpdatePoliciesStoring
    let exclusionStore: any ExclusionRulesStoring
    /// Administrator-forced settings (MDM profile), read once at launch.
    let managed: ManagedConfiguration
    let managedGate: ManagedPolicyGate
    /// Tamper evidence for the "allow unnotarized" toggle (L-14).
    let notarizationAudit: NotarizationSettingAudit
    /// Evaluated once at launch: the toggle was changed outside the app since it last wrote it.
    let notarizationSettingChangedExternally: Bool

    private let http: URLSessionHTTPClient
    private let comparator = VersionComparator()
    private let betaStore: BetaChannelStore
    /// Reused across checker rebuilds so the cask index isn't downloaded again.
    private let homebrewSource: HomebrewCaskSource
    /// Built once: definitions are bundled data. Empty when the resource bundle is missing.
    private let vendorSource: VendorFeedSource
    /// Shared by `ElectronUpdateSource` (registers SHA-512s) and the downloader (verifies them).
    private let checksumStore: ChecksumStore
    private let backupStore: BackupStore
    private let scheduler: UpdateScheduler
    private let notifier: UpdateNotifier
    private let logger = Logger(subsystem: "com.macappupdater", category: "AppEnvironment")

    init(defaults: UserDefaults = .standard) {
        let http = URLSessionHTTPClient()
        let helperClient = HelperClient()
        let managed = ManagedConfiguration(reader: CFPreferencesManagedReader())
        let gate = ManagedPolicyGate(configuration: managed)
        let notarizationAudit = NotarizationSettingAudit(defaults: defaults)
        let gatekeeper = SpctlGatekeeperAssessor()
        let notarizationPolicy = Self.liveNotarizationPolicy(audit: notarizationAudit, gate: gate)
        // Restore is gated like an install (H-2): same assessor, same live user/MDM policy.
        let backupStore = BackupStore(
            gatekeeperAssessor: gatekeeper, notarizationPolicy: notarizationPolicy()
        )
        let policyStore = ManagedUpdatePoliciesStore(
            base: UserDefaultsUpdatePoliciesStore(defaults: defaults), configuration: managed
        )
        let exclusionStore = ManagedExclusionRulesStore(
            base: UserDefaultsExclusionRulesStore(defaults: defaults), configuration: managed
        )
        let betaStore = BetaChannelStore(defaults: defaults)
        let checksumStore = ChecksumStore()
        let vendorSource = VendorFeedSource.bundled(http: http, comparator: comparator)
        let downloadHosts = UserDefaultsDownloadHostStore(defaults: defaults)
        self.notarizationAudit = notarizationAudit
        self.notarizationSettingChangedExternally = !gate.isNotarizationLocked && notarizationAudit.wasChangedOutsideApp
        self.http = http
        self.helperClient = helperClient
        self.backupStore = backupStore
        self.managed = managed
        self.managedGate = gate
        self.policyStore = policyStore
        self.exclusionStore = exclusionStore
        self.betaStore = betaStore
        self.checksumStore = checksumStore
        self.vendorSource = vendorSource
        self.githubStore = GitHubRepositoryStore(defaults: defaults)
        self.tokenStore = KeychainTokenStore()
        self.homebrewSource = HomebrewCaskSource(http: http, comparator: comparator)
        self.selfUpdater = SelfUpdater()
        // Shares the update check's cask index so an export doesn't download it again.
        self.migrationModel = MigrationModel(resolver: LiveMigrationResolver(
            caskSource: homebrewSource, appStoreSource: AppStoreSource(http: http, comparator: comparator)
        ))
        self.formulaeModel = FormulaeModel(homebrew: HomebrewCLI())
        self.cleanupModel = CleanupModel(
            scanner: FileSystemCleanupScanner(installedApps: LiveInstalledAppCatalog()), cleaner: TrashCleaner()
        )
        self.startupModel = StartupModel(scanner: LiveStartupScanner(), controller: LaunchctlStartupController())
        self.securityModel = SecurityModel(checker: SystemSecurityChecker(), auditor: TCCPermissionAuditor())
        self.monitorModel = MonitorModel(
            system: LiveSystemSampler(),
            processes: LiveProcessSampler(),
            ports: LsofPortScanner(),
            terminator: SignalProcessTerminator()
        )

        let services = UpdateServices(
            packageInstaller: PackageInstaller(installService: helperClient),
            helper: helperClient,
            backupStore: backupStore,
            history: UpdateHistoryStore(),
            policies: policyStore,
            betaStore: betaStore,
            uninstaller: AppUninstaller(),
            insights: InsightsCollector(
                teamStore: UserDefaultsTeamIdentifierStore(defaults: defaults),
                gatekeeper: gatekeeper,
                downloadHostStore: downloadHosts,
                verdictCache: GatekeeperVerdictCache(storage: .standardDefaults)
            ),
            compatibility: CompatibilityAnalyzer(),
            runningApps: WorkspaceRunningAppChecker(),
            releaseNotesLoader: ReleaseNotesLoader(httpClient: http),
            conditions: LiveSystemConditionsProvider(),
            // Actor-owned `UserDefaults.standard`: a main-actor `defaults` can't be sent to it.
            firstSeen: FirstSeenStore(),
            vendorDetector: VendorManagementDetector(),
            vendorInstallStrategy: { vendorSource.installStrategy(for: $0) },
            vendorName: { vendorSource.definition(for: $0.app.bundleIdentifier)?.name },
            downloadHosts: downloadHosts,
            managed: managed,
            sizeProbe: DownloadSizeProbe(),
            versionAliases: InstalledVersionAliasStore()
        )
        let viewModel = UpdatesViewModel(
            scanner: AppScanner(),
            checker: UpdateChecker(sources: []),
            downloader: ProgressDownloader(publicEDKey: Self.sparklePublicKey, checksum: checksumStore.lookup),
            installer: AppInstaller(
                backupStore: backupStore,
                gatekeeperAssessor: gatekeeper,
                notarizationPolicy: notarizationPolicy(),
                downloadHostStore: downloadHosts
            ),
            services: services,
            exclusionStore: exclusionStore
        )
        let notifier = UpdateNotifier()
        self.viewModel = viewModel
        self.notifier = notifier
        let interval = gate.effectiveCheckInterval(userValue: Self.storedIntervalHours(defaults))
        self.scheduler = UpdateScheduler(interval: interval * 3600) {
            // Auto-install only runs from the scheduled path, never from a manual check.
            let remaining = await viewModel.runScheduledCheck()
            await notifier.notifyUpdatesAvailable(remaining)
        }
        viewModel.replaceChecker(makeChecker(mappings: githubStore.load()))
    }

    func start() {
        scheduler.start()
        let notifier = self.notifier
        let backupStore = self.backupStore
        let logger = self.logger
        Task { await notifier.requestAuthorization() }
        Task {
            do {
                try await backupStore.pruneAll()
            } catch {
                logger.error("Pruning backups failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        Task { await viewModel.loadHistory() }
        Task { await refreshHelperRegistration() }
    }

    func stop() {
        scheduler.stop()
    }

    func reschedule(hours: Double) {
        logger.info("Rescheduling update checks every \(hours, privacy: .public)h")
        scheduler.updateInterval(managedGate.effectiveCheckInterval(userValue: hours) * 3600)
    }

    var githubMappingDependencies: GitHubMappingDependencies {
        GitHubMappingDependencies(
            store: githubStore, tokenStore: tokenStore, onMappingsChange: githubMappingsChanged
        )
    }

    /// `GitHubReleasesSource` captures its mappings at init, so the checker is rebuilt.
    func githubMappingsChanged(_ mappings: GitHubRepositoryMappings) {
        viewModel.replaceChecker(makeChecker(mappings: mappings))
        Task { await viewModel.refresh() }
    }

    /// Sources not allowed by the organization (MDM `AllowedSources`) are left out.
    private func makeChecker(mappings: GitHubRepositoryMappings) -> UpdateChecker {
        let channels = managedGate.areBetaChannelsAllowed
            ? betaStore.channelProvider
            : SparkleSource.defaultChannelsOnly
        return UpdateChecker(sources: managedGate.allowedSources([
            AppStoreSource(http: http, comparator: comparator),
            SparkleSource(http: http, comparator: comparator, allowedChannels: channels),
            ElectronUpdateSource(http: http, comparator: comparator, checksumStore: checksumStore),
            vendorSource,
            GitHubReleasesSource(
                repositories: mappings.repositories, http: http, comparator: comparator,
                token: tokenStore.tokenProvider
            ),
            homebrewSource,
        ]))
    }

    /// The notarization policy is re-read on every install and restore, so the Settings toggle
    /// applies immediately. MDM `RequireNotarization = true` wins; a toggle flipped outside the app
    /// (unconfirmed by `NotarizationSettingAudit`) counts as off.
    private static func liveNotarizationPolicy(
        audit: NotarizationSettingAudit,
        gate: ManagedPolicyGate
    ) -> @Sendable () -> NotarizationPolicy {
        {
            gate.effectiveNotarizationPolicy(userAllowsUnnotarized: audit.confirmedAllowUnnotarized)
        }
    }

    /// After an app update launchd must pick up the new helper binary: re-register when stale.
    private func refreshHelperRegistration() async {
        guard await viewModel.refreshHelperStatus() == .enabled else { return }
        guard !(await helperClient.isHelperUpToDate()) else { return }
        logger.notice("Privileged helper is outdated; re-registering")
        do {
            try await helperClient.unregister()
            try await helperClient.register()
        } catch {
            logger.error("Re-registering helper failed: \(error.localizedDescription, privacy: .public)")
        }
        await viewModel.refreshHelperStatus()
    }

    private static func storedIntervalHours(_ defaults: UserDefaults) -> Double {
        let stored = defaults.double(forKey: SettingsKeys.checkIntervalHours)
        return stored > 0 ? stored : SettingsKeys.defaultCheckIntervalHours
    }

    /// Sparkle apps publish their EdDSA public key as `SUPublicEDKey` in Info.plist.
    private static let sparklePublicKey: PublicKeyLookup = { app in
        Bundle(url: app.url)?.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    }
}
