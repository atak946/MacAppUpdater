import Foundation

/// A daily window (local hours, 0–23) in which unattended installs must not run.
/// `startHour > endHour` wraps across midnight (e.g. 22 → 8). Equal hours mean "no quiet time".
public struct QuietHours: Sendable, Codable, Equatable, Hashable {
    public let startHour: Int
    public let endHour: Int

    public init(startHour: Int, endHour: Int) {
        self.startHour = Self.clampHour(startHour)
        self.endHour = Self.clampHour(endHour)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            startHour: try container.decode(Int.self, forKey: .startHour),
            endHour: try container.decode(Int.self, forKey: .endHour)
        )
    }

    /// True when `hour` falls inside the window (start inclusive, end exclusive).
    public func contains(hour: Int) -> Bool {
        guard startHour != endHour else { return false }
        if startHour < endHour { return hour >= startHour && hour < endHour }
        return hour >= startHour || hour < endHour
    }

    /// True when `date` falls inside the window in `calendar`'s time zone.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        contains(hour: calendar.component(.hour, from: date))
    }

    /// The next moment the window closes after `date` (the next `endHour:00`).
    public func end(after date: Date, calendar: Calendar) -> Date {
        let components = DateComponents(hour: endHour, minute: 0, second: 0)
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(60 * 60)
    }

    private static func clampHour(_ hour: Int) -> Int {
        min(max(hour, 0), 23)
    }
}

/// System-state requirements an unattended install must meet (C3).
public struct InstallConditions: Sendable, Codable, Equatable, Hashable {
    public let requireACPower: Bool
    public let avoidExpensiveNetwork: Bool
    public let avoidConstrainedNetwork: Bool
    public let quietHours: QuietHours?
    /// Never quit a running app for an unattended install.
    public let skipRunningApps: Bool

    public init(
        requireACPower: Bool = false,
        avoidExpensiveNetwork: Bool = false,
        avoidConstrainedNetwork: Bool = false,
        quietHours: QuietHours? = nil,
        skipRunningApps: Bool = true
    ) {
        self.requireACPower = requireACPower
        self.avoidExpensiveNetwork = avoidExpensiveNetwork
        self.avoidConstrainedNetwork = avoidConstrainedNetwork
        self.quietHours = quietHours
        self.skipRunningApps = skipRunningApps
    }

    /// Missing keys fall back to defaults so older or partial JSON keeps decoding.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = InstallConditions()
        self.init(
            requireACPower: try container.decodeIfPresent(Bool.self, forKey: .requireACPower)
                ?? defaults.requireACPower,
            avoidExpensiveNetwork: try container.decodeIfPresent(Bool.self, forKey: .avoidExpensiveNetwork)
                ?? defaults.avoidExpensiveNetwork,
            avoidConstrainedNetwork: try container.decodeIfPresent(Bool.self, forKey: .avoidConstrainedNetwork)
                ?? defaults.avoidConstrainedNetwork,
            quietHours: try container.decodeIfPresent(QuietHours.self, forKey: .quietHours),
            skipRunningApps: try container.decodeIfPresent(Bool.self, forKey: .skipRunningApps)
                ?? defaults.skipRunningApps
        )
    }

    public func with(
        requireACPower: Bool? = nil,
        avoidExpensiveNetwork: Bool? = nil,
        avoidConstrainedNetwork: Bool? = nil,
        skipRunningApps: Bool? = nil
    ) -> InstallConditions {
        InstallConditions(
            requireACPower: requireACPower ?? self.requireACPower,
            avoidExpensiveNetwork: avoidExpensiveNetwork ?? self.avoidExpensiveNetwork,
            avoidConstrainedNetwork: avoidConstrainedNetwork ?? self.avoidConstrainedNetwork,
            quietHours: quietHours,
            skipRunningApps: skipRunningApps ?? self.skipRunningApps
        )
    }

    /// Returns a copy with the quiet-hours window replaced; `nil` turns quiet hours off.
    public func withQuietHours(_ window: QuietHours?) -> InstallConditions {
        InstallConditions(
            requireACPower: requireACPower,
            avoidExpensiveNetwork: avoidExpensiveNetwork,
            avoidConstrainedNetwork: avoidConstrainedNetwork,
            quietHours: window,
            skipRunningApps: skipRunningApps
        )
    }
}
