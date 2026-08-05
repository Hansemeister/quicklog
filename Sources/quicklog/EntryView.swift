import AppKit
import SwiftUI

/// Detail pane: rendered entries for the selected day + composer for today.
struct EntryView: View {
    @ObservedObject var store: JournalStore
    @FocusState private var composerFocused: Bool
    @State private var showPreview = false

    var body: some View {
        VStack(spacing: 0) {
            entryList
            Divider()
            if store.isViewingToday {
                composer
            } else {
                readOnlyNotice
            }
        }
        .navigationTitle(store.selectedDay)
    }

    // MARK: Entries

    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.entries.isEmpty {
                        Text("No entries yet.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                    ForEach(store.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.time)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            MarkdownText(entry.body)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(20)
            }
            .onChange(of: store.entries.count) { _, _ in
                withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: store.selectedDay) { _, _ in
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    private var bottomAnchor: String { "bottom" }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.draft)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .focused($composerFocused)
                    .frame(minHeight: 90, maxHeight: 160)
                if store.draft.isEmpty {
                    Text("What's on your mind?  (markdown: # header, **bold**, *italic*, - bullet)")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            if showPreview && !store.draft.isEmpty {
                ScrollView {
                    MarkdownText(store.draft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                }
                .frame(maxHeight: 140)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
            }

            HStack(spacing: 10) {
                if let error = store.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("Preview", isOn: $showPreview)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                Button("Save") { store.saveDraft() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(.bar)
        .onAppear { composerFocused = true }
    }

    private var readOnlyNotice: some View {
        HStack {
            Image(systemName: "lock")
            Text("Past day — read only.")
            Spacer()
            Button("Jump to Today") { store.select(store.todayKey) }
                .controlSize(.small)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Markdown rendering

/// Minimal block-level markdown renderer: headers (`#`..`###`), bullet lists
/// (`-`/`*`/`+`) with nesting by indentation, and paragraphs. Inline `**bold**`,
/// `*italic*`, and `` `code` `` are handled by Foundation's markdown parser.
struct MarkdownText: View {
    private let blocks: [MarkdownBlock]

    init(_ text: String) {
        self.blocks = MarkdownBlock.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    inline(text)
                        .font(headingFont(level))
                        .padding(.top, level == 1 ? 6 : 4)
                case let .bullet(indent, text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(bulletGlyph(indent))
                            .foregroundStyle(.secondary)
                        inline(text)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case let .paragraph(text):
                    inline(text)
                case .blank:
                    Spacer().frame(height: 6)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(.title2, weight: .bold)
        case 2: return .system(.title3, weight: .semibold)
        default: return .system(.headline, weight: .semibold)
        }
    }

    private func bulletGlyph(_ indent: Int) -> String {
        switch indent % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case paragraph(String)
    case blank

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                if case .blank = blocks.last { continue }
                blocks.append(.blank)
                continue
            }

            if let level = headingLevel(trimmed) {
                let body = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(level, 3), text: body))
                continue
            }

            if let marker = bulletMarker(trimmed) {
                let leading = line.prefix(while: { $0 == " " }).count
                blocks.append(.bullet(indent: leading / 2, text: marker))
                continue
            }

            blocks.append(.paragraph(trimmed))
        }
        while case .blank = blocks.last { blocks.removeLast() }
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6 else { return nil }
        guard line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    /// `- text` / `* text` / `+ text` -> `text`
    private static func bulletMarker(_ line: String) -> String? {
        guard let first = line.first, "-*+".contains(first) else { return nil }
        let rest = line.dropFirst()
        guard rest.first == " " else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }
}
