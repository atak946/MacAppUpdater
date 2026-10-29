import AppKit
import MonitorCore
import SwiftUI

/// Right-side detail panel of the Processes page for the selected group: identity, live stats with
/// sparklines, members, ports, paths and quit actions. Every value comes precomputed from `ProcessSelection`.
struct ProcessInspector: View {
    static let width: CGFloat = 340

    let selection: ProcessSelection
    let icon: NSImage?
    let canTerminate: Bool
    let onClose: () -> Void
    let onQuit: () -> Void
    let onForceQuit: () -> Void

    private var item: ProcessListItem { selection.item }
    private var group: ProcessGroup { item.group }
    private var main: ProcessSnapshot? { group.processes.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            GlassDivider()
            if selection.isRunning {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                        stats
                        actions
                        membersSection
                        portsSection
                        detailsSection
                    }
                    .padding(Theme.Spacing.l)
                }
                .scrollIndicators(.automatic)
            } else {
                EmptyStateView(
                    symbol: "xmark.octagon",
                    tint: Theme.Palette.textTertiary,
                    title: String(localized: "This process has ended"),
                    message: String(localized: "It quit or was terminated. Pick another process from the list."),
                    actionTitle: String(localized: "Close"),
                    action: onClose
                )
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .surface(.elevated)
        // Esc closes the panel; scoped to the panel's lifetime so it never shadows other screens.
        .background(
            Button("Close details", action: onClose)
                .keyboardShortcut(.cancelAction)
                .hidden()
                .accessibilityHidden(true)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            ProcessIcon(image: icon, kind: group.kind, size: 52)
                .opacity(selection.isRunning ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                if let bundleID = group.bundleIdentifier {
                    Text(verbatim: bundleID)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack(spacing: Theme.Spacing.xs) {
                    ProcessKindPill(kind: group.kind, showsUser: true)
                    if !selection.isRunning {
                        StatusPill(title: String(localized: "Ended"), symbol: "stop.fill", tint: Theme.Palette.danger)
                    }
                }
                if let summary {
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .help(String(localized: "Close details"))
        }
        .padding(Theme.Spacing.l)
    }

    /// Catalog description of the main process, localized through the string catalog.
    private var summary: String? {
        guard let main, let info = KnownProcessCatalog.info(forProcessNamed: main.name) else { return nil }
        return String(localized: String.LocalizationValue(info.summary))
    }

    // MARK: Stats

    private var stats: some View {
        Grid(horizontalSpacing: Theme.Spacing.s, verticalSpacing: Theme.Spacing.s) {
            GridRow {
                InspectorStatTile(title: String(localized: "CPU"), value: MonitorFormat.cpu(item.cpuPercent),
                                  symbol: "cpu", tint: cpuTint(item.cpuPercent / ProcessListMetrics.cpuBarScale),
                                  history: selection.cpuHistory)
                InspectorStatTile(title: String(localized: "Memory"), value: MonitorFormat.bytes(item.memoryBytes),
                                  symbol: "memorychip", tint: Theme.Palette.brand, history: selection.memoryHistory)
            }
            GridRow {
                InspectorStatTile(title: String(localized: "Threads"), value: "\(item.threadCount)",
                                  symbol: "point.3.connected.trianglepath.dotted", tint: Theme.Palette.info)
                InspectorStatTile(title: String(localized: "Processes"), value: "\(item.members.count)",
                                  symbol: "square.stack.3d.up", tint: Theme.Palette.info)
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Button("Quit", systemImage: "xmark.circle", action: onQuit)
                    .buttonStyle(.secondary)
                Button("Force Quit…", systemImage: "bolt.fill", action: onForceQuit)
                    .buttonStyle(.secondary(tint: Theme.Palette.danger))
            }
            .controlSize(.small)
            .disabled(!canTerminate)
            // On the container: macOS shows no tooltip on a disabled button itself.
            .help(canTerminate ? "" : String(localized: "Protected by macOS: quitting it would destabilize your Mac."))
            Spacer(minLength: 0)
            if let url = ProcessActions.revealURL(for: group) {
                Button { ProcessActions.reveal(url) } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle())
                    .help(String(localized: "Reveal in Finder"))
            }
            if let main {
                Button { ProcessActions.copy(String(main.pid)) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(IconButtonStyle())
                    .help(String(localized: "Copy PID"))
            }
        }
    }

    // MARK: Sections

    private var membersSection: some View {
        InspectorSection(title: String(localized: "Processes")) {
            InspectorMembersTable(members: item.members)
        }
    }

    @ViewBuilder
    private var portsSection: some View {
        if !selection.ports.isEmpty {
            InspectorSection(title: String(localized: "Listening ports")) {
                InspectorPortChips(ports: selection.ports)
            }
        }
    }

    private var detailsSection: some View {
        InspectorSection(title: String(localized: "Details")) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if let main {
                    InspectorInfoRow(label: String(localized: "PID"), value: "\(main.pid)")
                    InspectorInfoRow(label: String(localized: "Parent PID"), value: "\(main.parentPID)")
                    InspectorInfoRow(label: String(localized: "User"), value: UserNames.name(for: main.userID))
                    if let start = main.startDate {
                        InspectorInfoRow(label: String(localized: "Started"),
                                         value: start.formatted(date: .abbreviated, time: .shortened))
                        InspectorInfoRow(label: String(localized: "Uptime"),
                                         value: MonitorFormat.duration(Date().timeIntervalSince(start)))
                    }
                    if let path = main.executablePath {
                        InspectorPathRow(label: String(localized: "Executable"), path: path)
                    }
                }
                if let bundleURL = group.bundleURL {
                    InspectorPathRow(label: String(localized: "Bundle"), path: bundleURL.path)
                }
            }
            .padding(Theme.Spacing.s + 2)
            .surface(.inset, radius: Theme.Radius.m)
        }
    }
}
