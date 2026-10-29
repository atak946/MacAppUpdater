import AppKit
import MonitorCore
import SwiftUI

// MARK: - Actions

/// Finder and pasteboard helpers shared by the Processes list menus and the inspector.
@MainActor
enum ProcessActions {
    /// Bundle for apps, executable otherwise.
    static func revealURL(for group: ProcessGroup) -> URL? {
        if let bundleURL = group.bundleURL { return bundleURL }
        return group.processes.first?.executablePath.map { URL(fileURLWithPath: $0) }
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Short user names for uids, cached because `getpwuid` touches Directory Services.
@MainActor
enum UserNames {
    private static var cache: [UInt32: String] = [:]

    static func name(for uid: UInt32) -> String {
        if let cached = cache[uid] { return cached }
        let name = getpwuid(uid).flatMap { String(validatingCString: $0.pointee.pw_name) } ?? "\(uid)"
        cache[uid] = name
        return name
    }
}

// MARK: - Section chrome

/// Eyebrow title over a group of inspector content.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title.uppercased())
                .font(Theme.Typography.eyebrow)
                .tracking(1.4)
                .foregroundStyle(Theme.Palette.textTertiary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Stats

/// Live value tile with an optional 60-sample sparkline.
struct InspectorStatTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var history: SampleHistory?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(value)
                .font(Theme.Typography.numeral(18))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let history {
                GlowAreaChart(
                    series: [ChartSeries(id: title, values: history.values, tint: tint)],
                    capacity: ProcessSelection.historyCapacity
                )
                .frame(height: 30)
            }
        }
        .padding(Theme.Spacing.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.inset, radius: Theme.Radius.m)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Members

/// Compact pid / name / CPU / memory / user table of a group's processes.
struct InspectorMembersTable: View {
    let members: [ProcessSnapshot]

    private enum Width {
        static let pid: CGFloat = 50
        static let cpu: CGFloat = 50
        static let memory: CGFloat = 62
        static let user: CGFloat = 58
    }

    var body: some View {
        VStack(spacing: 0) {
            row(pid: String(localized: "PID"), name: String(localized: "Name"), cpu: String(localized: "CPU"),
                memory: String(localized: "Memory"), user: String(localized: "User"), isHeader: true)
            GlassDivider()
            ForEach(members) { process in
                row(pid: "\(process.pid)", name: process.name, cpu: MonitorFormat.cpu(process.cpuPercent),
                    memory: MonitorFormat.bytes(process.memoryBytes), user: UserNames.name(for: process.userID),
                    isHeader: false)
            }
        }
        .surface(.inset, radius: Theme.Radius.m)
    }

    private func row(pid: String, name: String, cpu: String, memory: String, user: String, isHeader: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xs + 2) {
            Text(verbatim: pid).frame(width: Width.pid, alignment: .leading)
            Text(verbatim: name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: cpu).frame(width: Width.cpu, alignment: .trailing)
            Text(verbatim: memory).frame(width: Width.memory, alignment: .trailing)
            Text(verbatim: user).lineLimit(1).frame(width: Width.user, alignment: .leading)
        }
        .font(isHeader ? .system(size: 10, weight: .bold) : .system(size: 11).monospacedDigit())
        .foregroundStyle(isHeader ? Theme.Palette.textTertiary : Theme.Palette.textSecondary)
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, isHeader ? 6 : 4)
    }
}

// MARK: - Ports

/// ":3000 TCP" chips for every listening socket of the group.
struct InspectorPortChips: View {
    let ports: [ListeningPort]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(ports) { port in
                HStack(spacing: 4) {
                    Text(verbatim: ":\(port.port)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text(verbatim: port.transport).font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.Palette.brandTertiary.opacity(0.7))
                }
                .foregroundStyle(Theme.Palette.brandTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.Palette.brandTertiary.opacity(0.14)))
                .overlay(Capsule().strokeBorder(Theme.Palette.brandTertiary.opacity(0.3), lineWidth: 0.5))
                .help(String(localized: "Listening on \(port.address) (PID \(Int(port.pid)))"))
            }
        }
    }
}

// MARK: - Info rows

/// Label and value on one line, value right aligned and selectable.
struct InspectorInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.Palette.textTertiary)
            Spacer(minLength: Theme.Spacing.s)
            Text(verbatim: value)
                .foregroundStyle(Theme.Palette.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .font(.system(size: 11.5, weight: .medium))
    }
}

/// A file path over two lines with a Reveal in Finder button.
struct InspectorPathRow: View {
    let label: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer(minLength: Theme.Spacing.s)
                Button { ProcessActions.reveal(URL(fileURLWithPath: path)) } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(IconButtonStyle())
                .help(String(localized: "Reveal in Finder"))
            }
            Text(verbatim: path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
