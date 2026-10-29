import MaintenanceCore
import SwiftUI

// MARK: - Kind

extension StartupItemKind {
    var title: String {
        switch self {
        case .userAgent: String(localized: "User Agent")
        case .globalAgent: String(localized: "Global Agent")
        case .daemon: String(localized: "Daemon")
        }
    }

    var symbol: String {
        switch self {
        case .userAgent: "person.fill"
        case .globalAgent: "person.2.fill"
        case .daemon: "gearshape.2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .userAgent: Theme.Palette.info
        case .globalAgent: Theme.Palette.brand
        case .daemon: Theme.Palette.brandSecondary
        }
    }
}

// MARK: - Item text

extension StartupItem {
    /// App name, else the last label component ("com.vendor.updater" → "updater").
    var displayName: String {
        appName ?? label.split(separator: ".").last.map(String.init) ?? label
    }

    /// When launchd starts the job, e.g. "At login · Kept alive · Every 1 hr".
    var triggerDescription: String {
        var parts: [String] = []
        if runAtLoad { parts.append(String(localized: "At login")) }
        if keepAlive { parts.append(String(localized: "Kept alive")) }
        switch schedule {
        case .interval(let seconds):
            let formatted = Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated))
            parts.append(String(localized: "Every \(formatted)"))
        case .calendar:
            parts.append(String(localized: "On a schedule"))
        case nil:
            break
        }
        return parts.isEmpty ? String(localized: "On demand") : parts.joined(separator: " · ")
    }

    var matchesSearchFields: [String] {
        [label, appName ?? "", executableURL?.path ?? ""]
    }
}

// MARK: - Signer pill

/// Apple / Team ID / Unsigned capsule for a job's executable.
struct StartupSignerPill: View {
    let item: StartupItem

    var body: some View {
        if let signature = item.signature {
            if signature.isApple {
                StatusPill(title: String(localized: "Apple"), symbol: "apple.logo", tint: Theme.Palette.textSecondary)
                    .help(signature.signerName ?? "")
            } else if signature.isSigned {
                StatusPill(title: signature.teamID ?? String(localized: "Signed"), symbol: "checkmark.seal.fill", tint: Theme.Palette.success)
                    .monospaced()
                    .help(signature.signerName ?? "")
            } else {
                StatusPill(title: String(localized: "Unsigned"), symbol: "exclamationmark.triangle.fill", tint: Theme.Palette.danger)
                    .help(String(localized: "No developer signature (unsigned or ad-hoc signed)."))
            }
        } else {
            StatusPill(title: String(localized: "Missing"), symbol: "questionmark.circle", tint: Theme.Palette.warning)
                .help(String(localized: "The executable could not be found or inspected."))
        }
    }
}

// MARK: - Filter & sort

enum StartupFilter: CaseIterable, Identifiable {
    case all, agents, daemons, disabled, unsigned

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .agents: String(localized: "Agents")
        case .daemons: String(localized: "Daemons")
        case .disabled: String(localized: "Disabled")
        case .unsigned: String(localized: "Unsigned")
        }
    }

    func matches(_ item: StartupItem) -> Bool {
        switch self {
        case .all: true
        case .agents: item.kind.isAgent
        case .daemons: item.kind == .daemon
        case .disabled: !item.isEnabled
        case .unsigned: item.isUnsigned
        }
    }
}

enum StartupSort: CaseIterable, Identifiable {
    case name, app, kind

    var id: Self { self }

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .app: String(localized: "App")
        case .kind: String(localized: "Kind")
        }
    }

    func areInIncreasingOrder(_ lhs: StartupItem, _ rhs: StartupItem) -> Bool {
        switch self {
        case .name:
            break
        case .app:
            // Items without an owner sort last.
            let (left, right) = (lhs.appName ?? "\u{FFFF}", rhs.appName ?? "\u{FFFF}")
            if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
        case .kind:
            let order = StartupItemKind.allCases
            let (left, right) = (order.firstIndex(of: lhs.kind) ?? 0, order.firstIndex(of: rhs.kind) ?? 0)
            if left != right { return left < right }
        }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}
