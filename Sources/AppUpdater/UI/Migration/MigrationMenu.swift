import AppKit
import AppUpdaterCore
import SwiftUI
import UniformTypeIdentifiers

/// All Apps toolbar menu: export the app list for a new Mac, or import one to see what is missing.
struct MigrationMenu: View {
    let model: MigrationModel
    /// Every scanned app, not just the filtered ones on screen.
    let installedApps: [InstalledApp]

    var body: some View {
        Menu {
            Button("Export as Brewfile…", systemImage: "shippingbox") { export(.brewfile) }
            Button("Export as JSON…", systemImage: "curlybraces") { export(.json) }
            Divider()
            Button("Import App List…", systemImage: "square.and.arrow.down") { importList() }
        } label: {
            if model.isWorking {
                Label { Text("Migrate") } icon: { ProgressView().controlSize(.small) }
            } else {
                Label("Migrate", systemImage: "arrow.right.arrow.left")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.secondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isWorking)
        .help("Export or import the app list to set up a new Mac")
        .sheet(item: Bindable(model).importResult) { result in
            MigrationImportSheet(result: result)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func export(_ format: MigrationModel.ExportFormat) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export App List")
        panel.nameFieldStringValue = format.defaultFileName
        panel.canCreateDirectories = true
        if format == .json { panel.allowedContentTypes = [.json] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.export(installedApps, as: format, to: url) }
    }

    /// Brewfiles usually have no extension, so any file can be picked; the content decides.
    private func importList() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import App List")
        panel.message = String(localized: "Choose a Brewfile or an App Updater JSON export.")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importList(from: url, installed: installedApps) }
    }
}
