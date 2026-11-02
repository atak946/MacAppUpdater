import MaintenanceCore
import SwiftUI

/// Disk Usage: a TreeSize-style size tree of a folder, largest first, with drill-down.
struct DiskUsageView: View {
    let model: DiskUsageModel
    /// The sidebar search field; filters the folder on screen by name.
    let searchText: String

    @State private var trashCandidate: DiskUsageNode?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            // The hero carries its own headline before the first tree is on screen.
            if model.root != nil || isFailed {
                PageHeader(title: String(localized: "Disk Usage"), subtitle: subtitle) {
                    headerActions
                }
            }
            if let current = model.current, !model.isScanning {
                statsRow(current)
            }
            if let message = model.actionError {
                errorBanner(message).transition(.opacity)
            }
            content
        }
        .padding(Theme.Spacing.page)
        .frame(maxWidth: Theme.Spacing.contentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pageBackground()
        .animation(Theme.Motion.hover, value: model.actionError)
        .confirmationDialog(
            trashTitle, isPresented: isConfirmingTrash, titleVisibility: .visible, presenting: trashCandidate
        ) { node in
            Button("Move to Trash", role: .destructive) {
                Task { await model.moveToTrash(node) }
            }
        } message: { node in
            Text(node.url.path)
        }
    }

    // MARK: Header

    private var subtitle: String {
        String(localized: "See which folders and files take up the most space on your Mac.")
    }

    /// The hero owns the actions until a tree is on screen.
    @ViewBuilder
    private var headerActions: some View {
        if model.root != nil, !model.isScanning {
            HStack(spacing: Theme.Spacing.s) {
                Button {
                    model.chooseFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
                .buttonStyle(.secondary)
                Button {
                    model.scan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.secondary)
            }
        }
    }

    private func statsRow(_ node: DiskUsageNode) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            StatTile(
                value: node.sizeInBytes.formatted(.byteCount(style: .file)), label: String(localized: "Size on disk"),
                symbol: "internaldrive.fill", tint: Theme.Palette.brand
            )
            StatTile(
                value: node.fileCount.formatted(), label: String(localized: "Files"),
                symbol: "doc.fill", tint: Theme.Palette.info
            )
            StatTile(
                value: node.folderCount.formatted(), label: String(localized: "Folders"),
                symbol: "folder.fill", tint: Theme.Palette.warning
            )
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            IconTile(symbol: "exclamationmark.triangle.fill", tint: Theme.Palette.danger, size: 24)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss") { model.actionError = nil }
                .buttonStyle(.secondary)
                .controlSize(.small)
        }
        .padding(Theme.Spacing.m)
        .surface(.raised, radius: Theme.Radius.m)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            hero(.idle)
        case .scanning(let progress):
            hero(.scanning(progress))
        case .failed(let message):
            EmptyStateView(
                symbol: "exclamationmark.triangle.fill", tint: Theme.Palette.danger,
                title: String(localized: "The scan failed"), message: message,
                actionTitle: String(localized: "Try Again"), action: { model.scan() }
            )
            .surface(.raised)
        case .loaded:
            if let current = model.current { listCard(current) }
        }
    }

    private func hero(_ phase: DiskUsageScanHero.Phase) -> some View {
        DiskUsageScanHero(
            phase: phase,
            rootName: model.scanRoot.lastPathComponent,
            onScanHome: { model.scan(FileManager.default.homeDirectoryForCurrentUser) },
            onChooseFolder: model.chooseFolder,
            onCancel: model.cancelScan
        )
    }

    private func listCard(_ current: DiskUsageNode) -> some View {
        let children = filtered(current.children)
        return VStack(spacing: 0) {
            DiskUsageBreadcrumb(
                trail: model.trail,
                isRescanning: model.isRescanning(current),
                onSelect: model.goTo(index:),
                onUp: model.goUp,
                onRescan: { Task { await model.rescan(current) } }
            )
            GlassDivider()
            if children.isEmpty {
                EmptyStateView(
                    symbol: "line.3.horizontal.decrease.circle",
                    title: String(localized: "Nothing to show"),
                    message: searchText.isEmpty
                        ? String(localized: "This folder is empty or could not be read.")
                        : String(localized: "Try another search term.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let firstID = children.first?.id
                        ForEach(children) { node in
                            VStack(spacing: 0) {
                                if node.id != firstID {
                                    GlassDivider(leadingInset: DiskUsageStyle.dividerInset)
                                        .padding(.trailing, Theme.Spacing.m)
                                }
                                row(node, parentSize: current.sizeInBytes)
                            }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .surface(.raised)
    }

    private func row(_ node: DiskUsageNode, parentSize: Int64) -> some View {
        DiskUsageRow(
            node: node,
            icon: node.kind == .smallFiles ? nil : model.icon(for: node),
            share: parentSize > 0 ? Double(node.sizeInBytes) / Double(parentSize) : 0,
            isRescanning: model.isRescanning(node),
            onOpen: { model.open(node) }
        )
        .contextMenu { menu(for: node) }
    }

    @ViewBuilder
    private func menu(for node: DiskUsageNode) -> some View {
        if node.kind != .smallFiles {
            if node.isFolder, !node.children.isEmpty {
                Button("Open", systemImage: "arrow.right.circle") { model.open(node) }
            }
            if node.isFolder {
                Button("Rescan This Folder", systemImage: "arrow.clockwise") {
                    Task { await model.rescan(node) }
                }
                .disabled(model.isRescanning(node))
            }
            Button("Reveal in Finder", systemImage: "folder") { model.reveal(node) }
            Button("Copy Path", systemImage: "doc.on.doc") { model.copyPath(node) }
            Divider()
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { trashCandidate = node }
        } else {
            Button("Reveal Folder in Finder", systemImage: "folder") { model.openInFinder(node) }
        }
    }

    // MARK: Data

    private func filtered(_ nodes: [DiskUsageNode]) -> [DiskUsageNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nodes }
        return nodes.filter { $0.kind != .smallFiles && $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var isFailed: Bool {
        if case .failed = model.state { return true }
        return false
    }

    private var isConfirmingTrash: Binding<Bool> {
        Binding(get: { trashCandidate != nil }, set: { if !$0 { trashCandidate = nil } })
    }

    private var trashTitle: String {
        guard let node = trashCandidate else { return "" }
        return String(localized: "Move “\(node.name)” (\(node.sizeInBytes.formatted(.byteCount(style: .file)))) to the Trash?")
    }
}
