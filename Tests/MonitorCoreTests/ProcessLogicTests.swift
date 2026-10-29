import Foundation
import Testing
@testable import MonitorCore

/// Builds a snapshot with sensible defaults for tests.
func makeProcess(pid: Int32, name: String = "proc", path: String? = nil, bundleID: String? = nil,
                 cpu: Double = 0, memory: UInt64 = 0, kind: ProcessKind = .user) -> ProcessSnapshot {
    let bundleURL = path.flatMap(ProcessClassifier.outermostAppURL(forExecutablePath:))
    return ProcessSnapshot(pid: pid, parentPID: 1, name: name, executablePath: path, bundleURL: bundleURL,
                           bundleIdentifier: bundleID, userID: 501, cpuPercent: cpu, memoryBytes: memory,
                           threadCount: 1, startDate: nil, kind: kind)
}

// MARK: - Classifier

@Suite("Process classifier")
struct ProcessClassifierTests {
    @Test("outermost app for nested helpers")
    func nested() {
        let path = "/Applications/Foo.app/Contents/Frameworks/Foo Helper.framework/Helpers/Foo Helper (GPU).app/Contents/MacOS/Foo Helper (GPU)"
        #expect(ProcessClassifier.outermostAppURL(forExecutablePath: path)?.path == "/Applications/Foo.app")
        #expect(ProcessClassifier.outermostAppURL(forExecutablePath: "/Applications/Bar.app/Contents/MacOS/Bar")?.path
                == "/Applications/Bar.app")
    }

    @Test("no bundle for plain binaries or a bare .app path")
    func noBundle() {
        #expect(ProcessClassifier.outermostAppURL(forExecutablePath: "/usr/libexec/trustd") == nil)
        #expect(ProcessClassifier.outermostAppURL(forExecutablePath: "/Applications/Weird.app") == nil)
    }

    @Test("main executable detection")
    func mainExecutable() {
        let bundle = URL(fileURLWithPath: "/Applications/Foo.app")
        #expect(ProcessClassifier.isMainExecutable("/Applications/Foo.app/Contents/MacOS/Foo", of: bundle))
        #expect(!ProcessClassifier.isMainExecutable("/Applications/Foo.app/Contents/MacOS/sub/Foo", of: bundle))
        #expect(!ProcessClassifier.isMainExecutable("/Applications/Foo.app/Contents/Frameworks/X.app/Contents/MacOS/X", of: bundle))
        #expect(!ProcessClassifier.isMainExecutable(nil, of: bundle))
    }

    @Test("kind rules")
    func kinds() {
        #expect(ProcessClassifier.kind(name: "anything", path: nil, userID: 501, pid: 1) == .critical)
        #expect(ProcessClassifier.kind(name: "WindowServer", path: nil, userID: 88, pid: 400) == .critical)
        #expect(ProcessClassifier.kind(name: "mds_stores", path: nil, userID: 0, pid: 400) == .system)
        #expect(ProcessClassifier.kind(name: "Safari", path: "/System/Volumes/x", userID: 501, pid: 400) == .user)
        #expect(ProcessClassifier.kind(name: "foo", path: "/usr/libexec/foo", userID: 501, pid: 400) == .system)
        #expect(ProcessClassifier.kind(name: "rootd", path: "/opt/rootd", userID: 0, pid: 400) == .system)
        #expect(ProcessClassifier.kind(name: "node", path: "/opt/homebrew/bin/node", userID: 501, pid: 400) == .user)
    }
}

// MARK: - CPU %

@Suite("Process CPU math")
struct ProcessCPUMathTests {
    @Test("tick conversion with timebase")
    func conversion() {
        #expect(ProcessCPUMath.nanoseconds(fromTicks: 24, numer: 125, denom: 3) == 1000)
        #expect(ProcessCPUMath.nanoseconds(fromTicks: 1000, numer: 1, denom: 1) == 1000)
        #expect(ProcessCPUMath.nanoseconds(fromTicks: 7, numer: 1, denom: 0) == 7)
        #expect(ProcessCPUMath.nanoseconds(fromTicks: UInt64.max, numer: 125, denom: 3) == UInt64.max)
    }

    @Test("percent of one core")
    func percent() {
        #expect(ProcessCPUMath.percent(previousNanos: 0, currentNanos: 500, elapsedNanos: 1000) == 50)
        #expect(ProcessCPUMath.percent(previousNanos: 0, currentNanos: 2000, elapsedNanos: 1000) == 200)
        #expect(ProcessCPUMath.percent(previousNanos: nil, currentNanos: 500, elapsedNanos: 1000) == 0)
        #expect(ProcessCPUMath.percent(previousNanos: 900, currentNanos: 500, elapsedNanos: 1000) == 0)
        #expect(ProcessCPUMath.percent(previousNanos: 0, currentNanos: 500, elapsedNanos: 0) == 0)
    }

    @Test("display name prefers the untruncated file name")
    func displayName() {
        #expect(ProcessReader.displayName(short: "Google Chrome He", path: "/x/Google Chrome Helper (GPU)") == "Google Chrome Helper (GPU)")
        #expect(ProcessReader.displayName(short: "launchd", path: nil) == "launchd")
        #expect(ProcessReader.displayName(short: "", path: "/bin/zsh") == "zsh")
        #expect(ProcessReader.displayName(short: "Code Helper", path: "/x/Electron") == "Code Helper")
    }
}

// MARK: - Catalog

@Suite("Known process catalog")
struct KnownProcessCatalogTests {
    @Test("exact lookups")
    func exact() {
        #expect(KnownProcessCatalog.info(forProcessNamed: "mds_stores")?.summary == "Spotlight indexing")
        #expect(KnownProcessCatalog.info(forProcessNamed: "WindowServer")?.kind == .critical)
        #expect(KnownProcessCatalog.info(forProcessNamed: "bird")?.summary == "iCloud sync")
        #expect(KnownProcessCatalog.info(forProcessNamed: "backupd")?.summary == "Time Machine")
    }

    @Test("prefix lookups and misses")
    func prefix() {
        #expect(KnownProcessCatalog.info(forProcessNamed: "com.apple.WebKit.WebContent")?.kind == .user)
        #expect(KnownProcessCatalog.info(forProcessNamed: "mdworker_shared")?.summary == "Spotlight indexing")
        #expect(KnownProcessCatalog.info(forProcessNamed: "Google Chrome Helper (Renderer)") != nil)
        #expect(KnownProcessCatalog.info(forProcessNamed: "my-own-tool") == nil)
    }
}
