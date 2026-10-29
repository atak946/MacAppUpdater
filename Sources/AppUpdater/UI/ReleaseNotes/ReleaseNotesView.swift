import AppKit
import AppUpdaterCore
import os
import SwiftUI

/// Renders an update's release notes: HTML in a script-free web view, Markdown natively.
struct ReleaseNotesView: View {
    let notes: ReleaseNotes?
    var loader: any ReleaseNotesLoading = ReleaseNotesLoader()

    private enum Phase: Equatable {
        case loading
        case loaded(ReleaseNotesContent)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    private static let logger = Logger(subsystem: "com.macappupdater", category: "ReleaseNotesView")

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .dark)
            .tint(Theme.Palette.brandTertiary)
            .task(id: notes) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: Theme.Spacing.s) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Loading release notes…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        case .failed(let message):
            NotesStateView(symbol: "doc.text.magnifyingglass", tint: Theme.Palette.warning,
                           title: String(localized: "Release notes unavailable"), message: message) {
                if case .remote(let url) = notes {
                    Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.secondary)
                        .controlSize(.small)
                }
            }
        case .loaded(let loaded):
            loadedView(loaded)
        }
    }

    @ViewBuilder
    private func loadedView(_ content: ReleaseNotesContent) -> some View {
        switch content {
        case .html(let html, let baseURL):
            ReleaseNotesWebView(html: html, baseURL: baseURL)
        case .markdown(let markdown):
            textScroll(Text(MarkdownRenderer.render(markdown)))
        case .plainText(let text):
            textScroll(Text(text).font(.system(.callout, design: .monospaced)))
        case .empty:
            NotesStateView(symbol: "doc.text", tint: Theme.Palette.brand,
                           title: String(localized: "No release notes"),
                           message: String(localized: "The developer didn't publish notes for this version.")) {
                EmptyView()
            }
        }
    }

    private func textScroll(_ text: Text) -> some View {
        ScrollView {
            text
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    private func load() async {
        guard let notes else {
            phase = .loaded(.empty)
            return
        }
        phase = .loading
        do {
            phase = .loaded(try await loader.load(notes))
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Loading release notes failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Compact glass state (empty / error) sized for the notes card and popover.
private struct NotesStateView<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.white, tint], startPoint: .top, endPoint: .bottom))
                .glow(tint, radius: 8, opacity: 0.7)
                .frame(width: 44, height: 44)
                .background(Circle().fill(tint.opacity(0.14)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.textGradient)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 320)
            actions
        }
        .padding(Theme.Spacing.l)
    }
}

/// Converts Markdown into an `AttributedString` that keeps block structure,
/// since SwiftUI `Text` ignores presentation intents (paragraphs would run together).
enum MarkdownRenderer {
    static func render(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return AttributedString(markdown)
        }
        return parsed.runs[\.presentationIntent].reduce(into: AttributedString()) { result, run in
            let (intent, range) = run
            if !result.characters.isEmpty { result.append(AttributedString(separator(for: intent))) }
            result.append(styledBlock(AttributedString(parsed[range]), intent: intent))
        }
    }

    private static func separator(for intent: PresentationIntent?) -> String {
        isListItem(intent) ? "\n" : "\n\n"
    }

    private static func styledBlock(_ block: AttributedString, intent: PresentationIntent?) -> AttributedString {
        guard let intent else { return block }
        var styled = block
        for component in intent.components {
            switch component.kind {
            case .header(let level):
                let font: Font = level <= 1 ? .title2.bold() : (level == 2 ? .title3.bold() : .headline)
                styled.font = font
            case .codeBlock:
                let font: Font = .system(.callout, design: .monospaced)
                styled.font = font
            case .blockQuote:
                styled.foregroundColor = .secondary
            default:
                break
            }
        }
        return AttributedString(listPrefix(for: intent)) + styled
    }

    private static func isListItem(_ intent: PresentationIntent?) -> Bool {
        intent?.components.contains { if case .listItem = $0.kind { true } else { false } } ?? false
    }

    private static func listPrefix(for intent: PresentationIntent) -> String {
        let components = intent.components
        guard let itemIndex = components.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
              case .listItem(let ordinal) = components[itemIndex].kind
        else { return "" }
        let depth = components.filter { if case .listItem = $0.kind { true } else { false } }.count
        let indent = String(repeating: "    ", count: max(depth - 1, 0))
        let isOrdered = components.dropFirst(itemIndex + 1).first.map {
            if case .orderedList = $0.kind { true } else { false }
        } ?? false
        return indent + (isOrdered ? "\(ordinal). " : "•  ")
    }
}
