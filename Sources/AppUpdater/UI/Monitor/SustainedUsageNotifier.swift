import Foundation
import MonitorCore
import os
import UserNotifications

protocol SustainedUsageNotifying: Sendable {
    func notifySustainedUsage(_ hog: SustainedHog) async
}

/// Local notification for an app that kept the CPU busy. Authorization is requested at launch
/// by `UpdateNotifier`; without it the post fails quietly.
struct SustainedUsageNotifier: SustainedUsageNotifying {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "UsageHistory")

    /// UNUserNotificationCenter raises an exception outside of an app bundle (e.g. `swift run`).
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func notifySustainedUsage(_ hog: SustainedHog) async {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(hog.name) is using a lot of CPU")
        content.body = String(localized: "It averaged \(MonitorFormat.cpu(hog.averageCPUPercent)) CPU over the last \(MonitorFormat.duration(hog.duration)).")
        let request = UNNotificationRequest(identifier: "com.macappupdater.sustained-usage.\(hog.id)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Self.logger.error("Failed to post usage notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}
