import MaintenanceCore
import SwiftUI

/// The items of one removed app: everything named after the same bundle identifier.
struct CleanupOwnerSection: Identifiable, Equatable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let items: [CleanupItem]
    var totalSize: Int64 { items.reduce(0) { $0 + $1.sizeInBytes } }

    /// Sections ordered by total size (largest first); items keep their order. Items without an
    /// owner are grouped under their own name so nothing is hidden.
    static func sections(of items: [CleanupItem]) -> [CleanupOwnerSection] {
        let grouped = Dictionary(grouping: items) { $0.ownerBundleIdentifier ?? $0.displayName }
        let order = items.map { $0.ownerBundleIdentifier ?? $0.displayName }
        var seen = Set<String>()
        return order.filter { seen.insert($0).inserted }
            .map { CleanupOwnerSection(bundleIdentifier: $0, items: grouped[$0] ?? []) }
            .sorted { lhs, rhs in
                lhs.totalSize != rhs.totalSize ? lhs.totalSize > rhs.totalSize : lhs.bundleIdentifier < rhs.bundleIdentifier
            }
    }
}

/// Expanded body of the removed-app leftovers card: one section per bundle identifier.
struct CleanupOwnerSectionList: View {
    let group: CleanupGroup
    let model: CleanupModel

    @State private var showsAll = false

    /// Sections shown before "Show all N".
    private static let collapsedLimit = 5

    var body: some View {
        let sections = CleanupOwnerSection.sections(of: group.items)
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(showsAll ? sections[...] : sections.prefix(Self.collapsedLimit)) { section in
                VStack(spacing: 0) {
                    CleanupOwnerHeader(section: section, model: model, tint: group.category.tint)
                    ForEach(section.items) { item in
                        CleanupItemRow(item: item, isSelected: model.isSelected(item), tint: group.category.tint) {
                            model.toggle(item)
                        }
                        .padding(.leading, Theme.Spacing.l)
                    }
                }
            }
            if !showsAll, sections.count > Self.collapsedLimit {
                Button {
                    withAnimation(Theme.Motion.content) { showsAll = true }
                } label: {
                    Label("Show all \(sections.count)", systemImage: "chevron.down")
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .padding(.top, Theme.Spacing.s)
            }
        }
    }
}

/// Bundle identifier, item count, total size and a tri-state checkbox for one removed app.
private struct CleanupOwnerHeader: View {
    let section: CleanupOwnerSection
    let model: CleanupModel
    let tint: Color

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            CleanupCheckbox(state: model.selectionState(of: section.items), tint: tint) {
                model.toggleItems(section.items)
            }
            .accessibilityLabel(Text("Select all leftovers of \(section.bundleIdentifier)"))
            Text(section.bundleIdentifier)
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(section.items.count) items")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer(minLength: Theme.Spacing.m)
            Text(CleanupFormat.bytes(section.totalSize))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
    }
}
