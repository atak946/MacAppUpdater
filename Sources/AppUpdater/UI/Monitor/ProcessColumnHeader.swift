import SwiftUI

/// Sortable column titles aligned with `ProcessGroupRow`; click to sort, click again to flip the direction.
struct ProcessColumnHeader: View {
    let sort: ProcessSortOrder
    let onSort: (ProcessSortKey) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.s) {
                column(.name)
                Text(verbatim: "·").foregroundStyle(Theme.Palette.textTertiary.opacity(0.6))
                column(.pid)
            }
            .padding(.leading, ProcessListMetrics.chevron + ProcessListMetrics.icon + Theme.Spacing.m * 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            column(.ports).frame(width: ProcessListMetrics.ports, alignment: .leading)
            column(.cpu).frame(width: ProcessListMetrics.cpu, alignment: .trailing)
            column(.memory).frame(width: ProcessListMetrics.memory, alignment: .trailing)
            column(.threads).frame(width: ProcessListMetrics.threads, alignment: .trailing)
            Text("Kind")
                .modifier(ColumnTitleStyle(isActive: false))
                .frame(width: ProcessListMetrics.kind, alignment: .leading)
            Color.clear.frame(width: ProcessListMetrics.actions, height: 1)
        }
        .padding(.horizontal, ProcessListMetrics.rowHorizontal)
        .padding(.vertical, Theme.Spacing.s)
    }

    private func column(_ key: ProcessSortKey) -> some View {
        SortColumnButton(
            title: key.columnTitle,
            helpTitle: key.title,
            isActive: sort.key == key,
            ascending: sort.ascending,
            action: { onSort(key) }
        )
    }
}

/// One clickable column title with a direction chevron when active.
private struct SortColumnButton: View {
    let title: String
    let helpTitle: String
    let isActive: Bool
    let ascending: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7.5, weight: .heavy))
                    .opacity(isActive ? 1 : 0)
            }
            .modifier(ColumnTitleStyle(isActive: isActive, isHovered: isHovered))
            .padding(.vertical, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.hover, value: isHovered) // perf-guard: allow (hover/focus/selection state, not sample-driven)
        .help(String(localized: "Sort by \(helpTitle)"))
        .accessibilityLabel(Text("Sort by \(helpTitle)"))
        .accessibilityValue(isActive ? Text(ascending ? "Ascending" : "Descending") : Text(verbatim: ""))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Eyebrow look shared by sortable and static column titles.
private struct ColumnTitleStyle: ViewModifier {
    let isActive: Bool
    var isHovered = false

    func body(content: Content) -> some View {
        content
            .textCase(.uppercase)
            .font(Theme.Typography.eyebrow)
            .tracking(1.2)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private var color: Color {
        if isActive { return Theme.Palette.brandTertiary }
        return isHovered ? Theme.Palette.textSecondary : Theme.Palette.textTertiary
    }
}
