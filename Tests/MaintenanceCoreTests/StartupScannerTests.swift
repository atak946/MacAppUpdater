import Foundation
import Testing
@testable import MaintenanceCore

@Suite("Startup scanner")
struct StartupScannerTests {
    @Test("discovers each folder with overrides, load state and signatures")
    func scansFolders() async throws {
        let home = try FakeHome()
        let user = try home.folder("LaunchAgents")
        let global = try home.folder("GlobalAgents")
        let daemons = try home.folder("LaunchDaemons")
        try plistData(["Label": "com.example.user", "Program": "/bin/sh", "Disabled": true])
            .write(to: user.appendingPathComponent("com.example.user.plist"))
        try plistData(["Label": "com.example.global", "ProgramArguments": ["/bin/ls"]])
            .write(to: global.appendingPathComponent("com.example.global.plist"))
        try plistData(["Label": "com.example.daemon", "Program": "/bin/ls"])
            .write(to: daemons.appendingPathComponent("com.example.daemon.plist"))
        try Data("not a plist".utf8).write(to: user.appendingPathComponent("broken.plist"))

        let runner = FakeCommandRunner([
            "print-disabled gui/501": CommandOutput(status: 0, standardOutput: "\"com.example.user\" => enabled"),
            "print-disabled system": CommandOutput(status: 0, standardOutput: "\"com.example.daemon\" => disabled"),
            "print system/com.example.daemon": CommandOutput(status: 0, standardOutput: ""),
        ])
        let signature = StartupSignature(signerName: "Software Signing", teamID: nil, isApple: true, isSigned: true)
        let scanner = LiveStartupScanner(
            locations: StartupLocations(
                userAgents: user, globalAgents: global, daemons: daemons, applicationFolders: [],
                backgroundItemsFile: home.url.appendingPathComponent("missing.btm")
            ),
            runner: runner, signatures: FixedSignatureReader(result: signature), uid: 501
        )

        let result = await scanner.scan()
        let byLabel = Dictionary(uniqueKeysWithValues: result.items.map { ($0.label, $0) })

        #expect(result.items.count == 3)
        #expect(result.loginItems == nil)
        #expect(byLabel["com.example.user"]?.isEnabled == true)
        #expect(byLabel["com.example.user"]?.kind == .userAgent)
        #expect(byLabel["com.example.global"]?.requiresAdmin == false)
        #expect(byLabel["com.example.daemon"]?.requiresAdmin == true)
        #expect(byLabel["com.example.daemon"]?.isEnabled == false)
        #expect(byLabel["com.example.daemon"]?.isLoaded == true)
        #expect(byLabel["com.example.global"]?.isLoaded == false)
        #expect(byLabel["com.example.global"]?.isAppleSigned == true)
    }

    @Test("unsigned means no identity; a missing signature isn't counted")
    func unsignedFlag() {
        #expect(makeItem(signature: .unsigned).isUnsigned)
        #expect(!makeItem(signature: nil).isUnsigned)
    }
}

@Suite("Startup signature reader")
struct StartupSignatureReaderTests {
    @Test("system binaries are Apple-signed; missing files yield nil")
    func readsAppleSignature() throws {
        let reader = SecStaticCodeSignatureReader()
        let signature = try #require(reader.signature(of: URL(fileURLWithPath: "/bin/ls")))
        #expect(signature.isApple && signature.isSigned)
        #expect(reader.signature(of: URL(fileURLWithPath: "/nonexistent/binary")) == nil)
    }
}
