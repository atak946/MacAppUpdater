import AppUpdaterCore
import os
import SwiftUI

/// Settings tab: map installed apps to GitHub repositories and manage the optional API token.
/// Standalone: all dependencies are plain inputs so the integrator decides where it lives.
struct GitHubMappingsView: View {
    let store: GitHubRepositoryStore
    let tokenStore: any TokenStoring
    let installedApps: [InstalledApp]
    /// Called after mappings were persisted, so the caller can rebuild its `UpdateChecker`.
    let onMappingsChange: (GitHubRepositoryMappings) -> Void
    /// Preselects this app in the add row (e.g. from Coverage › Map GitHub Repo).
    var initialBundleID: String?

    @State private var mappings = GitHubRepositoryMappings()
    @State private var selectedBundleID = ""
    @State private var repositoryInput = ""
    @State private var saveError: String?

    private let logger = Logger(subsystem: "com.macappupdater", category: "GitHubMappings")

    var body: some View {
        Form {
            Section("Repositories") {
                mappingsTable
                addRow
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("API token") {
                GitHubTokenField(tokenStore: tokenStore)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            mappings = store.load()
            if let initialBundleID, mappings.repository(for: initialBundleID) == nil {
                selectedBundleID = initialBundleID
            }
        }
    }

    // MARK: Table

    private var rows: [MappingRow] {
        mappings.repositories
            .map { MappingRow(bundleID: $0.key, appName: appName(for: $0.key), repository: $0.value) }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    @ViewBuilder
    private var mappingsTable: some View {
        if rows.isEmpty {
            Text("No apps mapped yet. Map an app to check its GitHub releases.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Table(rows) {
                TableColumn("App") { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.appName)
                        Text(row.bundleID).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TableColumn("Repository") { row in
                    Text(row.repository).textSelection(.enabled)
                }
                TableColumn("") { row in
                    Button(role: .destructive) { remove(row.bundleID) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove mapping")
                    .accessibilityLabel("Remove mapping for \(row.appName)")
                }
                .width(28)
            }
            .frame(minHeight: 140)
        }
    }

    // MARK: Add row

    private var candidateApps: [InstalledApp] {
        installedApps
            .filter { !$0.isFromAppStore && mappings.repository(for: $0.bundleIdentifier) == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var normalizedInput: String? {
        GitHubRepositoryMappings.normalizedRepository(repositoryInput)
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("App", selection: $selectedBundleID) {
                    Text("Choose an app…").tag("")
                    ForEach(candidateApps) { app in
                        Text(app.name).tag(app.bundleIdentifier)
                    }
                }
                .onChange(of: selectedBundleID) { _, newValue in applySuggestion(for: newValue) }
                TextField("owner/repo", text: $repositoryInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(selectedBundleID.isEmpty || normalizedInput == nil)
            }
            validationMessage
        }
    }

    @ViewBuilder
    private var validationMessage: some View {
        if !repositoryInput.isEmpty, normalizedInput == nil {
            Label("Use the form owner/repo, e.g. rxhanson/Rectangle.", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else if let suggestion = GitHubRepositoryMappings.suggestion(for: selectedBundleID),
                  suggestion == normalizedInput {
            Label("Suggested repository for this app.", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func applySuggestion(for bundleID: String) {
        guard repositoryInput.isEmpty, let suggestion = GitHubRepositoryMappings.suggestion(for: bundleID) else { return }
        repositoryInput = suggestion
    }

    private func add() {
        do {
            persist(try mappings.adding(repository: repositoryInput, for: selectedBundleID))
            selectedBundleID = ""
            repositoryInput = ""
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func remove(_ bundleID: String) {
        persist(mappings.removing(bundleIdentifier: bundleID))
    }

    private func persist(_ updated: GitHubRepositoryMappings) {
        do {
            try store.save(updated)
            mappings = updated
            saveError = nil
            onMappingsChange(updated)
        } catch {
            logger.error("Saving GitHub mappings failed: \(error.localizedDescription, privacy: .public)")
            saveError = error.localizedDescription
        }
    }

    private func appName(for bundleID: String) -> String {
        installedApps.first { $0.bundleIdentifier == bundleID }?.name ?? bundleID
    }
}

private struct MappingRow: Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
    let repository: String
}

/// SecureField for the GitHub token; the value is written only to the Keychain.
private struct GitHubTokenField: View {
    let tokenStore: any TokenStoring

    @State private var tokenInput = ""
    @State private var hasToken = false
    @State private var status: String?

    private let logger = Logger(subsystem: "com.macappupdater", category: "GitHubToken")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(hasToken ? String(localized: "Token saved in Keychain") : String(localized: "Personal access token (optional)"), text: $tokenInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(KeychainTokenStore.sanitized(tokenInput) == nil)
                Button("Remove", role: .destructive, action: remove)
                    .disabled(!hasToken)
            }
            Text(status ?? String(localized: "Raises the GitHub API rate limit. A token without any scopes is enough for public repositories."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        do {
            hasToken = try tokenStore.readToken() != nil
        } catch {
            logger.error("Reading GitHub token failed: \(error.localizedDescription, privacy: .public)")
            status = error.localizedDescription
        }
    }

    private func save() {
        run(String(localized: "Token saved.")) { try tokenStore.saveToken(tokenInput) }
    }

    private func remove() {
        run(String(localized: "Token removed.")) { try tokenStore.deleteToken() }
    }

    private func run(_ success: String, _ action: () throws -> Void) {
        do {
            try action()
            tokenInput = ""
            status = success
        } catch {
            logger.error("GitHub token update failed: \(error.localizedDescription, privacy: .public)")
            status = error.localizedDescription
        }
        refresh()
    }
}
