import AppUpdaterCore
import SwiftUI

// MARK: - Info grid

/// Label/value card with everything known about the bundle, grouped into Bundle, Update and Location.
struct AppInfoGrid: View {
    let app: InstalledApp
    let details: AppDetails?
    /// Result of the last update check; nil before the first check.
    let result: UpdateCheckResult?
    /// "Released …" / "First seen …" for the available update, if any.
    var releaseDate: String?

    private let labelWidth: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            group {
                row("Version", app.shortVersion, monospaced: true)
                row("Build", app.buildVersion ?? "—", monospaced: true)
                row("Size", details?.sizeInBytes.map { $0.formatted(.byteCount(style: .file)) })
                row("Modified", details?.modifiedAt.map { $0.formatted(date: .abbreviated, time: .shortened) })
                row("Requires", details?.minimumSystemVersion.map { "macOS \($0)" } ?? (details == nil ? nil : "—"))
                row("Architecture", details.map { $0.executableArchitectures.isEmpty ? "—" : $0.executableArchitectures.joined(separator: ", ") })
                row("Category", details.map { $0.category ?? "—" })
                row("Signed by", details.map(signatureText))
            }
            separator
            group {
                row("Update source", sourceText)
                if let releaseDate {
                    row("Update", releaseDate)
                }
            }
            separator
            group {
                row("Location", app.url.path, monospaced: true)
                if let copyright = details?.copyright {
                    row("Copyright", copyright)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.raised)
    }

    private var separator: some View {
        GlassDivider().padding(.horizontal, Theme.Spacing.l)
    }

    private func group(@ViewBuilder _ rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s + 2) {
            rows()
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m + 2)
    }

    /// A nil value means "still loading".
    private func row(_ label: LocalizedStringKey, _ value: String?, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.l) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: labelWidth, alignment: .leading)
            Group {
                if let value {
                    Text(value)
                        .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .transition(.opacity)
                } else {
                    SkeletonBar()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Theme.Motion.content, value: value)
    }

    private func signatureText(_ details: AppDetails) -> String {
        switch details.signature {
        case .signed(let team): String(localized: "Team \(team)")
        case .unsigned: String(localized: "Not signed / invalid signature")
        case .launcher(let target): String(localized: "Launcher for \(target)")
        case .apple: String(localized: "Apple")
        }
    }

    private var sourceText: String {
        guard let result else { return String(localized: "Not checked yet") }
        guard let kind = result.matchedSource else {
            return result.errors.isEmpty ? String(localized: "No known source") : String(localized: "Check failed (\(result.errors.count) error(s))")
        }
        let latest = result.latestVersion.map { String(localized: " — latest \($0)") } ?? ""
        switch kind {
        case .sparkle: return "Sparkle — \(app.sparkleFeedURL?.host() ?? String(localized: "feed"))\(latest)"
        default: return "\(kind.displayName)\(latest)"
        }
    }
}

/// Pulsing glass placeholder shown while a value loads, instead of a spinner.
private struct SkeletonBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.10))
            .frame(width: 96, height: 9)
            .opacity(isDimmed ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { isDimmed = true }
            }
            .accessibilityLabel(Text("Loading"))
    }
}
