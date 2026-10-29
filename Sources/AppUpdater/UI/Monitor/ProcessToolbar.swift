import SwiftUI

/// Toolbar under the Processes header: category capsule, search field, narrowing chips,
/// result count and "Clear filters".
struct ProcessToolbar: View {
    @Binding var filter: ProcessFilter
    @Binding var search: String
    let chips: Set<ProcessChip>
    let counts: [ProcessFilter: Int]
    let shownCount: Int
    let isNarrowed: Bool
    let onToggleChip: (ProcessChip) -> Void
    let onClear: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.m) {
                capsule
                chipRow
                Spacer(minLength: Theme.Spacing.s)
                searchField
                summary
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: Theme.Spacing.m) {
                    capsule
                    Spacer(minLength: Theme.Spacing.s)
                    searchField
                }
                chipsAndSummary
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                searchField
                capsule
                chipsAndSummary
            }
        }
    }

    private var searchField: some View {
        ProcessSearchField(text: $search)
    }

    private var chipsAndSummary: some View {
        HStack(spacing: Theme.Spacing.m) {
            chipRow
            Spacer(minLength: Theme.Spacing.s)
            summary
        }
    }

    private var capsule: some View {
        MonitorFilterCapsule(selection: $filter) { counts[$0] ?? 0 }
    }

    private var chipRow: some View {
        HStack(spacing: Theme.Spacing.xs + 2) {
            ForEach(ProcessChip.allCases) { chip in
                FilterChip(chip: chip, isOn: chips.contains(chip)) { onToggleChip(chip) }
            }
        }
        .fixedSize()
    }

    private var summary: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text("\(shownCount) shown")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.Palette.textTertiary)
            if isNarrowed {
                Button("Clear filters", systemImage: "xmark.circle.fill", action: onClear)
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .transition(.opacity)
            }
        }
        .fixedSize()
        .animation(Theme.Motion.hover, value: isNarrowed)
    }
}

/// Toggleable glass capsule; lit with the cyan accent while on.
private struct FilterChip: View {
    let chip: ProcessChip
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark" : chip.symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .frame(width: 11)
                Text(chip.title)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(isOn ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(stroke, lineWidth: isOn ? 1 : 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.hover, value: isHovered)
        .animation(Theme.Motion.hover, value: isOn)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if isOn { return Theme.Palette.brandTertiary.opacity(0.22) }
        return isHovered ? Theme.Palette.pressedFill : Theme.Palette.hoverFill
    }

    private var stroke: Color {
        isOn ? Theme.Palette.brandTertiary.opacity(0.6) : Theme.Palette.hairline
    }
}
