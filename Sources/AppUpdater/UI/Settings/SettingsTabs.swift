import AppUpdaterCore
import os
import SwiftUI

/// The Settings window: General, automatic update policies, GitHub mappings and self-update.
struct SettingsTabs: View {
    let environment: AppEnvironment

    var body: some View {
        TabView {
            SettingsView(
                onIntervalChange: environment.reschedule(hours:),
                helper: environment.helperClient,
                onHelperStatusChange: { Task { await environment.viewModel.refreshHelperStatus() } },
                managed: environment.managed,
                notarizationAudit: environment.notarizationAudit,
                notarizationChangedExternally: environment.notarizationSettingChangedExternally
            )
            .tabItem { Label("General", systemImage: "gearshape") }

            PoliciesSettingsTab(
                store: environment.policyStore, viewModel: environment.viewModel, managed: environment.managed
            )
                .tabItem { Label("Policies", systemImage: "bolt.badge.automatic") }

            GitHubMappingsView(
                store: environment.githubStore,
                tokenStore: environment.tokenStore,
                installedApps: environment.viewModel.installedApps,
                onMappingsChange: environment.githubMappingsChanged
            )
            .tabItem { Label("GitHub", systemImage: "shippingbox") }

            SelfUpdateSettingsTab(selfUpdater: environment.selfUpdater)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
    }
}

/// Owns the policies value for `UpdatePoliciesView` and persists every change.
private struct PoliciesSettingsTab: View {
    let store: any UpdatePoliciesStoring
    let viewModel: UpdatesViewModel
    let managed: ManagedConfiguration

    @State private var policies: UpdatePolicies?
    private let logger = Logger(subsystem: "com.macappupdater", category: "Settings")

    var body: some View {
        UpdatePoliciesView(
            policies: policies ?? store.load(),
            installedApps: viewModel.installedApps,
            icon: viewModel.icon(for:),
            managed: managed,
            onChange: save
        )
        .frame(width: 460, height: 640)
        .onAppear { policies = store.load() }
    }

    /// Re-reads after saving so administrator-forced values snap back.
    private func save(_ updated: UpdatePolicies) {
        do {
            try store.save(updated)
        } catch {
            logger.error("Saving update policies failed: \(error.localizedDescription, privacy: .public)")
        }
        policies = store.load()
    }
}

/// Updates of App Updater itself (Sparkle).
private struct SelfUpdateSettingsTab: View {
    let selfUpdater: SelfUpdater

    var body: some View {
        Form {
            Section("App Updater") {
                LabeledContent("Version", value: Self.appVersion)
                CheckForAppUpdatesView(selfUpdater: selfUpdater)
                if !selfUpdater.isActive {
                    Text("Self-update is available in the packaged App Updater.app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "Development build")
    }
}
