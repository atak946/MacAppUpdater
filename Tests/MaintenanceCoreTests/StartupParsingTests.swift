import Foundation
import Testing
@testable import MaintenanceCore

@Suite("Startup plist parsing")
struct StartupPlistParsingTests {
    @Test("reads label, program arguments and launch keys")
    func parsesFullJob() throws {
        let job = try LaunchdJobDefinition.parse(plistData([
            "Label": "com.example.agent",
            "ProgramArguments": ["/Applications/Example.app/Contents/MacOS/helper", "--quiet"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "StartInterval": 3600,
            "Disabled": true,
            "AssociatedBundleIdentifiers": "com.example.App",
        ]))
        #expect(job.label == "com.example.agent")
        #expect(job.executablePath == "/Applications/Example.app/Contents/MacOS/helper")
        #expect(job.runAtLoad)
        #expect(job.keepAlive)
        #expect(job.schedule == .interval(seconds: 3600))
        #expect(job.isDisabled)
        #expect(job.associatedBundleIdentifiers == ["com.example.App"])
    }

    @Test("Program wins over ProgramArguments and defaults are false")
    func programWins() throws {
        let job = try LaunchdJobDefinition.parse(plistData([
            "Label": "x", "Program": "/bin/sh", "ProgramArguments": ["sh", "-c", "true"],
        ]))
        #expect(job.executablePath == "/bin/sh")
        #expect(!job.runAtLoad && !job.keepAlive && !job.isDisabled)
        #expect(job.schedule == nil)
    }

    @Test("calendar intervals accept a dictionary or an array")
    func calendarSchedules() throws {
        let single = try LaunchdJobDefinition.parse(plistData(["Label": "a", "StartCalendarInterval": ["Hour": 3]]))
        let many = try LaunchdJobDefinition.parse(plistData([
            "Label": "b", "StartCalendarInterval": [["Weekday": 1], ["Weekday": 5, "Hour": 9]],
        ]))
        #expect(single.schedule == .calendar([["Hour": 3]]))
        #expect(many.schedule == .calendar([["Weekday": 1], ["Weekday": 5, "Hour": 9]]))
    }

    @Test("missing label and non-dictionary plists are rejected")
    func rejectsInvalid() throws {
        #expect(throws: LaunchdJobDefinition.ParseError.missingLabel) {
            try LaunchdJobDefinition.parse(plistData(["Program": "/bin/ls"]))
        }
        let array = try PropertyListSerialization.data(fromPropertyList: ["a"], format: .xml, options: 0)
        #expect(throws: LaunchdJobDefinition.ParseError.notADictionary) { try LaunchdJobDefinition.parse(array) }
    }

    @Test("bare executables resolve through the search path")
    func resolvesExecutable() {
        let found = LiveStartupScanner.resolveExecutable("python3") { $0 == "/usr/bin/python3" }
        #expect(found?.path == "/usr/bin/python3")
        #expect(LiveStartupScanner.resolveExecutable("/opt/x") { _ in false }?.path == "/opt/x")
        #expect(LiveStartupScanner.resolveExecutable("rel/path") { _ in true } == nil)
        #expect(LiveStartupScanner.resolveExecutable(nil) { _ in true } == nil)
    }
}

@Suite("launchctl output parsing")
struct LaunchctlOutputParsingTests {
    @Test("print-disabled maps enabled/disabled and legacy true/false")
    func parsesOverrides() {
        let output = """
        disabled services = {
        \t"com.example.on" => enabled
        \t"com.example.off" => disabled
        \t"com.legacy.off" => true
        \t"com.legacy.on" => false
        }
        login item associations = {
        }
        """
        let overrides = LaunchctlOutputParser.parseDisabledOverrides(output)
        #expect(overrides == ["com.example.on": true, "com.example.off": false, "com.legacy.off": false, "com.legacy.on": true])
    }

    @Test("print reads top-level properties and skips nested blocks")
    func parsesService() {
        let output = """
        gui/501/com.example.agent = {
        \tactive count = 1
        \tpath = /Users/me/Library/LaunchAgents/com.example.agent.plist
        \tstate = running
        \targuments = {
        \t\tstate = nested
        \t}
        \tpid = 812
        }
        """
        let properties = LaunchctlOutputParser.parseServiceProperties(output)
        #expect(properties["state"] == "running")
        #expect(properties["pid"] == "812")
        #expect(properties["path"] == "/Users/me/Library/LaunchAgents/com.example.agent.plist")
        #expect(LaunchctlOutputParser.isRunning(output))
        #expect(!LaunchctlOutputParser.isRunning("x = {\n\tstate = not running\n}"))
    }
}

@Suite("Startup owner resolution")
struct StartupOwnerResolverTests {
    private let apps = [
        StartupAppCandidate(name: "Chrome", bundleIdentifier: "com.google.Chrome", url: URL(fileURLWithPath: "/Applications/Google Chrome.app")),
        StartupAppCandidate(name: "Example", bundleIdentifier: "com.example.App", url: URL(fileURLWithPath: "/Applications/Example.app")),
    ]

    @Test("the outermost app in the executable path wins")
    func outermostApp() {
        let resolver = StartupOwnerResolver(apps: apps)
        let exe = URL(fileURLWithPath: "/Applications/Example.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper")
        let owner = resolver.owner(executable: exe, label: "unrelated", associated: [])
        #expect(owner?.url.path == "/Applications/Example.app")
        #expect(owner?.name == "Example")
    }

    @Test("associated ids, then label prefix, otherwise nothing")
    func fallbacks() {
        let resolver = StartupOwnerResolver(apps: apps)
        let tool = URL(fileURLWithPath: "/usr/local/bin/tool")
        #expect(resolver.owner(executable: tool, label: "x", associated: ["COM.EXAMPLE.APP"])?.name == "Example")
        #expect(resolver.owner(executable: tool, label: "com.google.keystone.agent", associated: [])?.name == "Chrome")
        #expect(resolver.owner(executable: tool, label: "com.other.agent", associated: []) == nil)
    }
}
