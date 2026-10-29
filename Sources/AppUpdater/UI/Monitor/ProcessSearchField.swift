import AppKit
import SwiftUI

/// Inline glass search field of the Processes page. While the page is on screen ⌘F focuses this
/// field instead of the sidebar search: a local key monitor consumes the event before menu and
/// `.keyboardShortcut` handling, and is removed again when the field leaves the screen.
struct ProcessSearchField: View {
    @Binding var text: String

    @FocusState private var isFocused: Bool
    @State private var shortcut = CommandFShortcut()

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.Palette.brandTertiary : Theme.Palette.textTertiary)
            TextField("Search processes, PID or port", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onExitCommand { isFocused = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .transition(.opacity)
            }
            Text(verbatim: "⌘F")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .opacity(isFocused || !text.isEmpty ? 0 : 1)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Spacing.m - 2)
        .padding(.vertical, 7)
        .frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .fill(Color.white.opacity(isFocused ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(isFocused ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.Palette.hairline), lineWidth: 1)
        )
        .animation(Theme.Motion.hover, value: isFocused)
        .animation(Theme.Motion.hover, value: text.isEmpty)
        .onAppear { shortcut.install { isFocused = true } }
        .onDisappear { shortcut.remove() }
    }
}

/// Owns an `NSEvent` local monitor that turns ⌘F in the main window into `action`.
@MainActor
final class CommandFShortcut {
    private var monitor: Any?

    func install(_ action: @escaping @MainActor () -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isCommandF(event), event.window?.isMainWindow == true, event.window?.attachedSheet == nil else {
                return event
            }
            MainActor.assumeIsolated { action() }
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private nonisolated static func isCommandF(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "f"
    }
}
