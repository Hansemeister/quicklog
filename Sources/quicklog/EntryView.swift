import AppKit
import SwiftUI

/// Detail pane: rendered entries for the selected day + composer for today.
struct EntryView: View {
    @ObservedObject var store: JournalStore
    @FocusState private var composerFocused: Bool
    @State private var showPreview = false
    @State private var hoveredEntryID: String?
    @FocusState private var editorFocused: Bool

    /// Composer height, dragged via the divider and remembered across launches.
    @AppStorage("quicklog.composerHeight") private var composerHeight: Double = 150
    @State private var dragStartHeight: Double?

    private let minComposerHeight: Double = 110
    private let maxComposerHeight: Double = 520
    /// The entry list never shrinks past this, so the handle always stays
    /// reachable and both panes stay usable.
    private let minEntriesHeight: Double = 120
    private let handleHeight: Double = 11

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                entryList
                if store.isViewingToday {
                    resizeHandle(available: geo.size.height)
                    composer
                        .frame(height: clamped(composerHeight, available: geo.size.height))
                } else {
                    Divider()
                    pastDayNotice
                }
            }
        }
        .navigationTitle(store.selectedDay)
    }

    /// Keeps the composer between its own minimum and whatever leaves the entry
    /// list at least `minEntriesHeight` — also applied on render, so shrinking
    /// the window can't strand the divider off-screen.
    private func clamped(_ height: Double, available: Double) -> Double {
        let ceiling = max(minComposerHeight, available - minEntriesHeight - handleHeight)
        return min(max(height, minComposerHeight), min(maxComposerHeight, ceiling))
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
                        entryRow(entry)
                            .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(20)
                .animation(.easeInOut(duration: 0.22), value: store.entries.map(\.id))
                .animation(.easeInOut(duration: 0.12), value: hoveredEntryID)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: store.entries.count) { _, _ in
                withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: store.selectedDay) { _, _ in
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    private func entryRow(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.time)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if store.isEditing(entry) {
                    Text("editing")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
                Spacer()
            }

            if store.isEditing(entry) {
                inlineEditor
            } else {
                MarkdownText(entry.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(
                    hoveredEntryID == entry.id && !store.isEditing(entry) ? 0.06 : 0
                ))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredEntryID = entry.id
            } else if hoveredEntryID == entry.id {
                hoveredEntryID = nil
            }
        }
        // Click the text to edit it. `simultaneousGesture` so the text view still
        // gets the click for selection, and TapGesture's own movement threshold
        // means a drag to highlight for copying does not trigger this.
        .simultaneousGesture(
            TapGesture().onEnded {
                guard !store.isEditing(entry) else { return }
                store.beginEdit(entry)
            }
        )
        .contextMenu {
            Button("Edit") { store.beginEdit(entry) }
            Button("Delete", role: .destructive) { store.delete(entry) }
        }
        // Fade + collapse on delete — the macOS convention for a row leaving a
        // list (Mail, Reminders, Notes).
        .transition(
            .asymmetric(
                insertion: .opacity,
                removal: .opacity.combined(with: .scale(scale: 0.92, anchor: .topLeading))
            )
        )
    }

    /// In-place editor for an existing entry. Writes back to that entry's own
    /// day file — the file name and `## HH:mm` stamp are untouched. Saving an
    /// empty body deletes the entry (undo with the toolbar button).
    private var inlineEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $store.editDraft)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .frame(minHeight: 90, maxHeight: 280)
                .padding(2)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3))
                )
                .onAppear { editorFocused = true }
                .onChange(of: editorFocused) { _, focused in
                    // SwiftUI parks the caret at offset 0 when the editor takes
                    // focus, and writing a TextSelection back loses the race
                    // with it. Move the caret on the text view itself, once
                    // focus has actually landed.
                    if focused { DispatchQueue.main.async { moveCaretToEnd() } }
                }
            HStack(spacing: 8) {
                Text("Clear the text to delete this entry.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.cancelEdit() }
                Button(store.editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                       ? "Delete" : "Save") { store.commitEdit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var bottomAnchor: String { "bottom" }

    /// Puts the caret at the end of whichever text view currently has focus —
    /// the inline editor, when this runs.
    private func moveCaretToEnd() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        let end = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
        editor.scrollRangeToVisible(NSRange(location: end, length: 0))
    }

    // MARK: Resizable split

    /// Drag to change the entries/composer ratio.
    ///
    /// The gesture must measure in `.global` space: in local space the handle
    /// moves as the height changes, so each frame reads a shifted origin and the
    /// divider oscillates under the cursor.
    private func resizeHandle(available: Double) -> some View {
        ZStack {
            Divider()
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 44, height: 4)
        }
        .frame(height: handleHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = dragStartHeight ?? composerHeight
                    if dragStartHeight == nil { dragStartHeight = base }
                    let dy = value.location.y - value.startLocation.y
                    composerHeight = clamped(base - dy, available: available)
                }
                .onEnded { _ in dragStartHeight = nil }
        )
        .help("Drag to resize")
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.draft)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .focused($composerFocused)
                    .frame(maxHeight: .infinity)
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
                .frame(maxHeight: max(60, composerHeight * 0.4))
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

    private var pastDayNotice: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
            Text("Past day — edit or delete entries here; new entries go to today.")
            Spacer()
            if let error = store.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
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
