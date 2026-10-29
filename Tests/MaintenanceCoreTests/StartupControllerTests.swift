import Foundation
import Testing
@testable import MaintenanceCore

@Suite("Startup controller")
struct StartupControllerTests {
    private let uid: uid_t = 501

    @Test("disabling a loaded agent boots it out, then disables it persistently")
    func disableCommands() throws {
        let item = makeItem(isLoaded: true)
        let commands = try LaunchctlStartupController.commands(enabling: false, item: item, uid: uid)
        #expect(commands == [
            LaunchctlCommand(["bootout", "gui/501", item.plistURL.path], toleratesFailure: true),
            LaunchctlCommand(["disable", "gui/501/com.example.agent"]),
        ])
    }

    @Test("enabling an unloaded agent enables it, then bootstraps the plist")
    func enableCommands() throws {
        let item = makeItem(isEnabled: false, isLoaded: false)
        let commands = try LaunchctlStartupController.commands(enabling: true, item: item, uid: uid)
        #expect(commands == [
            LaunchctlCommand(["enable", "gui/501/com.example.agent"]),
            LaunchctlCommand(["bootstrap", "gui/501", item.plistURL.path], toleratesFailure: true),
        ])
        let loaded = try LaunchctlStartupController.commands(enabling: true, item: makeItem(isLoaded: true), uid: uid)
        #expect(loaded.map(\.arguments.first) == ["enable"])
    }

    @Test("Apple items are never touched", arguments: [StartupItemKind.userAgent, .globalAgent, .daemon])
    func appleProtected(kind: StartupItemKind) async {
        let runner = FakeCommandRunner()
        let item = makeItem(label: "com.apple.Siri.agent", kind: kind)
        await #expect(throws: StartupControlError.appleItemProtected(label: item.label)) {
            try await LaunchctlStartupController(runner: runner, uid: uid).setEnabled(false, for: item)
        }
        #expect(runner.calls.isEmpty)
        #expect(!item.isControllable)
    }

    @Test("global agents live in the user's gui domain and need no administrator")
    func globalAgentWithoutAdmin() async throws {
        let item = makeItem(label: "us.zoom.updater", kind: .globalAgent, isLoaded: true)
        let runner = FakeCommandRunner(fallback: CommandOutput(status: 0, standardOutput: ""))
        let admin = FakeAdminRunner()
        let result = try await LaunchctlStartupController(runner: runner, adminRunner: admin, uid: uid).setEnabled(false, for: item)
        #expect(!item.requiresAdmin && item.isControllable)
        #expect(!result.isEnabled)
        #expect(runner.calls.last == ["disable", "gui/501/us.zoom.updater"])
        #expect(admin.batches.isEmpty)
    }

    @Test("daemons run their system-domain commands through one administrator prompt")
    func daemonUsesAdmin() async throws {
        let item = makeItem(label: "com.example.daemon", kind: .daemon, isLoaded: true)
        let runner = FakeCommandRunner()
        let admin = FakeAdminRunner()
        let result = try await LaunchctlStartupController(runner: runner, adminRunner: admin, uid: uid).setEnabled(false, for: item)
        #expect(item.requiresAdmin && item.isControllable)
        #expect(runner.calls.isEmpty)
        #expect(admin.batches == [[
            LaunchctlCommand(["bootout", "system", item.plistURL.path], toleratesFailure: true),
            LaunchctlCommand(["disable", "system/com.example.daemon"]),
        ]])
        #expect(!result.isEnabled && !result.isLoaded)
    }

    @Test("a cancelled administrator prompt changes nothing")
    func adminCancelled() async {
        let item = makeItem(label: "com.example.daemon", kind: .daemon)
        let admin = FakeAdminRunner(result: CommandOutput(status: 1, standardOutput: "", standardError: "User canceled. (-128)"))
        await #expect(throws: StartupControlError.cancelled) {
            try await LaunchctlStartupController(runner: FakeCommandRunner(), adminRunner: admin, uid: uid).setEnabled(false, for: item)
        }
    }

    @Test("labels that could break out of the command are refused before anything runs")
    func hostileLabelRefused() {
        let item = makeItem(label: "evil\"; rm -rf ~; \"", kind: .daemon)
        #expect(throws: StartupControlError.invalidLabel(item.label)) {
            try LaunchctlStartupController.commands(enabling: false, item: item, uid: uid)
        }
    }

    @Test("the administrator script quotes every argument and tolerates marked failures")
    func adminScriptQuoting() {
        let script = AdministratorScript.shellCommand(for: [
            LaunchctlCommand(["bootout", "system", "/Library/LaunchDaemons/it's.plist"], toleratesFailure: true),
            LaunchctlCommand(["disable", "system/com.example.daemon"]),
        ])
        #expect(script == "('/bin/launchctl' 'bootout' 'system' '/Library/LaunchDaemons/it'\\''s.plist' || true) && '/bin/launchctl' 'disable' 'system/com.example.daemon'")
        #expect(AdministratorScript.appleScriptSource(for: #"echo "a\b""#) == #"do shell script "echo \"a\\b\"" with administrator privileges"#)
    }

    @Test("a tolerated bootout failure still disables; a failed disable throws")
    func failureHandling() async throws {
        let item = makeItem(isLoaded: true)
        let bootout = "bootout gui/501 \(item.plistURL.path)"
        let tolerant = FakeCommandRunner([
            bootout: CommandOutput(status: 5, standardOutput: ""),
            "disable gui/501/com.example.agent": CommandOutput(status: 0, standardOutput: ""),
        ])
        let result = try await LaunchctlStartupController(runner: tolerant, uid: uid).setEnabled(false, for: item)
        #expect(!result.isEnabled)
        #expect(tolerant.calls.count == 2)

        let failing = FakeCommandRunner([bootout: CommandOutput(status: 0, standardOutput: "")])
        await #expect(throws: StartupControlError.self) {
            try await LaunchctlStartupController(runner: failing, uid: uid).setEnabled(false, for: item)
        }
    }

    @Test("a successful enable reports the item as loaded")
    func enableSucceeds() async throws {
        let runner = FakeCommandRunner(fallback: CommandOutput(status: 0, standardOutput: ""))
        let result = try await LaunchctlStartupController(runner: runner, uid: uid)
            .setEnabled(true, for: makeItem(isEnabled: false, isLoaded: false))
        #expect(result.isEnabled && result.isLoaded)
    }
}
