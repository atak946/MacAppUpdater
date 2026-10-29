import Foundation

/// Per-app facts gathered for the Insights dashboard.
public struct AppInsight: Sendable, Hashable, Identifiable {
    public var id: String { app.id }

    public let app: InstalledApp
    public let sizeInBytes: Int64?
    public let lastUsedDate: Date?
    public let isIntelOnly: Bool
    public let warnings: [AppWarning]

    public init(app: InstalledApp, sizeInBytes: Int64?, lastUsedDate: Date?, isIntelOnly: Bool, warnings: [AppWarning]) {
        self.app = app
        self.sizeInBytes = sizeInBytes
        self.lastUsedDate = lastUsedDate
        self.isIntelOnly = isIntelOnly
        self.warnings = warnings
    }

    /// Highest severity among this app's warnings, if any.
    public var highestSeverity: WarningSeverity? { warnings.map(\.severity).max() }
}

/// One warning tied to the app it was raised for.
public struct AppWarningEntry: Sendable, Hashable, Identifiable {
    public var id: String { "\(app.id)#\(warning.id)" }
    public let app: InstalledApp
    public let warning: AppWarning

    public init(app: InstalledApp, warning: AppWarning) {
        self.app = app
        self.warning = warning
    }
}

/// Warnings of one severity, for grouped display.
public struct WarningGroup: Sendable, Hashable, Identifiable {
    public var id: WarningSeverity { severity }
    public let severity: WarningSeverity
    public let entries: [AppWarningEntry]

    public init(severity: WarningSeverity, entries: [AppWarningEntry]) {
        self.severity = severity
        self.entries = entries
    }
}

/// Aggregated, display-ready snapshot of the whole app library.
public struct InsightsReport: Sendable, Hashable {
    public let generatedAt: Date
    public let apps: [AppInsight]
    public let totalApps: Int
    public let totalSizeInBytes: Int64
    /// Largest first, at most `InsightsBuilder.largestAppsLimit`.
    public let largestApps: [AppInsight]
    /// Not opened for more than the unused threshold, least recently used first.
    public let unusedApps: [AppInsight]
    public let intelOnlyApps: [AppInsight]
    /// Non-empty groups only, critical first.
    public let warningGroups: [WarningGroup]

    public init(
        generatedAt: Date,
        apps: [AppInsight],
        totalApps: Int,
        totalSizeInBytes: Int64,
        largestApps: [AppInsight],
        unusedApps: [AppInsight],
        intelOnlyApps: [AppInsight],
        warningGroups: [WarningGroup]
    ) {
        self.generatedAt = generatedAt
        self.apps = apps
        self.totalApps = totalApps
        self.totalSizeInBytes = totalSizeInBytes
        self.largestApps = largestApps
        self.unusedApps = unusedApps
        self.intelOnlyApps = intelOnlyApps
        self.warningGroups = warningGroups
    }

    public var totalWarnings: Int { warningGroups.reduce(0) { $0 + $1.entries.count } }

    public func warnings(for bundleIdentifier: String) -> [AppWarning] {
        apps.first { $0.app.bundleIdentifier == bundleIdentifier }?.warnings ?? []
    }
}

/// Pure aggregation of `[AppInsight]` into an `InsightsReport`.
public struct InsightsBuilder: Sendable {
    public static let largestAppsLimit = 10

    public let unusedThresholdDays: Int
    public let largestLimit: Int

    public init(
        unusedThresholdDays: Int = CompatibilityAnalyzer.defaultUnusedThresholdDays,
        largestLimit: Int = InsightsBuilder.largestAppsLimit
    ) {
        self.unusedThresholdDays = unusedThresholdDays
        self.largestLimit = largestLimit
    }

    public func build(from insights: [AppInsight], now: Date = Date()) -> InsightsReport {
        InsightsReport(
            generatedAt: now,
            apps: insights,
            totalApps: insights.count,
            totalSizeInBytes: insights.reduce(Int64(0)) { $0 + ($1.sizeInBytes ?? 0) },
            largestApps: largest(insights),
            unusedApps: unused(insights, now: now),
            intelOnlyApps: insights.filter(\.isIntelOnly).sorted(by: Self.byName),
            warningGroups: groups(insights)
        )
    }

    private func largest(_ insights: [AppInsight]) -> [AppInsight] {
        let sized = insights.filter { ($0.sizeInBytes ?? 0) > 0 }
        return Array(sized.sorted { ($0.sizeInBytes ?? 0) > ($1.sizeInBytes ?? 0) }.prefix(largestLimit))
    }

    private func unused(_ insights: [AppInsight], now: Date) -> [AppInsight] {
        guard let cutoff = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -unusedThresholdDays, to: now) else { return [] }
        return insights
            .filter { ($0.lastUsedDate.map { $0 < cutoff }) ?? false }
            .sorted { ($0.lastUsedDate ?? .distantPast) < ($1.lastUsedDate ?? .distantPast) }
    }

    private func groups(_ insights: [AppInsight]) -> [WarningGroup] {
        let entries = insights.flatMap { insight in
            insight.warnings.map { AppWarningEntry(app: insight.app, warning: $0) }
        }
        return WarningSeverity.allCases.reversed().compactMap { severity in
            let matching = entries
                .filter { $0.warning.severity == severity }
                .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
            return matching.isEmpty ? nil : WarningGroup(severity: severity, entries: matching)
        }
    }

    private static func byName(_ lhs: AppInsight, _ rhs: AppInsight) -> Bool {
        lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
    }
}
