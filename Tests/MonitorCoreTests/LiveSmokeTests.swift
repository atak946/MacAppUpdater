import Darwin
import Foundation
import Testing
@testable import MonitorCore

@Suite("Live samplers")
struct LiveSmokeTests {
    @Test("system sampler reports real memory, cores and disk")
    func system() async {
        let sampler = LiveSystemSampler()
        _ = await sampler.sample()
        let snapshot = await sampler.sample()
        #expect(snapshot.memory.totalBytes > 0)
        #expect(snapshot.memory.usedBytes <= snapshot.memory.totalBytes)
        #expect(!snapshot.perCoreUsage.isEmpty)
        #expect((0...1).contains(snapshot.cpuUsage))
        #expect(snapshot.disk.totalBytes > 0)
        #expect(snapshot.uptime > 0)
    }

    @Test("process sampler finds the current process")
    func processes() async throws {
        let sampler = LiveProcessSampler()
        _ = await sampler.sample()
        let processes = await sampler.sample()
        let me = try #require(processes.first { $0.pid == getpid() })
        #expect(me.memoryBytes > 0)
        #expect(me.threadCount > 0)
        #expect(me.executablePath != nil)
        #expect(!ProcessGrouper.group(processes).isEmpty)
    }

    @Test("port scanner completes")
    func ports() async {
        let ports = await LsofPortScanner().listeningPorts()
        #expect(ports.allSatisfy { $0.port > 0 })
    }
}
