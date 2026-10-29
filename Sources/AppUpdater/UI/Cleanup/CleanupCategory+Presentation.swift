import Foundation
import MaintenanceCore
import SwiftUI

// MARK: - Category presentation

extension CleanupCategory {
    /// Localized name shown on cards and chips.
    var title: String {
        switch self {
        case .userCaches: String(localized: "App Caches")
        case .logs: String(localized: "Logs")
        case .xcodeDerivedData: String(localized: "Xcode Derived Data")
        case .xcodeArchives: String(localized: "Xcode Archives")
        case .deviceSupport: String(localized: "Device Support")
        case .simulatorCaches: String(localized: "Simulator Caches")
        case .packageManagerCaches: String(localized: "Package Manager Caches")
        case .trash: String(localized: "Trash")
        case .oldInstallers: String(localized: "Old Installers")
        case .largeOldFiles: String(localized: "Large Old Files")
        case .removedAppLeftovers: String(localized: "Leftovers of Removed Apps")
        }
    }

    /// One-line explanation of what the category holds and whether it is safe to remove.
    var summary: String {
        switch self {
        case .userCaches: String(localized: "Temporary files apps rebuild on demand.")
        case .logs: String(localized: "Diagnostic and crash logs older than a few days.")
        case .xcodeDerivedData: String(localized: "Build products and indexes Xcode recreates.")
        case .xcodeArchives: String(localized: "App archives you may need for symbolication or re-export.")
        case .deviceSupport: String(localized: "Debug symbols for iOS, watchOS and tvOS versions.")
        case .simulatorCaches: String(localized: "Simulator caches and unavailable devices.")
        case .packageManagerCaches: String(localized: "Download caches of npm, Homebrew, Gradle and others.")
        case .trash: String(localized: "Items already in the Trash; removed permanently.")
        case .oldInstallers: String(localized: "Disk images and installers in Downloads.")
        case .largeOldFiles: String(localized: "Big files you haven't opened in a long time.")
        case .removedAppLeftovers: String(localized: "Settings and data of apps that are no longer installed.")
        }
    }

    var symbol: String {
        switch self {
        case .userCaches: "archivebox.fill"
        case .logs: "doc.text.fill"
        case .xcodeDerivedData: "hammer.fill"
        case .xcodeArchives: "shippingbox.fill"
        case .deviceSupport: "iphone"
        case .simulatorCaches: "ipad.and.iphone"
        case .packageManagerCaches: "cube.box.fill"
        case .trash: "trash.fill"
        case .oldInstallers: "arrow.down.circle.fill"
        case .largeOldFiles: "tray.full.fill"
        case .removedAppLeftovers: "app.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .userCaches: Theme.Palette.brand
        case .logs: Theme.Palette.info
        case .xcodeDerivedData: Theme.Palette.brandTertiary
        case .xcodeArchives: Color(red: 1.0, green: 0.56, blue: 0.32)
        case .deviceSupport: Color(red: 0.3, green: 0.85, blue: 0.86)
        case .simulatorCaches: Color(red: 0.42, green: 0.55, blue: 1.0)
        case .packageManagerCaches: Theme.Palette.success
        case .trash: Theme.Palette.danger
        case .oldInstallers: Theme.Palette.warning
        case .largeOldFiles: Theme.Palette.brandSecondary
        case .removedAppLeftovers: Color(red: 0.95, green: 0.42, blue: 0.68)
        }
    }

    /// Needs a second look before removing: never preselected and flagged with "Review".
    var needsReview: Bool { !isSelectedByDefault }
}

// MARK: - Formatting

enum CleanupFormat {
    /// "12.4 GB".
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    /// Number and unit separately ("12.4", "GB") for a large numeral with a smaller unit.
    static func splitBytes(_ value: Int64) -> (number: String, unit: String) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.includesUnit = false
        let number = formatter.string(fromByteCount: value)
        formatter.includesUnit = true
        formatter.includesCount = false
        return (number, formatter.string(fromByteCount: value))
    }

    /// "~/Library/Caches" for the folder that holds the item.
    static func location(of url: URL) -> String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}
