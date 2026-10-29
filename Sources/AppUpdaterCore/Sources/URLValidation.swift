import Foundation

/// Shared URL checks for untrusted strings (feeds, vendor templates, MDM values).
public enum URLValidation {
    /// An absolute `https` URL with a non-empty host and no embedded credentials, else nil.
    public static func httpsURL(_ string: String) -> URL? {
        guard let components = URLComponents(string: string),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        return components.url
    }
}

extension GitHubReleasesSource.Architecture {
    /// How well a release file name fits this architecture, used by the GitHub and
    /// electron-builder sources: 3 = native, 2 = universal, 1 = unmarked, 0 = the other arch.
    func score(fileName: String) -> Int {
        let lowered = fileName.lowercased()
        let isUniversal = lowered.contains("universal")
        let isArm = ["arm64", "aarch64", "apple-silicon", "applesilicon", "m1"].contains(where: lowered.contains)
        let isIntel = ["x86_64", "x86-64", "x64", "intel", "amd64"].contains(where: lowered.contains)
        let (native, foreign) = self == .appleSilicon ? (isArm, isIntel) : (isIntel, isArm)
        if native { return 3 }
        if isUniversal { return 2 }
        return foreign ? 0 : 1
    }
}
