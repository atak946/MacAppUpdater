import AppUpdaterCore
import SwiftUI

/// Everything `GitHubMappingsView` needs, handed from the composition root to the main window.
struct GitHubMappingDependencies {
    let store: GitHubRepositoryStore
    let tokenStore: any TokenStoring
    let onMappingsChange: (GitHubRepositoryMappings) -> Void
}

/// Coverage › "Map GitHub Repo…": the Settings mappings view in a sheet, prefilled with the app.
struct GitHubMappingSheet: View {
    let app: InstalledApp
    let installedApps: [InstalledApp]
    let dependencies: GitHubMappingDependencies

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Map \(app.name) to GitHub").font(.headline)
                    Text("Releases of the repository are then checked for updates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            GitHubMappingsView(
                store: dependencies.store,
                tokenStore: dependencies.tokenStore,
                installedApps: installedApps,
                onMappingsChange: dependencies.onMappingsChange,
                initialBundleID: app.bundleIdentifier
            )
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 540, height: 480)
    }
}
