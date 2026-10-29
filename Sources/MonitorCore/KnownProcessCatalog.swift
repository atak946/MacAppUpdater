import Foundation

/// Descriptions of well-known macOS processes. Summaries are English localization keys.
public enum KnownProcessCatalog {
    /// Exact-name lookup first, then known name prefixes (e.g. `com.apple.WebKit.*`, `mdworker_shared`).
    public static func info(forProcessNamed name: String) -> KnownProcessInfo? {
        if let exact = entries[name] { return exact }
        return prefixEntries.first { name.hasPrefix($0.prefix) }?.info
    }

    // MARK: - Data

    private static func critical(_ summary: String) -> KnownProcessInfo { KnownProcessInfo(summary: summary, kind: .critical) }
    private static func system(_ summary: String) -> KnownProcessInfo { KnownProcessInfo(summary: summary, kind: .system) }
    private static func user(_ summary: String) -> KnownProcessInfo { KnownProcessInfo(summary: summary, kind: .user) }

    private static let entries: [String: KnownProcessInfo] = [
        "kernel_task": critical("Kernel; also throttles CPU to cool the Mac"),
        "launchd": critical("Starts and supervises every other process"),
        "WindowServer": critical("Draws everything on screen"),
        "loginwindow": critical("Manages your login session"),
        "logd": critical("System logging"),
        "opendirectoryd": critical("User accounts and directory services"),
        "configd": critical("Network and system configuration"),
        "coreservicesd": critical("Core app and file services"),
        "securityd": critical("Keychain and security services"),
        "notifyd": critical("System notification messaging"),
        "diskarbitrationd": critical("Mounts and manages disks"),
        "powerd": critical("Power management and sleep"),
        "runningboardd": critical("Manages app lifecycles and resources"),
        "mds": system("Spotlight indexing"),
        "mds_stores": system("Spotlight indexing"),
        "mdworker": system("Spotlight indexing"),
        "corespotlightd": system("Spotlight indexing"),
        "photoanalysisd": system("Analyzes photos for faces and objects"),
        "mediaanalysisd": system("Analyzes photos and videos"),
        "photolibraryd": system("Manages the Photos library"),
        "cloudd": system("iCloud sync"),
        "bird": system("iCloud sync"),
        "fileproviderd": system("iCloud Drive and file provider sync"),
        "backupd": system("Time Machine"),
        "backupd-helper": system("Time Machine"),
        "softwareupdated": system("Checks for and installs macOS updates"),
        "trustd": system("Verifies certificates"),
        "nsurlsessiond": system("Background downloads"),
        "coreaudiod": system("Audio playback and recording"),
        "bluetoothd": system("Bluetooth"),
        "airportd": system("Wi-Fi"),
        "mDNSResponder": system("Network name resolution (DNS, Bonjour)"),
        "syspolicyd": system("Gatekeeper app security checks"),
        "XProtect": system("Malware protection"),
        "XprotectService": system("Malware protection"),
        "Dock": system("Dock, Launchpad and Mission Control"),
        "Finder": system("Finder"),
        "SystemUIServer": system("Menu bar extras"),
        "ControlCenter": system("Control Center and menu bar"),
        "NotificationCenter": system("Notifications"),
        "Spotlight": system("Spotlight search"),
        "sharingd": system("AirDrop and Handoff"),
        "rapportd": system("Continuity between your devices"),
        "suggestd": system("Siri suggestions"),
        "knowledge-agent": system("Siri suggestions"),
        "remindd": system("Reminders sync"),
        "secd": system("Keychain sync"),
        "distnoted": system("Notification messaging between apps"),
        "cfprefsd": system("Preferences storage"),
        "UserEventAgent": system("System event handling"),
        "hidd": system("Keyboard, mouse and trackpad input"),
        "Safari": user("Safari web browser"),
    ]

    private static let prefixEntries: [(prefix: String, info: KnownProcessInfo)] = [
        ("com.apple.WebKit.", user("Safari/WebKit web content")),
        ("mdworker", system("Spotlight indexing")),
        ("Google Chrome Helper", user("Chrome web content")),
    ]
}
