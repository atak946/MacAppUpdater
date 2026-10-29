import Foundation
import Testing

/// Source-level guard for the monitor pages. Views there redraw on every sample (every 2s), and SwiftUI
/// renders blurred or interpolated content on the CPU, so these modifiers quietly multiply CPU use.
///
/// Intentional, non-sample-driven uses (hover, focus, a click-only selection) are exempted by putting
/// `// perf-guard: allow (<reason>)` at the end of the offending line.
@Suite("Monitor views avoid per-sample animation and blur")
struct MonitorPerfGuardTests {
    static let forbidden = ["numericText", ".animation(", ".glow(", ".shadow(", "symbolEffect", "repeatForever"]
    static let allowMarker = "// perf-guard: allow"

    /// TODO: MonitorCharts.swift is being rewritten in parallel; drop this exclusion once that lands.
    static let excludedFiles: Set<String> = ["MonitorCharts.swift"]

    /// Package root, found by walking up from this file to the directory holding Package.swift.
    static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        fatalError("Package.swift not found above \(#filePath)")
    }()

    @Test("No forbidden modifiers in UI/Monitor sources")
    func monitorSources() throws {
        let dir = Self.packageRoot.appendingPathComponent("Sources/AppUpdater/UI/Monitor")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !Self.excludedFiles.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty, "no Swift sources found in \(dir.path)")

        let hits = try files.flatMap { url in
            Self.violations(in: try String(contentsOf: url, encoding: .utf8), file: url.lastPathComponent)
        }
        #expect(hits.isEmpty, "Per-sample animation/blur in monitor views:\n\(hits.joined(separator: "\n"))")
    }

    /// ProgressRing (DesignSystem) drives live gauges and was made glow- and animation-free on purpose.
    @Test("ProgressRing stays free of forbidden modifiers")
    func progressRing() throws {
        let url = Self.packageRoot.appendingPathComponent("Sources/AppUpdater/UI/DesignSystem/Components.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let ring = try #require(Self.declaration(named: "struct ProgressRing", in: source), "ProgressRing not found")
        let hits = Self.violations(in: ring.text, file: url.lastPathComponent, firstLine: ring.line)
        #expect(hits.isEmpty, "Per-sample animation/blur in ProgressRing:\n\(hits.joined(separator: "\n"))")
    }

    // MARK: - Scanning

    /// `file:line: pattern` for each code line containing a forbidden pattern without the allow marker.
    static func violations(in source: String, file: String, firstLine: Int = 1) -> [String] {
        source.components(separatedBy: "\n").enumerated().flatMap { offset, line -> [String] in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !line.contains(allowMarker) else { return [] }
            return forbidden.filter { line.contains($0) }.map { "\(file):\(firstLine + offset): \($0)" }
        }
    }

    /// Text of the brace-delimited declaration starting at `prefix`, with its 1-based start line.
    static func declaration(named prefix: String, in source: String) -> (text: String, line: Int)? {
        guard let start = source.range(of: prefix) else { return nil }
        var depth = 0
        var end = source.endIndex
        scan: for index in source[start.lowerBound...].indices {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { end = source.index(after: index); break scan }
            default: break
            }
        }
        let line = source[..<start.lowerBound].filter { $0 == "\n" }.count + 1
        return (String(source[start.lowerBound..<end]), line)
    }
}
