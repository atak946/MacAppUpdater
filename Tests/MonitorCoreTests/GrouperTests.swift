import Foundation
import Testing
@testable import MonitorCore

@Suite("Process grouper")
struct ProcessGrouperTests {
    private let fooMain = "/Applications/Foo.app/Contents/MacOS/Foo"
    private let fooHelper = "/Applications/Foo.app/Contents/Frameworks/H.framework/Helpers/Foo Helper.app/Contents/MacOS/Foo Helper"

    @Test("helpers group under the outermost app with main process first")
    func grouping() {
        let groups = ProcessGrouper.group([
            makeProcess(pid: 10, name: "Foo Helper", path: fooHelper, bundleID: "com.foo", cpu: 5),
            makeProcess(pid: 20, name: "Foo", path: fooMain, bundleID: "com.foo", cpu: 1),
            makeProcess(pid: 30, name: "Foo Helper", path: fooHelper, bundleID: "com.foo", cpu: 9),
            makeProcess(pid: 40, name: "zsh", path: "/bin/zsh"),
        ])
        #expect(groups.count == 2)
        let foo = groups[0]
        #expect(foo.id == "com.foo")
        #expect(foo.name == "Foo")
        #expect(foo.processes.map(\.pid) == [20, 30, 10])
        #expect(foo.cpuPercent == 15)
        #expect(groups[1].id == "pid:40")
        #expect(groups[1].name == "zsh")
    }

    @Test("lowest pid is main when no Contents/MacOS executable is present")
    func lowestPID() {
        let groups = ProcessGrouper.group([
            makeProcess(pid: 9, path: fooHelper, cpu: 1),
            makeProcess(pid: 3, path: fooHelper, cpu: 0),
        ])
        #expect(groups[0].processes.first?.pid == 3)
        #expect(groups[0].id == "/Applications/Foo.app")
    }

    @Test("group kind is the most protective member kind")
    func kind() {
        let groups = ProcessGrouper.group([
            makeProcess(pid: 1, path: fooMain, kind: .user),
            makeProcess(pid: 2, path: fooHelper, kind: .critical),
            makeProcess(pid: 3, path: fooHelper, kind: .system),
        ])
        #expect(groups[0].kind == .critical)
        #expect(ProcessGrouper.mostProtectiveKind([.user, .system]) == .system)
        #expect(ProcessGrouper.mostProtectiveKind([]) == .user)
    }

    @Test("sorted by cpu desc then memory desc")
    func sorting() {
        let groups = ProcessGrouper.group([
            makeProcess(pid: 1, name: "a", cpu: 1, memory: 10),
            makeProcess(pid: 2, name: "b", cpu: 5, memory: 1),
            makeProcess(pid: 3, name: "c", cpu: 1, memory: 99),
            makeProcess(pid: 4, name: "d", cpu: 1, memory: 99),
        ])
        #expect(groups.map(\.id) == ["pid:2", "pid:3", "pid:4", "pid:1"])
    }

    @Test("system tools an app spawns stay standalone and out of its cpu")
    func spawnedSystemTools() {
        let groups = ProcessGrouper.group([
            makeProcess(pid: 20, name: "Foo", path: fooMain, bundleID: "com.foo", cpu: 4),
            makeProcess(pid: 21, parentPID: 20, name: "Foo Helper", path: fooHelper, bundleID: "com.foo", cpu: 2),
            makeProcess(pid: 22, parentPID: 20, name: "spctl", path: "/usr/sbin/spctl", cpu: 180, kind: .system),
            makeProcess(pid: 23, parentPID: 20, name: "codesign", path: "/usr/bin/codesign", cpu: 90, kind: .system),
            makeProcess(pid: 24, parentPID: 20, name: "XPCService", path: "/System/Library/Frameworks/X.framework/XPCServices/S.xpc/Contents/MacOS/S", cpu: 30, kind: .system),
            makeProcess(pid: 25, parentPID: 1, name: "Fetch", path: "/Applications/Foo.app/Contents/XPCServices/Fetch.xpc/Contents/MacOS/Fetch", cpu: 1),
        ])
        let foo = groups.first { $0.id == "com.foo" }
        #expect(foo?.processes.map(\.pid) == [20, 21, 25])
        #expect(foo?.cpuPercent == 7)
        #expect(Set(groups.filter { $0.id != "com.foo" }.map(\.id)) == ["pid:22", "pid:23", "pid:24"])
    }

    @Test("two copies of one app get distinct ids")
    func duplicateBundleIDs() {
        let groups = ProcessGrouper.group([
            makeProcess(pid: 1, path: fooMain, bundleID: "com.foo"),
            makeProcess(pid: 2, path: "/Users/me/Foo.app/Contents/MacOS/Foo", bundleID: "com.foo"),
        ])
        #expect(Set(groups.map(\.id)) == ["/Applications/Foo.app", "/Users/me/Foo.app"])
    }
}
