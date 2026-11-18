import Testing
import Foundation
@testable import AppUpdaterCore

@Test func packageFormatFromExtension() {
    #expect(PackageFormat(fileURL: URL(fileURLWithPath: "/tmp/a.DMG")) == .dmg)
    #expect(PackageFormat(fileURL: URL(fileURLWithPath: "/tmp/a.pkg")) == .pkg)
    #expect(PackageFormat(fileURL: URL(fileURLWithPath: "/tmp/a.7z")) == .unknown)
    #expect(PackageFormat(fileURL: URL(fileURLWithPath: "/tmp/a.gz")) == .unknown)
    for name in ["a.tar", "a.tar.gz", "A.TGZ", "a.tar.xz", "a.tar.bz2", "a.tbz2", "a.txz"] {
        #expect(PackageFormat(fileURL: URL(fileURLWithPath: "/tmp/\(name)")) == .tarball)
    }
}
