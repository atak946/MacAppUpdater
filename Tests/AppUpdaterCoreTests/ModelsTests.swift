import Testing
import Foundation
@testable import AppUpdaterCore

@Test func packageFormatFromExtension() {
    #expect(PackageFormat(fileURL: URL(fileURLWithPath: "/tmp/a.DMG")) == .dmg)
    #expect(PackageFormat(fileURL: URL(fileURLWithPath: "/tmp/a.pkg")) == .pkg)
    #expect(PackageFormat(fileURL: URL(fileURLWithPath: "/tmp/a.tar")) == .unknown)
}
