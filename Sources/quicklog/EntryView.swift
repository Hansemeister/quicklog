import AppKit
import SwiftUI

/// Detail pane: rendered entries for the selected day + composer for today.
struct EntryView: View {
    @ObservedObject var store: JournalStore
    @FocusState private var composerFocused: Bool
    /// Fallback focus for the inline editor, used only when the AppKit route
    /// below fails — see `focusEditor`.
    @FocusState private var editorFocused: Bool
    @State private var showPreview = false
    @State private var hoveredEntryID: String?
    /// The checkbox the cursor is currently over, if any. A click on the entry
    /// resolves this one instead of opening the editor.
    @State private var hoveredBox: HoveredBox?
    /// Which end of the next editor the caret belongs at — top when arriving from
    /// above. Written by the arrow-key monitor.
    @State private var arrivingFromAbove = false

    /// Composer height, dragged via the divider and remembered across launches.
    @AppStorage("quicklog.composerHeight") private var composerHeight: Double = 150

    private let minComposerHeight: Double = 110
    private let maxComposerHeight: Double = 520
    /// The entry list never shrinks past this, so the handle always stays
    /// reachable and both panes stay usable.
    private let minEntriesHeight: Double = 120
    /// Definite heights for the past-day footer, so the entry list above it can
    /// be given one too. `pastDayNoticeHeight` fits the caption plus its padding.
    private let pastDayNoticeHeight: Double = 38
    private let dividerThickness: Double = 1

    /// A hovered checkbox and the entry it belongs to. The line number alone is
    /// not an identity: two entries both have a line 0, so one row's exit would
    /// clear the other row's box — and the click that followed opened the editor
    /// instead of toggling, or worse, toggled the wrong entry.
    private struct HoveredBox: Equatable {
        let entryID: String
        let item: TaskLine.Item
    }

