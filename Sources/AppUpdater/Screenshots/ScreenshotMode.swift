import Foundation

/// Detects the README screenshot mode: `--render-screenshots <dir>` or `MACAPPUPDATER_RENDER_SCREENSHOTS=<dir>`.
enum ScreenshotMode {
    static let argument = "--render-screenshots"
    static let environmentKey = "MACAPPUPDATER_RENDER_SCREENSHOTS"

    /// The output folder when screenshot mode was requested; the argument wins over the environment.
    static func outputDirectory(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let index = arguments.firstIndex(of: argument) {
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else { return nil }
            return directory(from: arguments[next])
        }
        return environment[environmentKey].flatMap(directory(from:))
    }

    private static func directory(from path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }
}
