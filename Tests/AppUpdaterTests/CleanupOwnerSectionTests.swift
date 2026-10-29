import Foundation
import MaintenanceCore
import Testing
@testable import AppUpdater

@Suite("Removed-app leftover sections")
@MainActor
struct CleanupOwnerSectionTests {
    private func item(_ name: String, owner: String, bytes: Int64) -> CleanupItem {
        CleanupItem(
            url: URL(fileURLWithPath: "/Users/test/Library/Preferences/\(name)"),
            category: .removedAppLeftovers, displayName: name, sizeInBytes: bytes, ownerBundleIdentifier: owner
        )
    }

    @Test("items are grouped by bundle identifier, largest app first")
    func grouping() {
        let items = [
            item("a1", owner: "org.a.App", bytes: 10), item("b1", owner: "org.b.App", bytes: 25),
            item("a2", owner: "org.a.App", bytes: 5),
        ]

        let sections = CleanupOwnerSection.sections(of: items)

        #expect(sections.map(\.bundleIdentifier) == ["org.b.App", "org.a.App"])
        #expect(sections.map(\.totalSize) == [25, 15])
        #expect(sections[1].items.map(\.displayName) == ["a1", "a2"])
    }

    @Test("toggling one app selects only its items")
    func toggleSection() {
        let items = [item("a1", owner: "org.a.App", bytes: 10), item("b1", owner: "org.b.App", bytes: 25)]
        let model = CleanupModel(scanner: FakeCleanupScanner(), cleaner: FakeCleanupCleaner())

        model.toggleItems([items[0]])

        #expect(model.selectionState(of: [items[0]]) == .all)
        #expect(model.selectionState(of: items) == .some)
        model.toggleItems([items[0]])
        #expect(model.selectionState(of: items) == .none)
    }
}
