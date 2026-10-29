import MonitorCore
import SwiftUI

/// Column widths shared by the header and the rows.
enum ProcessListMetrics {
    static let chevron: CGFloat = 14
    static let icon: CGFloat = 26
    static let ports: CGFloat = 104
    static let cpu: CGFloat = 88
    static let memory: CGFloat = 76
    static let threads: CGFloat = 58
    static let kind: CGFloat = 72
    static let pid: CGFloat = 52
    static let actions: CGFloat = 60
    static let rowHorizontal: CGFloat = Theme.Spacing.l
    static let dividerInset: CGFloat = rowHorizontal + chevron + icon + Theme.Spacing.m * 2
    /// CPU bar is full at one fully used core.
    static let cpuBarScale: Double = 100
}

/// One app or standalone process: icon, name, subtitle, ports, CPU meter, memory, kind and hover actions.
/// Clicking the row selects it (opens the inspector); the chevron expands member processes inline.
struct ProcessGroupRow: View {
    let item: ProcessListItem
    let icon: NSImage?
    let isExpanded: Bool
    let isSelected: Bool
    let canTerminate: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onQuit: () -> Void
    let onForceQuit: () -> Void

    @State private var isHovered = false

    private var group: ProcessGroup { item.group }
    private var isExpandable: Bool { item.members.count > 1 }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            chevron
            ProcessIcon(image: icon, kind: group.kind, size: ProcessListMetrics.icon)
            nameColumn.frame(maxWidth: .infinity, alignment: .leading)
            PortChips(ports: item.ports).frame(width: ProcessListMetrics.ports, alignment: .leading)
            CPUCell(percent: item.cpuPercent).frame(width: ProcessListMetrics.cpu)
            Text(MonitorFormat.bytes(item.memoryBytes))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: ProcessListMetrics.memory, alignment: .trailing)
            ThreadCell(count: item.threadCount, size: 12)
            // The pill is empty for user processes; the fixed spacer keeps the column in place.
            Color.clear
                .frame(width: ProcessListMetrics.kind, height: 1)
                .overlay(alignment: .leading) { ProcessKindPill(kind: group.kind).fixedSize() }
            actions.frame(width: ProcessListMetrics.actions, alignment: .trailing)
        }
        .padding(.horizontal, ProcessListMetrics.rowHorizontal - Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.s)
        .hoverHighlight(isHovered && !isSelected, radius: Theme.Radius.m)
        .background(selectionBackground)
        .padding(.horizontal, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onSelect)
        .animation(Theme.Motion.hover, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Show details"), onSelect)
        .accessibilityAction(named: Text("Quit"), onQuit)
    }

    private var chevron: some View {
        Button(action: onToggle) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Palette.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: ProcessListMetrics.chevron, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isExpandable ? 1 : 0)
        .disabled(!isExpandable)
        .help(isExpanded ? String(localized: "Hide processes") : String(localized: "Show processes"))
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .fill(Theme.Palette.selectionFill)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                        .strokeBorder(Theme.Palette.brandTertiary.opacity(0.45), lineWidth: 1)
                )
                .transition(.opacity)
        }
    }

    private var nameColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(group.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            Text(item.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button(action: onQuit) { Image(systemName: "xmark") }
                .help(canTerminate ? String(localized: "Quit") : protectedHelp)
            Button(action: onForceQuit) { Image(systemName: "bolt.fill") }
                .help(canTerminate ? String(localized: "Force Quit…") : protectedHelp)
        }
        .buttonStyle(IconButtonStyle())
        .disabled(!canTerminate)
        .opacity(isHovered ? 1 : 0)
        .animation(Theme.Motion.hover, value: isHovered)
    }

    private var protectedHelp: String {
        String(localized: "Protected by macOS: quitting it would destabilize your Mac.")
    }
}

/// System / Critical capsule; user processes show nothing unless `showsUser` is set.
struct ProcessKindPill: View {
    let kind: ProcessKind
    var showsUser = false

    var body: some View {
        switch kind {
        case .user:
            if showsUser { StatusPill(title: String(localized: "User"), symbol: "person.fill", tint: Theme.Palette.brandTertiary) }
        case .system: StatusPill(title: String(localized: "System"), symbol: "gearshape.fill", tint: Theme.Palette.info)
        case .critical: StatusPill(title: String(localized: "Critical"), symbol: "lock.fill", tint: Theme.Palette.warning)
        }
    }
}

/// A member process inside an expanded group.
struct ProcessMemberRow: View {
    let process: ProcessSnapshot

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Text(verbatim: "\(process.pid)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: ProcessListMetrics.pid, alignment: .leading)
            Text(process.name)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            CPUCell(percent: process.cpuPercent).frame(width: ProcessListMetrics.cpu)
            Text(MonitorFormat.bytes(process.memoryBytes))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: ProcessListMetrics.memory, alignment: .trailing)
            ThreadCell(count: process.threadCount, size: 11.5)
            Color.clear.frame(width: ProcessListMetrics.kind + ProcessListMetrics.actions + Theme.Spacing.m, height: 1)
        }
        .padding(.leading, ProcessListMetrics.dividerInset - Theme.Spacing.xs)
        .padding(.trailing, ProcessListMetrics.rowHorizontal - Theme.Spacing.xs)
        .padding(.vertical, 5)
        .hoverHighlight(isHovered, radius: Theme.Radius.s)
        .padding(.horizontal, Theme.Spacing.xs)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// Thread count, right aligned under the Threads column.
private struct ThreadCell: View {
    let count: Int
    let size: CGFloat

    var body: some View {
        Text(verbatim: "\(count)")
            .font(.system(size: size).monospacedDigit())
            .foregroundStyle(Theme.Palette.textTertiary)
            .frame(width: ProcessListMetrics.threads, alignment: .trailing)
    }
}

/// CPU percent over a tiny glowing meter.
private struct CPUCell: View {
    let percent: Double

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(MonitorFormat.cpu(percent))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(percent >= 1 ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
            UsageBar(
                fraction: percent / ProcessListMetrics.cpuBarScale,
                tint: cpuTint(percent / ProcessListMetrics.cpuBarScale),
                height: 3
            )
            .frame(width: 56)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// ":3000" style chips for listening ports; at most two, then "+n".
private struct PortChips: View {
    let ports: [UInt16]

    private static let maxVisible = 2

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ports.prefix(Self.maxVisible), id: \.self) { port in
                chip(":\(port)")
            }
            if ports.count > Self.maxVisible {
                chip("+\(ports.count - Self.maxVisible)")
                    .help(ports.map { ":\($0)" }.joined(separator: " "))
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.Palette.brandTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.Palette.brandTertiary.opacity(0.14)))
            .overlay(Capsule().strokeBorder(Theme.Palette.brandTertiary.opacity(0.3), lineWidth: 0.5))
            .fixedSize()
    }
}
