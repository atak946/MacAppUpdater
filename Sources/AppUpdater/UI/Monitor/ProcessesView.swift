import AppKit
import MonitorCore
import SwiftUI

/// Task manager: process groups (apps with their helpers) with live CPU, memory, ports and quit actions.
/// Clicking a row opens `ProcessInspector` on the right. Search: the page field wins while it has text,
/// otherwise the sidebar search (`searchText`) applies; both match name, bundle id, PID and port.
struct ProcessesView: View {
    let model: MonitorModel
    let searchText: String

    @AppStorage("processes.filter") private var filter: ProcessFilter = .apps
    @AppStorage("processes.chips") private var chipsRaw = ""
    @AppStorage("processes.sort") private var sortRaw = ProcessSortOrder.default.rawValue
    @State private var expanded: Set<String> = []
    @State private var pendingForceQuit: ProcessGroup?
    @State private var pageSearch = ""

    private var chips: Set<ProcessChip> { ProcessChip.decode(chipsRaw) }
    private var sort: ProcessSortOrder { ProcessSortOrder(rawValue: sortRaw) }
    private var query: ProcessListQuery {
        ProcessListQuery(
            filter: filter, chips: chips, sort: sort,
            search: ProcessListQuery.effectiveSearch(page: pageSearch, sidebar: searchText)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            PageHeader(title: String(localized: "Processes"), subtitle: subtitle) { EmptyView() }
            ProcessToolbar(
                filter: animatedFilter,
                search: $pageSearch,
                chips: chips,
                counts: model.filterCounts,
                shownCount: model.visibleItems.count,
                isNarrowed: query.isNarrowed,
                onToggleChip: toggle,
                onClear: clearFilters
            )
            HStack(alignment: .top, spacing: Theme.Spacing.l) {
                listCard
                if let selection = model.selection {
                    inspector(selection)
                        .transition(.opacity.combined(with: .offset(x: 16)))
                }
            }
        }
        .padding(Theme.Spacing.page)
        .frame(maxWidth: contentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pageBackground()
        .monitorObservation(model, demand: .ports)
        .onAppear { model.listQuery = query }
        .onChange(of: query) { _, newQuery in model.listQuery = newQuery }
        .onDisappear { model.isOrderFrozen = false }
        .confirmationDialog(
            String(localized: "Force quit \(pendingForceQuit?.name ?? "")?"),
            isPresented: isConfirmingForceQuit,
            titleVisibility: .visible,
            presenting: pendingForceQuit
        ) { group in
            Button(String(localized: "Force Quit"), role: .destructive) {
                Task { await model.terminate(group, mode: .force) }
            }
        } message: { _ in
            Text("Unsaved changes will be lost.")
        }
        .alert(String(localized: "Couldn't quit"), isPresented: hasError) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// The page grows by the inspector width so the list keeps its columns while the panel is open.
    private var contentWidth: CGFloat {
        Theme.Spacing.contentWidth + (model.selection == nil ? 0 : ProcessInspector.width + Theme.Spacing.l)
    }

    // MARK: Inspector

    private func inspector(_ selection: ProcessSelection) -> some View {
        let group = selection.item.group
        return ProcessInspector(
            selection: selection,
            icon: model.icon(for: group),
            canTerminate: selection.isRunning && model.canTerminate(group),
            onClose: { select(nil) },
            onQuit: { Task { await model.terminate(group, mode: .graceful) } },
            onForceQuit: { pendingForceQuit = group }
        )
    }

    private func select(_ groupID: String?) {
        withAnimation(Theme.Motion.content) { model.select(groupID) }
    }

    // MARK: Header

    private var subtitle: String {
        let count = model.processList.count
        guard let snapshot = model.snapshot else { return String(localized: "\(count) processes") }
        let used = MonitorFormat.bytes(snapshot.memory.usedBytes)
        let total = MonitorFormat.bytes(snapshot.memory.totalBytes)
        return String(localized: "\(count) processes · CPU \(MonitorFormat.percent(snapshot.cpuUsage)) · \(used) of \(total)")
    }

    // MARK: Filters

    private var animatedFilter: Binding<ProcessFilter> {
        Binding(get: { filter }, set: { newValue in withAnimation(Theme.Motion.content) { filter = newValue } })
    }

    private func toggle(_ chip: ProcessChip) {
        var next = chips
        if next.contains(chip) { next.remove(chip) } else { next.insert(chip) }
        chipsRaw = ProcessChip.encode(next)
    }

    private func clearFilters() {
        filter = .all
        chipsRaw = ""
    }

    private func sort(by key: ProcessSortKey) {
        sortRaw = sort.toggled(key).rawValue
    }

    // MARK: List

    private var listCard: some View {
        let items = model.visibleItems
        return VStack(spacing: 0) {
            ProcessColumnHeader(sort: sort, onSort: sort(by:))
            GlassDivider()
            if items.isEmpty {
                if model.hasProcessSample {
                    emptyResults
                } else {
                    EmptyStateView(symbol: nil, title: String(localized: "Reading processes…"))
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                GlassDivider(leadingInset: ProcessListMetrics.dividerInset)
                                    .padding(.trailing, Theme.Spacing.m)
                            }
                            groupRows(item)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    .animation(Theme.Motion.content, value: items.map(\.id))
                }
                .scrollIndicators(.automatic)
                // Freeze the row order under the pointer so rows don't move while aiming at them.
                .onHover { model.isOrderFrozen = $0 }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .surface(.raised)
    }

    @ViewBuilder
    private var emptyResults: some View {
        if query.isNarrowed {
            EmptyStateView(
                symbol: "line.3.horizontal.decrease.circle",
                title: String(localized: "No processes match"),
                message: String(localized: "Filters hide every process. Clear them or try another search term."),
                actionTitle: String(localized: "Clear filters"),
                action: clearFilters
            )
        } else {
            EmptyStateView(
                symbol: "magnifyingglass",
                title: String(localized: "No processes match"),
                message: String(localized: "Try another search term.")
            )
        }
    }

    @ViewBuilder
    private func groupRows(_ item: ProcessListItem) -> some View {
        let group = item.group
        let isExpanded = expanded.contains(group.id)
        ProcessGroupRow(
            item: item,
            icon: model.icon(for: group),
            isExpanded: isExpanded,
            isSelected: model.selection?.groupID == group.id,
            canTerminate: model.canTerminate(group),
            onToggle: { toggle(group) },
            onSelect: { select(model.selection?.groupID == group.id ? nil : group.id) },
            onQuit: { Task { await model.terminate(group, mode: .graceful) } },
            onForceQuit: { pendingForceQuit = group }
        )
        .contextMenu { menu(for: group) }
        if isExpanded, item.members.count > 1 {
            ForEach(item.members) { process in
                ProcessMemberRow(process: process)
                    .contextMenu { memberMenu(for: process) }
            }
            .transition(.opacity)
        }
    }

    private func toggle(_ group: ProcessGroup) {
        withAnimation(Theme.Motion.content) {
            if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func menu(for group: ProcessGroup) -> some View {
        if model.canTerminate(group) {
            Button("Quit", systemImage: "xmark.circle") { Task { await model.terminate(group, mode: .graceful) } }
            Button("Force Quit…", systemImage: "bolt.circle") { pendingForceQuit = group }
            Divider()
        }
        Button("Show Details", systemImage: "sidebar.right") { select(group.id) }
        if let url = ProcessActions.revealURL(for: group) {
            Button("Show in Finder", systemImage: "folder") { ProcessActions.reveal(url) }
        }
        if let main = group.processes.first {
            Button("Copy PID", systemImage: "doc.on.doc") { ProcessActions.copy(String(main.pid)) }
        }
        if let bundleID = group.bundleIdentifier {
            Button("Copy Bundle Identifier", systemImage: "doc.on.doc") { ProcessActions.copy(bundleID) }
        }
    }

    @ViewBuilder
    private func memberMenu(for process: ProcessSnapshot) -> some View {
        if model.canTerminate(process) {
            Button("Quit", systemImage: "xmark.circle") { Task { await model.terminate(process, mode: .graceful) } }
            Button("Force Quit", systemImage: "bolt.circle") { Task { await model.terminate(process, mode: .force) } }
            Divider()
        }
        Button("Copy PID", systemImage: "doc.on.doc") { ProcessActions.copy(String(process.pid)) }
    }

    // MARK: Bindings

    private var isConfirmingForceQuit: Binding<Bool> {
        Binding(get: { pendingForceQuit != nil }, set: { if !$0 { pendingForceQuit = nil } })
    }

    private var hasError: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}
