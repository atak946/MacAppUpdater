import Darwin
import Foundation
import os
import Testing
@testable import MonitorCore

// MARK: - lsof

@Suite("lsof parser")
struct LsofOutputParserTests {
    @Test("TCP, UDP, IPv6, wildcards and duplicates")
    func parse() {
        let output = """
        p1134
        f11
        PTCP
        n*:61711
        f15
        PTCP
        n*:61711
        f19
        PTCP
        n127.0.0.1:8080
        p1157
        f10
        PUDP
        n*:*
        f18
        PUDP
        n*:5353
        f20
        PTCP
        n[::1]:631
        f21
        PUDP
        n192.168.1.2:5000->1.2.3.4:443
        """
        let ports = LsofOutputParser.parse(output)
        #expect(ports == [
            ListeningPort(pid: 1157, port: 631, transport: "TCP", address: "::1"),
            ListeningPort(pid: 1157, port: 5000, transport: "UDP", address: "192.168.1.2"),
            ListeningPort(pid: 1157, port: 5353, transport: "UDP", address: "*"),
            ListeningPort(pid: 1134, port: 8080, transport: "TCP", address: "127.0.0.1"),
            ListeningPort(pid: 1134, port: 61711, transport: "TCP", address: "*"),
        ])
    }

    @Test("malformed input is ignored")
    func malformed() {
        #expect(LsofOutputParser.parse("").isEmpty)
        #expect(LsofOutputParser.parse("n*:80\npabc\nPTCP\nn*:80").isEmpty)
        #expect(LsofOutputParser.endpoint(fromName: "noport") == nil)
        #expect(LsofOutputParser.endpoint(fromName: ":80") == nil)
        #expect(LsofOutputParser.endpoint(fromName: "[fe80:4::1]:123")?.address == "fe80:4::1")
    }
}

// MARK: - Terminator

@Suite("Signal terminator")
struct SignalProcessTerminatorTests {
    /// Records signals sent by the terminator.
    final class Recorder: Sendable {
        let signals = OSAllocatedUnfairLock<[(Int32, Int32)]>(initialState: [])
        let appCalls = OSAllocatedUnfairLock<[Int32]>(initialState: [])
    }

    private func terminator(_ recorder: Recorder, errno code: Int32 = 0, appHandles: Bool = false) -> SignalProcessTerminator {
        SignalProcessTerminator(
            sendSignal: { pid, signal in recorder.signals.withLock { $0.append((pid, signal)) }; return code },
            terminateApp: { pid, _ in recorder.appCalls.withLock { $0.append(pid) }; return appHandles },
            currentPID: 777
        )
    }

    @Test("refuses critical, pid ≤ 1 and the current process without signalling")
    func refusals() async {
        let recorder = Recorder()
        let sut = terminator(recorder)
        for process in [makeProcess(pid: 500, name: "WindowServer", kind: .critical),
                        makeProcess(pid: 1, name: "launchd"), makeProcess(pid: 0, name: "kernel_task"),
                        makeProcess(pid: 777, name: "me")] {
            await #expect(throws: TerminationError.protectedProcess(process.name)) {
                try await sut.terminate(process, mode: .force)
            }
        }
        #expect(recorder.signals.withLock { $0.isEmpty })
    }

    @Test("sends SIGTERM or SIGKILL")
    func signals() async throws {
        let recorder = Recorder()
        let sut = terminator(recorder)
        try await sut.terminate(makeProcess(pid: 42), mode: .graceful)
        try await sut.terminate(makeProcess(pid: 43), mode: .force)
        let sent = recorder.signals.withLock { $0 }
        #expect(sent.map(\.0) == [42, 43])
        #expect(sent.map(\.1) == [SIGTERM, SIGKILL])
    }

    @Test("apps are asked to quit first; signals are the fallback")
    func apps() async throws {
        let app = makeProcess(pid: 50, path: "/Applications/Foo.app/Contents/MacOS/Foo")
        let handled = Recorder()
        try await terminator(handled, appHandles: true).terminate(app, mode: .graceful)
        #expect(handled.appCalls.withLock { $0 } == [50])
        #expect(handled.signals.withLock { $0.isEmpty })
        let fallback = Recorder()
        try await terminator(fallback, appHandles: false).terminate(app, mode: .graceful)
        #expect(fallback.signals.withLock { $0.count } == 1)
    }

    @Test("errno mapping", arguments: [
        (EPERM, TerminationError.notPermitted), (ESRCH, .noSuchProcess), (EINVAL, .failed(EINVAL)),
    ])
    func errors(code: Int32, expected: TerminationError) async {
        let sut = terminator(Recorder(), errno: code)
        await #expect(throws: expected) { try await sut.terminate(makeProcess(pid: 99), mode: .graceful) }
        #expect(SignalProcessTerminator.error(fromErrno: 0) == nil)
    }
}
