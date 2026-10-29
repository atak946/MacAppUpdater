import Foundation
import MaintenanceCore
import SwiftUI

// MARK: - Checks

extension SecurityCheckKind {
    var title: String {
        switch self {
        case .fileVault: String(localized: "FileVault")
        case .firewall: String(localized: "Firewall")
        case .firewallStealth: String(localized: "Stealth Mode")
        case .systemIntegrityProtection: String(localized: "System Integrity Protection")
        case .gatekeeper: String(localized: "Gatekeeper")
        case .automaticUpdates: String(localized: "Automatic Updates")
        case .screenLock: String(localized: "Screen Lock")
        case .remoteLogin: String(localized: "Remote Login")
        case .xprotect: String(localized: "XProtect Definitions")
        }
    }

    var symbol: String {
        switch self {
        case .fileVault: "lock.doc.fill"
        case .firewall: "flame.fill"
        case .firewallStealth: "eye.slash.fill"
        case .systemIntegrityProtection: "cpu.fill"
        case .gatekeeper: "checkmark.shield.fill"
        case .automaticUpdates: "arrow.triangle.2.circlepath"
        case .screenLock: "lock.display"
        case .remoteLogin: "terminal.fill"
        case .xprotect: "ladybug.fill"
        }
    }

    var tint: Color {
        switch self {
        case .fileVault, .gatekeeper: Theme.Palette.brand
        case .firewall, .firewallStealth: Theme.Palette.brandSecondary
        case .systemIntegrityProtection, .xprotect: Theme.Palette.brandTertiary
        case .automaticUpdates, .screenLock, .remoteLogin: Theme.Palette.info
        }
    }

    /// System Settings pane; nil for SIP, which is only changed from Recovery.
    var settingsURL: URL? {
        let base = "x-apple.systempreferences:"
        let path: String? = switch self {
        case .fileVault: "com.apple.preference.security?FileVault"
        case .firewall, .firewallStealth: "com.apple.preference.security?Firewall"
        case .gatekeeper: "com.apple.preference.security?General"
        case .automaticUpdates, .xprotect: "com.apple.Software-Update-Settings.extension"
        case .screenLock: "com.apple.Lock-Screen-Settings.extension"
        case .remoteLogin: "com.apple.Sharing-Settings.extension"
        case .systemIntegrityProtection: nil
        }
        return path.flatMap { URL(string: base + $0) }
    }
}

extension SecurityCheckResult {
    /// Pill text for the raw state.
    var statusTitle: String {
        switch status {
        case .on: String(localized: "On")
        case .off: String(localized: "Off")
        case .unknown: String(localized: "Unknown")
        }
    }

    var statusTint: Color {
        switch isSecure {
        case true?: Theme.Palette.success
        case false?: severity >= .high ? Theme.Palette.danger : Theme.Palette.warning
        case nil: Theme.Palette.textTertiary
        }
    }

    /// One-line explanation of what the state means for the user.
    var explanation: String {
        guard let isSecure else { return String(localized: "Couldn't be read on this Mac.") }
        switch (kind, isSecure) {
        case (.fileVault, true): return String(localized: "Your disk is encrypted if the Mac is lost or stolen.")
        case (.fileVault, false): return String(localized: "Anyone with your Mac can read the disk. Turn on encryption.")
        case (.firewall, true): return String(localized: "Unwanted incoming connections are blocked.")
        case (.firewall, false): return String(localized: "Apps can accept incoming connections freely.")
        case (.firewallStealth, true): return String(localized: "Your Mac ignores probes from the network.")
        case (.firewallStealth, false): return String(localized: "Your Mac answers network probes such as ping.")
        case (.systemIntegrityProtection, true): return String(localized: "Core system files are protected from changes.")
        case (.systemIntegrityProtection, false): return String(localized: "System files can be modified. Re-enable it from Recovery.")
        case (.gatekeeper, true): return String(localized: "Only trusted, notarized apps open without a warning.")
        case (.gatekeeper, false): return String(localized: "Apps from any source open without checks.")
        case (.automaticUpdates, true): return String(localized: "Security fixes arrive in the background.")
        case (.automaticUpdates, false): return String(localized: "Security fixes aren't installed automatically.")
        case (.screenLock, true): return String(localized: "A password is required after sleep or the screen saver.")
        case (.screenLock, false): return String(localized: "Your Mac unlocks without a password after sleep.")
        case (.remoteLogin, true): return String(localized: "SSH access is turned off.")
        case (.remoteLogin, false): return String(localized: "Others can log in over SSH. Turn it off if unused.")
        case (.xprotect, true): return String(localized: "Malware definitions are up to date.")
        case (.xprotect, false): return String(localized: "Malware definitions haven't updated recently.")
        }
    }
}

/// Rating text and color for the 0...100 score.
enum SecurityRating {
    static func title(for score: Int) -> String {
        switch score {
        case 90...: String(localized: "Excellent")
        case 75..<90: String(localized: "Good")
        case 50..<75: String(localized: "Fair")
        default: String(localized: "At Risk")
        }
    }

    static func tint(for score: Int?) -> Color {
        guard let score else { return Theme.Palette.info }
        switch score {
        case 90...: return Theme.Palette.success
        case 75..<90: return Theme.Palette.info
        case 50..<75: return Theme.Palette.warning
        default: return Theme.Palette.danger
        }
    }
}

// MARK: - Privacy services

extension PrivacyService {
    var title: String {
        switch self {
        case .camera: String(localized: "Camera")
        case .microphone: String(localized: "Microphone")
        case .screenCapture: String(localized: "Screen Recording")
        case .accessibility: String(localized: "Accessibility")
        case .fullDiskAccess: String(localized: "Full Disk Access")
        case .inputMonitoring: String(localized: "Input Monitoring")
        case .contacts: String(localized: "Contacts")
        case .calendar: String(localized: "Calendars")
        case .photos: String(localized: "Photos")
        case .automation: String(localized: "Automation")
        }
    }

    var symbol: String {
        switch self {
        case .camera: "camera.fill"
        case .microphone: "mic.fill"
        case .screenCapture: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        case .fullDiskAccess: "internaldrive.fill"
        case .inputMonitoring: "keyboard.fill"
        case .contacts: "person.crop.circle.fill"
        case .calendar: "calendar"
        case .photos: "photo.fill"
        case .automation: "gearshape.2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .camera, .microphone, .screenCapture: Theme.Palette.brandSecondary
        case .accessibility, .inputMonitoring, .automation: Theme.Palette.brand
        case .fullDiskAccess: Theme.Palette.warning
        case .contacts, .calendar, .photos: Theme.Palette.brandTertiary
        }
    }

    var settingsURL: URL? {
        let anchor = switch self {
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .screenCapture: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .contacts: "Privacy_Contacts"
        case .calendar: "Privacy_Calendars"
        case .photos: "Privacy_Photos"
        case .automation: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor)
    }
}

extension PermissionFlag {
    var title: String {
        switch self {
        case .notInstalled: String(localized: "Not installed")
        case .unused: String(localized: "Unused")
        }
    }
}
