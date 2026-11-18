import AppUpdaterCore
import SwiftUI

/// Chronological log of installs, failures and rollbacks, grouped by day.
/// Stateless with respect to storage: the caller passes entries and handles actions.
struct UpdateHistoryView: View {
    let entries: [UpdateHistoryEntry]
    let onClear: () -> Void
    /// Optional: reveal or open the app an entry refers to.
    var onSelect: ((UpdateHistoryEntry) -> Void)?

    @State private var searchText = ""
    @AppStorage("history.outcomeFilter") private var outcome: HistoryOutcomeFilter = .all
    @AppStorage("history.period") private var period: HistoryPeriod = .allTime
    @State private var isConfirmingClear = false

    var body: some View {
        content
            .confirmationDialog("Clear the update history?", isPresented: $isConfirmingClear) {
                Button("Clear History", role: .destructive, action: onClear)
            } message: {
                Text("Backups are not affected.")
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
                    PageToolbar(prompt: String(localized: "Search history"), search: $searchText, shownCount: filtered.count) {
                        FilterCapsule(options: HistoryOutcomeFilter.allCases, selection: $outcome, title: \.title) { option in
                            entries.count { option.includes($0) }
                        }
                        periodMenu
                    }
                    if sections.isEmpty {
                        EmptyStateView(
                            symbol: "magnifyingglass",
                            tint: Theme.Palette.textSecondary,
                            title: String(localized: "No matching events"),
                            message: String(localized: "Try an app name, bundle identifier or version, or another filter.")
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

    private var periodMenu: some View {
        Menu {
            Picker("Period", selection: $period) {
                ForEach(HistoryPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(period.title, systemImage: "calendar")
        }
        .menuStyle(.button)
        .buttonStyle(.secondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Period")
    }

    private var filtered: [UpdateHistoryEntry] {
        let cutoff = period.cutoff(from: .now)
        let narrowed = entries.filter { entry in
            outcome.includes(entry) && cutoff.map { entry.date >= $0 } ?? true
        }
        return SearchQuery(searchText).filter(narrowed) { entry in
            [entry.appName, entry.bundleID, entry.fromVersion, entry.toVersion, entry.source?.displayName]
        }
    }

    private var sections: [(day: Date, entries: [UpdateHistoryEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return grouped
            .map { (day: $0.key, entries: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }
}

/// Narrows the history by what happened.
enum HistoryOutcomeFilter: String, CaseIterable, Hashable {
    case all, succeeded, failed, rolledBack

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .succeeded: String(localized: "Succeeded")
        case .failed: String(localized: "Failed")
        case .rolledBack: String(localized: "Rolled back")
        }
    }

    func includes(_ entry: UpdateHistoryEntry) -> Bool {
        switch (self, entry.outcome) {
        case (.all, _), (.succeeded, .succeeded), (.failed, .failed), (.rolledBack, .rolledBack): true
        default: false
        }
    }
}

/// Narrows the history to recent events.
enum HistoryPeriod: String, CaseIterable, Hashable {
    case allTime, lastWeek, lastMonth, lastYear

    var title: String {
        switch self {
        case .allTime: String(localized: "All time")
        case .lastWeek: String(localized: "Last 7 days")
        case .lastMonth: String(localized: "Last 30 days")
        case .lastYear: String(localized: "Last 12 months")
        }
    }

    /// Oldest date still shown, or nil for no limit.
    func cutoff(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .allTime: nil
        case .lastWeek: calendar.date(byAdding: .day, value: -7, to: now)
        case .lastMonth: calendar.date(byAdding: .day, value: -30, to: now)
        case .lastYear: calendar.date(byAdding: .month, value: -12, to: now)
        }
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
