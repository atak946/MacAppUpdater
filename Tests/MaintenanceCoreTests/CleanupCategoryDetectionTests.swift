import Foundation
import Testing
@testable import MaintenanceCore

@Suite("Cleanup category detection")
struct CleanupCategoryDetectionTests {
    private let mb = FakeHome.megabyte

    // MARK: Caches

    @Test("user caches skip system, own, small and package-manager caches")
    func userCaches() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/com.example.Editor/data.bin", bytes: 2 * mb)
        try home.file("Library/Caches/SomeTool/blob", bytes: 2 * mb)
        try home.file("Library/Caches/com.apple.Safari/cache.db", bytes: 2 * mb)
        try home.file("Library/Caches/com.macappupdater.AppUpdater/cache", bytes: 2 * mb)
        try home.file("Library/Caches/com.example.Tiny/x", bytes: 1_000)
        try home.file("Library/Caches/Homebrew/downloads/pkg.tar.gz", bytes: 2 * mb)
        try home.file("Library/Caches/Yarn/v6/pkg", bytes: 2 * mb)

        let report = try await home.scan([.userCaches, .packageManagerCaches])

        #expect(report.names(.userCaches).sorted() == ["SomeTool", "com.example.Editor"])
        let owners = Dictionary(uniqueKeysWithValues: report.items(.userCaches).map { ($0.displayName, $0.ownerBundleIdentifier) })
        #expect(owners["com.example.Editor"] == "com.example.Editor")
        #expect(owners["SomeTool"] == .some(nil))
        #expect(Set(report.items(.packageManagerCaches).map(\.displayName)) == ["Homebrew downloads", "Yarn cache"])
    }

    @Test("package-manager caches use friendly names")
    func packageManagerCaches() async throws {
        let home = try FakeHome()
        try home.file(".npm/_cacache/index", bytes: 4_096)
        try home.file(".gradle/caches/modules/jar", bytes: 4_096)
        try home.file(".nuget/packages/x/y.nupkg", bytes: 4_096)
        try home.file("Library/pnpm/store/v3/file", bytes: 4_096)
        try home.file("Library/Caches/CocoaPods/Pods/x", bytes: 4_096)
        try home.file("Library/Caches/org.swift.swiftpm/repositories/x", bytes: 4_096)

        let names = Set(try await home.scan([.packageManagerCaches]).items(.packageManagerCaches).map(\.displayName))

        #expect(names == ["npm cache", "Gradle caches", "NuGet packages", "pnpm store", "CocoaPods cache", "SwiftPM cache"])
    }

    // MARK: Logs

    @Test("logs include children and only old diagnostic reports")
    func logs() async throws {
        let home = try FakeHome()
        try home.file("Library/Logs/SomeApp/app.log", bytes: 4_096)
        try home.file("Library/Logs/DiagnosticReports/Old.ips", bytes: 4_096, ageInDays: 10)
        try home.file("Library/Logs/DiagnosticReports/New.ips", bytes: 4_096, ageInDays: 2)

        let report = try await home.scan([.logs])

        #expect(Set(report.names(.logs)) == ["SomeApp", "Old.ips"])
        #expect(report.items(.logs).contains { $0.displayName == "DiagnosticReports/Old.ips" })
    }

    // MARK: Developer

    @Test("DerivedData strips the Xcode hash from display names")
    func derivedData() async throws {
        let home = try FakeHome()
        try home.file("Library/Developer/Xcode/DerivedData/MyApp-abcdefghijklmnopqrstuvwxyz/Build/x", bytes: 4_096)
        try home.file("Library/Developer/Xcode/DerivedData/ModuleCache.noindex/y", bytes: 4_096)

        let names = Set(try await home.scan([.xcodeDerivedData]).items(.xcodeDerivedData).map(\.displayName))

        #expect(names == ["MyApp", "ModuleCache.noindex"])
    }

    @Test("archives are listed per archive inside date folders")
    func archives() async throws {
        let home = try FakeHome()
        try home.file("Library/Developer/Xcode/Archives/2026-01-01/MyApp 1.xcarchive/Info.plist", bytes: 4_096)
        try home.file("Library/Developer/Xcode/Archives/2026-02-01/Other.xcarchive/Info.plist", bytes: 4_096)

        let names = Set(try await home.scan([.xcodeArchives]).items(.xcodeArchives).map(\.displayName))

        #expect(names == ["MyApp 1", "Other"])
    }

    @Test("device support covers every platform folder")
    func deviceSupport() async throws {
        let home = try FakeHome()
        try home.file("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)/Symbols/x", bytes: 4_096)
        try home.file("Library/Developer/Xcode/watchOS DeviceSupport/10.0/x", bytes: 4_096)
        try home.file("Library/Developer/Xcode/visionOS DeviceSupport/1.0/x", bytes: 4_096)

        let names = Set(try await home.scan([.deviceSupport]).items(.deviceSupport).map(\.displayName))

        #expect(names == ["iOS — 17.0 (21A329)", "watchOS — 10.0", "visionOS — 1.0"])
    }

    @Test("simulator caches and trash list direct children")
    func simulatorAndTrash() async throws {
        let home = try FakeHome()
        try home.file("Library/Developer/CoreSimulator/Caches/dyld/x", bytes: 4_096)
        try home.file(".Trash/Old Report.pdf", bytes: 4_096)
        try home.file(".Trash/.DS_Store", bytes: 4_096)
        try home.file(".Trash/Folder/inner.txt", bytes: 4_096)

        let report = try await home.scan([.simulatorCaches, .trash])

        #expect(report.names(.simulatorCaches) == ["dyld"])
        #expect(Set(report.names(.trash)) == ["Old Report.pdf", "Folder"])
    }

    // MARK: Downloads and home

    @Test("only old installers with known extensions are reported")
    func oldInstallers() async throws {
        let home = try FakeHome()
        try home.file("Downloads/Old.dmg", bytes: 4_096, ageInDays: 45)
        try home.file("Downloads/Old.PKG", bytes: 4_096, ageInDays: 45)
        try home.file("Downloads/New.zip", bytes: 4_096, ageInDays: 3)
        try home.file("Downloads/Old.pdf", bytes: 4_096, ageInDays: 45)

        let names = Set(try await home.scan([.oldInstallers]).names(.oldInstallers))

        #expect(names == ["Old.dmg", "Old.PKG"])
    }

    @Test("large old files respect size, age and exclusions")
    func largeOldFiles() async throws {
        let home = try FakeHome()
        try home.file("Movies/old.mov", bytes: 2 * mb, ageInDays: 400)
        try home.file("Movies/recent.mov", bytes: 2 * mb, ageInDays: 10)
        try home.file("Movies/small.mov", bytes: 1_000, ageInDays: 400)
        try home.file("Library/Big/old.bin", bytes: 2 * mb, ageInDays: 400)
        try home.file(".hidden/old.bin", bytes: 2 * mb, ageInDays: 400)
        try home.file("Applications/Tool.app/Contents/Resources/big.bin", bytes: 2 * mb, ageInDays: 400)
        let config = CleanupScanConfiguration(largeFileMinimumSize: Int64(mb))

        let report = try await home.scan([.largeOldFiles], configuration: config)

        #expect(report.names(.largeOldFiles) == ["old.mov"])
        #expect(report.items(.largeOldFiles).first?.lastAccessed != nil)
    }

    @Test("large file walk stops at the depth limit")
    func largeOldFilesDepth() async throws {
        let home = try FakeHome()
        try home.file("a/b/c/d/deep.bin", bytes: 2 * mb, ageInDays: 400)
        try home.file("a/shallow.bin", bytes: 2 * mb, ageInDays: 400)
        let config = CleanupScanConfiguration(largeFileMinimumSize: Int64(mb), largeFileMaximumDepth: 2)

        let report = try await home.scan([.largeOldFiles], configuration: config)

        #expect(report.names(.largeOldFiles) == ["shallow.bin"])
    }

    @Test("an installer that is also a large old file is counted once")
    func noDoubleCountingAcrossCategories() async throws {
        let home = try FakeHome()
        try home.file("Downloads/Huge.dmg", bytes: 2 * mb, ageInDays: 400)
        let config = CleanupScanConfiguration(largeFileMinimumSize: Int64(mb))

        let report = try await home.scan([.oldInstallers, .largeOldFiles], configuration: config)

        #expect(report.names(.oldInstallers) == ["Huge.dmg"])
        #expect(report.items(.largeOldFiles).isEmpty)
    }
}
