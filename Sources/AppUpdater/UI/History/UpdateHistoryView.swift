import AppUpdaterCore
import SwiftUI

/// Chronological log of installs, failures and rollbacks, grouped by day.
/// Stateless with respect to storage: the caller passes entries and handles actions.
struct UpdateHistoryView: View {
    let entries: [UpdateHistoryEntry]
    let onClear: () -> Void
    /// Optional: reveal or open the app an entry refers to.
    var onSelect: ((UpdateHistoryEntry) -> Void)?
    /// When the host window already has a search field (MainWindowView), pass its text here;
    /// the view then skips its own `.searchable` to avoid two toolbar search fields.
    var externalSearchText: String?

    @State private var searchText = ""
    @State private var isConfirmingClear = false

    var body: some View {
        searchableContent
            .confirmationDialog("Clear the update history?", isPresented: $isConfirmingClear) {
                Button("Clear History", role: .destructive, action: onClear)
            } message: {
                Text("Backups are not affected.")
            }
    }

    @ViewBuilder
    private var searchableContent: some View {
        if externalSearchText == nil {
            content.searchable(text: $searchText, placement: .toolbar, prompt: "Search history")
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            EmptyStateView(
                symbol: "clock.arrow.circlepath",
                title: String(localized: "No history yet"),
                message: String(localized: "Installed updates and rollbacks will appear here.")
            )
            .pageBackground()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    PageHeader(title: String(localized: "History"), subtitle: summary) {
                        Button(role: .destructive) { isConfirmingClear = true } label: {
                            Label("Clear History", systemImage: "trash")
                        }
                        .buttonStyle(.secondary(tint: Theme.Palette.danger))
                    }
                    if sections.isEmpty {
                        EmptyStateView(
                            symbol: "magnifyingglass",
                            tint: Theme.Palette.textSecondary,
                            title: String(localized: "No results for \u{201C}\(query)\u{201D}"),
                            message: String(localized: "Try an app name, bundle identifier or version.")
                        )
                        .surface(.inset)
                    } else {
                        ForEach(sections, id: \.day) { section in
                            daySection(section.day, entries: section.entries)
                        }
                    }
                }
                .padding(Theme.Spacing.page)
                .frame(maxWidth: Theme.Spacing.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .pageBackground()
        }
    }

    private func daySection(_ day: Date, entries: [UpdateHistoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(eyebrow: dayEyebrow(day), title: day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                StatusPill(
                    title: entries.count == 1 ? String(localized: "1 event") : String(localized: "\(entries.count) events"),
                    tint: Theme.Palette.textSecondary
                )
            }
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        GlassDivider(leadingInset: 58)
                    }
                    HistoryRow(entry: entry, onSelect: onSelect)
                }
            }
            .padding(Theme.Spacing.xs)
            .background(
                // Faint bloom tinted by the day's worst outcome.
                RadialGradient(colors: [dayTint(entries).opacity(0.14), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            )
            .surface(.raised)
        }
    }

    /// Danger if anything failed that day, warning for rollbacks, brand otherwise.
    private func dayTint(_ entries: [UpdateHistoryEntry]) -> Color {
        if entries.contains(where: { if case .failed = $0.outcome { true } else { false } }) { return Theme.Palette.danger }
        if entries.contains(where: { $0.outcome == .rolledBack }) { return Theme.Palette.warning }
        return Theme.Palette.brand
    }

    private func dayEyebrow(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.year())
    }

    private var summary: String {
        let failures = entries.filter { if case .failed = $0.outcome { true } else { false } }.count
        let total = entries.count == 1 ? String(localized: "1 update recorded") : String(localized: "\(entries.count) updates recorded")
        return failures == 0 ? total : String(localized: "\(total) · \(failures) failed")
    }

    private var filtered: [UpdateHistoryEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.appName, entry.bundleID, entry.fromVersion, entry.toVersion]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var query: String {
        (externalSearchText ?? searchText).trimmingCharacters(in: .whitespaces)
    }

    private var sections: [(day: Date, entries: [UpdateHistoryEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return grouped
            .map { (day: $0.key, entries: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }
}

#Preview {
    UpdateHistoryView(
        entries: [
            UpdateHistoryEntry(bundleID: "com.example.a", appName: "Alpha", fromVersion: "1.0",
                               toVersion: "1.1", source: .sparkle, outcome: .succeeded),
            UpdateHistoryEntry(bundleID: "com.example.b", appName: "Beta", fromVersion: "2.0",
                               toVersion: "2.1", source: .github, outcome: .failed(message: "Checksum mismatch")),
            UpdateHistoryEntry(bundleID: "com.example.a", appName: "Alpha", fromVersion: "1.1",
                               toVersion: "1.0", source: nil, date: .now.addingTimeInterval(-86_400),
                               outcome: .rolledBack),
        ],
        onClear: {}
    )
    .frame(width: 600, height: 400)
}
