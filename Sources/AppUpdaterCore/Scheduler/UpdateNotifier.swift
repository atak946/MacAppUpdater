import Foundation
import os
import UserNotifications

/// Posts local notifications about available updates.
public struct UpdateNotifier: Sendable {
    public static let notificationIdentifier = "com.macappupdater.updates-available"

    private static let logger = Logger(subsystem: "com.macappupdater", category: "Notifier")

    public init() {}

    /// UNUserNotificationCenter raises an exception outside of an app bundle (e.g. `swift run`).
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    @discardableResult
    public func requestAuthorization() async -> Bool {
        guard isAvailable else {
            Self.logger.notice("Notifications unavailable: not running from an app bundle")
            return false
        }
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            Self.logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Posts "N updates available", replacing any previous notification. No-op for zero.
    public func notifyUpdatesAvailable(_ updates: [AvailableUpdate]) async {
        guard isAvailable, !updates.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = Self.title(forCount: updates.count)
        content.body = Self.body(for: updates)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Self.logger.error("Failed to post notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func title(forCount count: Int) -> String {
        count == 1
            ? String(coreLocalized: "1 update available")
            : String(coreLocalized: "\(count) updates available")
    }

    static func body(for updates: [AvailableUpdate], maxNames: Int = 3) -> String {
        let names = updates.prefix(maxNames).map(\.app.name)
        let remainder = updates.count - names.count
        let list = names.joined(separator: ", ")
        return remainder > 0 ? String(coreLocalized: "\(list) and \(remainder) more") : list
    }
}
