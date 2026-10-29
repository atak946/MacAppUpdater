import AppKit
import AppUpdaterCore
import SwiftUI

/// Apps from an imported list that are not on this Mac, with ways to install them by hand.
///
/// Nothing is installed from here: commands are copied for Terminal (built only from validated
/// cask tokens) and App Store entries open their store page.
struct MigrationImportSheet: View {
    let result: MigrationModel.ImportResult

    @Environment(\.dismiss) private var dismiss
    @State private var copiedCommand: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
            Divider()
            if result.missing.isEmpty {
                ContentUnavailableView(
                    "Everything is installed",
                    systemImage: "checkmark.circle",
                    description: Text("Every app in the list is already on this Mac.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(result.missing) { entry in
                    MigrationEntryRow(entry: entry)
                }
                .listStyle(.inset)
            }
            Divider()
            footer.padding(12)
        }
        .frame(width: 560, height: 480)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Missing Apps").font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var summary: String {
        let total = result.manifest.apps.count
        let missing = result.missing.count
        return String(localized: "\(missing) of \(total) apps in \(result.fileURL.lastPathComponent) are not on this Mac.")
    }

    private var footer: some View {
        HStack {
            Button("Show File in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
            }
            Spacer()
            if let command = result.caskInstallCommand {
                copyButton(String(localized: "Copy Install Command"), command: command)
                    .help(command)
            }
            copyButton(String(localized: "Copy brew bundle Command"), command: result.bundleCommand)
                .help(result.bundleCommand)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func copyButton(_ title: String, command: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copiedCommand = command
        } label: {
            if copiedCommand == command {
                Label("Copied", systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// One missing app: name, how it can be installed and, for App Store apps, a store link.
private struct MigrationEntryRow: View {
    let entry: MigrationEntry

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let url = MigrationCommands.appStoreURL(for: entry) {
                Button("Open in App Store") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
            }
            StatusPill(title: kindTitle, symbol: kindSymbol, tint: kindTint)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        if let token = entry.caskToken { return "brew install --cask \(token)" }
        if let id = entry.appStoreID { return "id\(id)" }
        return entry.bundleIdentifier ?? "—"
    }

    private var kindTitle: String {
        if entry.caskToken != nil { return String(localized: "Homebrew") }
        if entry.source == .appStore { return String(localized: "App Store") }
        return String(localized: "Manual")
    }

    private var kindSymbol: String {
        if entry.caskToken != nil { return "shippingbox" }
        return entry.source == .appStore ? "bag" : "hand.raised"
    }

    private var kindTint: Color {
        if entry.caskToken != nil { return Theme.Palette.brand }
        return entry.source == .appStore ? Theme.Palette.info : Theme.Palette.textSecondary
    }
}