    private static let bottomAnchor = "bottom"

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                entryList
                    .frame(height: entriesHeight(available: geo.size.height))
                if store.isViewingToday {
                    ComposerDivider(
                        height: $composerHeight,
                        clamp: { clamped($0, available: geo.size.height) }
                    )
                    composer
                        .frame(height: clamped(composerHeight, available: geo.size.height))
                } else {
                    Divider()
                    pastDayNotice
                        .frame(height: pastDayNoticeHeight)
                }
            }
        }
        .navigationTitle(store.selectedDay)
        // Finishing with an entry — saved, deleted or cancelled — hands the
        // keyboard back to the composer so the next note can just be typed.
        .onChange(of: store.editingEntryID) { _, editing in
            if editing == nil { composerFocused = true }
        }
        .arrowNavigation(store: store, arrivingFromAbove: $arrivingFromAbove)
        .onDisappear {
            // Nothing else will pop a cursor this view pushed once it is gone.
            setHoveredBox(nil)
        }
    }

    /// Keeps the composer between its own minimum and whatever leaves the entry
    /// list at least `minEntriesHeight` — also applied on render, so shrinking
    /// the window can't strand the divider off-screen.
    private func clamped(_ height: Double, available: Double) -> Double {
        let ceiling = max(
            minComposerHeight,
            available - minEntriesHeight - ComposerDivider.thickness
        )
        return min(max(height, minComposerHeight), min(maxComposerHeight, ceiling))
    }

    /// A *definite* height for the entry list, subtracting whatever sits below it.
    ///
    /// This was `.frame(maxHeight: .infinity)`. A flexible frame wrapping a
    /// `ScrollView` makes it measure its own content to resolve a height, which
    /// showed up as the single hottest layout frame while the list was spinning.
    /// Pinning the height removes that negotiation.
    ///
    /// It is *not* what fixed the freeze — the spin survived this change; the
    /// `VStack` in `entryList` is the fix. Kept because the measurement work it
    /// avoids is real, and because both panes now size the same way.
    ///
    /// Caveat: `pastDayNoticeHeight` is a fixed 38pt, so the footer's caption
    /// would clip at large accessibility text sizes. Measure it instead if that
    /// ever matters.
    private func entriesHeight(available: Double) -> Double {
        let below = store.isViewingToday
            ? ComposerDivider.thickness + clamped(composerHeight, available: available)
            : dividerThickness + pastDayNoticeHeight
        return max(minEntriesHeight, available - below)
    }

    // MARK: Entries

    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack, not a LazyVStack. Lazy placement measures each
                // row against the visible rect while the ScrollView sizes its
                // content from those rows; once the content overflowed and was
                // scrolled, the two drove each other and never settled — a core
                // pegged at ~100%, memory climbing past 300M, window
                // unresponsive. A day holds a handful of entries, so laziness
                // bought nothing to trade against that.
                //
                // Do not "optimise" this back to LazyVStack. Bisected by sample:
                // the cycle survived removing .textSelection, both .onHover
                // modifiers, the .animation modifiers, and pinning every height.
                // Only dropping laziness stopped it. It needs enough content to
                // overflow, which is why short days look fine.
                VStack(alignment: .leading, spacing: 18) {
                    if store.entries.isEmpty {
                        Text("No entries yet.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                    ForEach(store.entries) { entry in
                        entryRow(entry)
                            .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(20)
                .animation(.easeInOut(duration: 0.22), value: store.entries.map(\.id))
                .animation(.easeInOut(duration: 0.12), value: hoveredEntryID)
            }
            .onChange(of: store.entries.count) { _, _ in
                withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: store.selectedDay) { _, _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            // Arrow-key navigation can open an entry that's scrolled out of view.
            .onChange(of: store.editingEntryID) { _, editing in
                if let editing { proxy.scrollTo(editing, anchor: .center) }
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
                MarkdownText(entry.body) { item, inside in
                    let box = HoveredBox(entryID: entry.id, item: item)
                    // Ordering isn't guaranteed when moving between two adjacent
                    // boxes, so a box may only clear its own claim — matched on
                    // the entry as well as the line.
                    if inside {
                        setHoveredBox(box)
                    } else if hoveredBox == box {
                        setHoveredBox(nil)
                    }
                }
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
                // The cursor can leave the row without the box's own onHover
                // firing (a deleted row, a scroll). Reset here so the pointing
                // hand can't get stuck — unconditionally, because a claim this
                // row's box failed to release is exactly the state to clear.
                if hoveredBox?.entryID == entry.id { setHoveredBox(nil) }
            }
        }
        // Click the text to edit it — or a checkbox to resolve it.
        // `simultaneousGesture` so the text view still gets the click for
        // selection, and TapGesture's own movement threshold means a drag to
        // highlight for copying does not trigger this. The checkbox can't own a
        // gesture of its own: this one is simultaneous, so it would fire too and
        // open the editor on top of the toggle. Hover state decides instead.
        .simultaneousGesture(
            TapGesture().onEnded {
                guard !store.isEditing(entry) else { return }
                // Only a box belonging to *this* entry may claim the click; a
                // stale claim from another row must not toggle anything here.
                if let box = hoveredBox, box.entryID == entry.id {
                    store.setTaskDone(entry, line: box.item.line, done: !box.item.done)
                } else {
                    edit(entry)
                }
            }
        )
        .contextMenu {
            Button("Edit") { edit(entry) }
            Button("Delete", role: .destructive) { store.delete(entry) }
        }
        // Fade + collapse on delete — the macOS convention for a row leaving a
        // list (Mail, Reminders, Notes). Editing a body does not change the row's
        // id, so this plays on delete only.
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
                .background(EditorAnchor(box: anchorBox))
                .onAppear { focusEditor(atTop: arrivingFromAbove) }
            HStack(spacing: 8) {
                Text("Clear the text to delete this entry.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.cancelEdit() }
                Button(store.editDraft.isBlank ? "Delete" : "Save") { store.commitEdit() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Opening an entry by mouse puts the caret at its end, wherever the last
    /// arrow-key navigation happened to leave the direction.
    private func edit(_ entry: Entry) {
        arrivingFromAbove = false
        store.beginEdit(entry)
    }

    // MARK: Editor focus

    /// A marker view planted in the inline editor's own subtree, so its
    /// `NSTextView` can be found by position on screen. Held in a box rather than
    /// as `@State` of its own: `makeNSView` fills it in synchronously, and this
    /// way finding the editor never waits on a view update.
    @State private var anchorBox = EditorAnchorBox()

    /// Focuses the inline editor and parks the caret at one end of it — the end
    /// it was entered from, so ↑/↓ carry on in the same direction.
    ///
    /// Done on the text view rather than through `@FocusState` +
    /// `TextSelection`: SwiftUI parks the caret at offset 0 when the editor takes
    /// focus, and both of those lose the race with it.
    ///
    /// The text view is found from `editorAnchor` — a zero-size marker installed
    /// as this editor's background, so it carries the editor's frame — by asking
    /// which text view covers it. Matching on *contents* used to do this job and
    /// picked the composer whenever the two happened to hold the same text.
    /// `LazyVStack` may not have laid the row out yet, hence the retries; if they
    /// all lose, `@FocusState` still puts the keyboard in the editor (caret at
    /// 0), because focus landing nowhere leaves arrow navigation dead until the
    /// user clicks.
    private func focusEditor(atTop: Bool, attempt: Int = 0) {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0 is QuicklogPanel }),
                  let editor = anchorBox.view.flatMap(Self.textView(near:))
            else {
                if attempt < 5 {
                    focusEditor(atTop: atTop, attempt: attempt + 1)
                } else {
                    editorFocused = true
                }
                return
            }
            window.makeFirstResponder(editor)
            let caret = atTop ? 0 : (editor.string as NSString).length
            editor.setSelectedRange(NSRange(location: caret, length: 0))
            editor.scrollRangeToVisible(NSRange(location: caret, length: 0))
        }
    }

    /// The text view the marker is standing in front of.
    ///
    /// The marker is installed as this editor's `.background`, so it carries the
    /// editor's own frame: the text view whose visible box covers it is the right
    /// one, wherever SwiftUI happened to put either in the AppKit hierarchy. An
    /// empty marker frame means layout hasn't run yet — the caller retries.
    private static func textView(near anchor: NSView) -> NSTextView? {
        guard let root = anchor.window?.contentView else { return nil }
        let marker = anchor.convert(anchor.bounds, to: root)
        guard !marker.isEmpty else { return nil }
        return textViews(in: root)
            .map { editor -> (editor: NSTextView, overlap: CGFloat) in
                // The scroll view, not the text view: a text view's own frame is
                // its document size, which can run far past what's on screen.
                let box: NSView = editor.enclosingScrollView ?? editor
                let rect = box.convert(box.bounds, to: root).intersection(marker)
                return (editor, rect.isNull ? 0 : rect.width * rect.height)
            }
            .filter { $0.overlap > 0 }
            .max { $0.overlap < $1.overlap }?
            .editor
    }

    private static func textViews(in view: NSView) -> [NSTextView] {
        if let editor = view as? NSTextView { return [editor] }
        return view.subviews.flatMap(textViews(in:))
    }

    /// Single funnel for the hovered checkbox, so the pointing-hand cursor is
    /// owned in one place (`Pointer`) rather than pushed per box.
    private func setHoveredBox(_ box: HoveredBox?) {
        hoveredBox = box
        Pointer.show(box == nil ? nil : .pointingHand)
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
                    .disabled(store.draft.isBlank)
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
            // The composer is hidden here but its draft is kept, and ⌘↩ still
            // saves it — to today, jumping there. Said out loud, because text
            // you can't see being written somewhere you aren't looking is not
            // something to leave implicit.
            Text(store.draft.isBlank
                 ? "Past day — edit or delete entries here; new entries go to today."
                 : "Past day — your unsaved draft is kept; ⌘↩ saves it to today.")
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

/// Where the inline editor's marker view is kept. A reference so the marker is
/// available the instant AppKit makes it, without a SwiftUI update in between.
@MainActor
final class EditorAnchorBox {
    /// Weak: the marker is owned by whatever superview SwiftUI puts it in.
    weak var view: NSView?
}

/// Zero-size view whose `NSView` marks where the inline editor lives on screen.
/// SwiftUI gives no handle on `TextEditor`'s text view, and this is cheaper than
/// reimplementing it.
private struct EditorAnchor: NSViewRepresentable {
    let box: EditorAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }
}
