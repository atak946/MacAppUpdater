import Foundation
import Security

/// XPC interface exported by the privileged helper (`com.macappupdater.helper`).
///
/// Kept deliberately small: every method is a potential root-level attack surface.
@objc public protocol PrivilegedHelperProtocol {
    /// Installs the flat `.pkg` readable through `fileHandle` with
    /// `/usr/sbin/installer -pkg <staged copy> -target /`.
    ///
    /// The app passes an open, read-only descriptor (NSXPC transfers the fd) instead of a
    /// path, so the helper never resolves caller-chosen paths as root. The helper copies the
    /// bytes into a root-only staging directory and installs the copy only when it is signed
    /// with a notarized Developer ID Installer certificate of `expectedTeamID`.
    /// Replies `(true, nil)` on success or `(false, message)` on failure.
    func installPackage(
        at fileHandle: FileHandle,
        expectedTeamID: String,
        withReply reply: @escaping @Sendable (Bool, String?) -> Void
    )

    /// Replies with the helper's `HelperConstants.helperVersion`.
    func version(withReply reply: @escaping @Sendable (String) -> Void)
}

/// Names shared by the app, the helper and the packaging script.
public enum HelperConstants {
    /// launchd label and Mach service name of the helper.
    public static let machServiceName = "com.macappupdater.helper"
    /// File name of the launchd plist in `Contents/Library/LaunchDaemons`.
    public static let launchdPlistName = "com.macappupdater.helper.plist"
    /// Code-signing identifier the helper binary must be signed with.
    public static let helperCodeSigningIdentifier = "com.macappupdater.helper"
    /// Code-signing identifier (bundle id) of the app allowed to talk to the helper.
    public static let appCodeSigningIdentifier = "com.macappupdater.app"
    /// Bumped whenever the XPC contract or helper behavior changes; the app
    /// re-registers the daemon when the running helper reports another version.
    /// 2.0.0: file-handle based `installPackage(at:expectedTeamID:withReply:)`.
    public static let helperVersion = "2.0.0"
    /// The helper exits after this many seconds without connections or installs;
    /// launchd relaunches it on the next Mach message.
    public static let idleExitSeconds: TimeInterval = 5 * 60
}

/// Code-signing utilities shared by both ends of the XPC connection.
public enum HelperCodeSigning {
    /// How strictly a peer requirement is built.
    public enum RequirementMode: Sendable, Equatable {
        /// Release builds: a Team ID is mandatory; without one every connection is refused.
        case release
        /// Debug builds only: an ad-hoc peer may be matched by identifier alone.
        case development
    }

    /// Compile-time mode: the identifier-only fallback exists only in `DEBUG` builds.
    public static var currentMode: RequirementMode {
        #if DEBUG
        .development
        #else
        .release
        #endif
    }

    /// Team identifier of the running process, or nil when ad-hoc signed / unsigned.
    public static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else {
            return nil
        }
        return team
    }

    /// Builds the code-signing requirement for the XPC peer, or nil when no safe
    /// requirement exists (fail closed: the caller must refuse the connection).
    ///
    /// - With a valid team id the peer must be Apple-anchored and signed by that team.
    ///   In `.release` mode it must also not carry `get-task-allow` (debuggable builds
    ///   could otherwise be driven by a debugger to talk to the root helper).
    /// - Without one, `.development` returns an identifier-only requirement (NOT a
    ///   security boundary, local ad-hoc builds only); `.release` returns nil.
    public static func peerRequirement(
        identifier: String,
        teamIdentifier: String?,
        mode: RequirementMode = currentMode
    ) -> String? {
        let identifierClause = "identifier \"\(identifier)\""
        guard let teamIdentifier, isValidTeamIdentifier(teamIdentifier) else {
            return mode == .development ? identifierClause : nil
        }
        let pinned = "anchor apple generic and \(identifierClause) and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        switch mode {
        case .release: return pinned + " and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"
        case .development: return pinned
        }
    }

    /// Team ids are 10 uppercase alphanumerics; anything else would corrupt the requirement.
    public static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }
}
