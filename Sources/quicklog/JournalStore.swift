import Foundation

/// Observable view-model layer over `StorageManager`.
@MainActor
final class JournalStore: ObservableObject {
    @Published var days: [Day] = []
    @Published var selectedDay: String
    @Published var entries: [Entry] = []
    @Published var draft: String = ""
    @Published var lastError: String?

    /// Today's `YYYY-MM-DD`, as a single observed value.
    ///
    /// Not recomputed per access: `isViewingToday` decides whether the composer
    /// is on screen at all, so a fresh `Date()` inside a re-render used to swap
    /// the composer for the past-day notice the moment the clock passed
    /// midnight — mid-typing, with the draft still in memory but nowhere to be
    /// seen. It only advances in `refreshToday`, which keeps the selection
    /// following today so the composer stays put.
    @Published private(set) var todayKey: String

    private let storage: StorageManager
    private var midnightTimer: Timer?

    init(storage: StorageManager = .shared) {
        self.storage = storage
        self.todayKey = storage.dayKey()
        self.selectedDay = storage.dayKey()
        reload()
        scheduleMidnightRollover()
    }

    deinit {
        midnightTimer?.invalidate()
    }

    var isViewingToday: Bool { selectedDay == todayKey }

    /// The one place the day rolls over. Everything that could straddle midnight
    /// goes through it with the same `Date` the rest of the operation uses.
    private func refreshToday(_ now: Date = Date()) {
        let key = storage.dayKey(for: now)
        guard key != todayKey else { return }
        let following = isViewingToday
        todayKey = key
        if following { selectedDay = key }
    }

    /// Fires just after midnight so the sidebar grows a new day and the composer
    /// keeps writing to the right file without waiting for the next user action.
    private func scheduleMidnightRollover() {
        midnightTimer?.invalidate()
        // A few seconds past the hour, not exactly on it: the day key is read
        // from a formatter, and firing early would produce yesterday's.
        guard let next = Calendar.current.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 0, second: 5),
            matchingPolicy: .nextTime
        ) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            // Runloop timers on the main runloop are delivered on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshToday()
                self.reload()
                self.scheduleMidnightRollover()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    func reload() {
        refreshToday()
        var list = storage.days()
        // Today is always selectable, even before its file exists.
        if !list.contains(where: { $0.key == todayKey }) {
            list.insert(Day(key: todayKey), at: 0)
        }
        days = list
        if !days.contains(where: { $0.key == selectedDay }) {
            // The day's file is gone (its last entry was deleted, or something
            // outside the app removed it). `select` rather than a bare
            // assignment: it also closes the inline editor, which is otherwise
            // left showing an entry that is no longer on screen — and with
            // `editingEntryID` still set nothing hands the keyboard back.
            select(todayKey)
            return
        }
        loadSelectedDay()
    }

    func loadSelectedDay() {
        entries = storage.entries(for: selectedDay)
        // The entry being edited can disappear underneath us the same way. Losing
        // the editor beats writing the text back to whatever took its place.
        if let id = editingEntryID, !entries.contains(where: { $0.id == id }) {
            cancelEdit()
        }
    }

    func select(_ key: String) {
        cancelEdit()
        selectedDay = key
        loadSelectedDay()
    }

    /// Saves the draft as a new entry on today's file, and selects that day —
    /// including from a past day, where the composer is hidden but the draft is
    /// kept (the past-day notice says so).
    func saveDraft() {
        let body = draft.trimmed
        guard !body.isEmpty else { return }
        // One `Date` for the file, the day key and the undo snapshot. Reading the
        // clock twice could put the entry in one day's file and the snapshot in
        // another's.
        let now = Date()
        refreshToday(now)
        let key = storage.dayKey(for: now)
        mutate(key) {
            try storage.append(body, date: now)
            draft = ""
            selectedDay = key
        }
    }

    // MARK: Undo / redo
    //
    // Whole-file snapshots. Cheap (a day file is a few KB), and immune to the
    // entry parser drifting out of sync with the edit API.

    private struct Snapshot {
        let dayKey: String
        /// File contents before the change; nil = file did not exist.
        let before: String?
        /// File contents after the change; nil = file was removed.
        let after: String?
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private let undoLimit = 50

    @Published var canUndo = false
    @Published var canRedo = false

    /// Runs a file mutation, recording before/after snapshots for undo.
    private func mutate(_ dayKey: String, _ body: () throws -> Void) {
        let before = storage.rawText(for: dayKey)
        var rebuildDayList = false
        do {
            try body()
            let after = storage.rawText(for: dayKey)
            // A day only enters or leaves the sidebar when its file appears or
            // disappears. Otherwise the list is untouched, and rebuilding it
            // costs a directory scan plus a date parse per file — per checkbox
            // click.
            rebuildDayList = (before == nil) != (after == nil)
            if before != after {
                undoStack.append(Snapshot(dayKey: dayKey, before: before, after: after))
                if undoStack.count > undoLimit { undoStack.removeFirst() }
                redoStack.removeAll()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            // The write failed because the file is not what we thought it was, so
            // take everything from disk again.
            rebuildDayList = true
        }
        refreshUndoFlags()
        if rebuildDayList { reload() } else { loadSelectedDay() }
    }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        guard restore(snap.before, to: snap.dayKey, putBack: snap, onto: &undoStack) else { return }
        redoStack.append(snap)
        finishTimeTravel(on: snap.dayKey)
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        guard restore(snap.after, to: snap.dayKey, putBack: snap, onto: &redoStack) else { return }
        undoStack.append(snap)
        finishTimeTravel(on: snap.dayKey)
    }

    /// Writes a snapshot back. On failure the snapshot returns to the stack it
    /// came from and the error is surfaced — a silently failed undo is
    /// indistinguishable from one that worked, which is how you lose the
    /// change twice.
    private func restore(
        _ text: String?,
        to dayKey: String,
        putBack snapshot: Snapshot,
        onto stack: inout [Snapshot]
    ) -> Bool {
        do {
            try storage.writeRaw(text, to: dayKey)
            return true
        } catch {
            stack.append(snapshot)
            lastError = error.localizedDescription
            refreshUndoFlags()
            reload()
            return false
        }
    }

    private func finishTimeTravel(on dayKey: String) {
        cancelEdit()
        selectedDay = dayKey
        lastError = nil
        refreshUndoFlags()
        reload()
    }

    private func refreshUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Edit / delete

    /// Entry currently open in the inline editor, if any.
    @Published var editingEntryID: String?
    @Published var editDraft: String = ""

    func isEditing(_ entry: Entry) -> Bool {
        editingEntryID == entry.id
    }

    func beginEdit(_ entry: Entry) {
        editingEntryID = entry.id
        editDraft = entry.body
        lastError = nil
    }

    func cancelEdit() {
        editingEntryID = nil
        editDraft = ""
    }

    /// Writes the inline editor's contents back to the entry's own day file.
    /// An empty body deletes the entry.
    func commitEdit() {
        guard let id = editingEntryID, entries.contains(where: { $0.id == id }) else {
            cancelEdit()
            return
        }
        let day = selectedDay
        let body = editDraft
        mutate(day) {
            try storage.updateEntry(dayKey: day, id: id, body: body)
            cancelEdit()
        }
    }

    /// Closes the editor, saving first if the text was changed — so stepping away
    /// with the arrow keys can't lose typing, and an untouched entry isn't
    /// rewritten just for having been visited.
    func endEdit() {
        if editDraft == entries.first(where: { $0.id == editingEntryID })?.body {
            cancelEdit()
        } else {
            commitEdit()
        }
    }

    /// True when the editor holds changes that a save would write. Used by
    /// `applicationWillTerminate` — quitting must not be the one way out that
    /// drops them.
    var hasUnsavedEdit: Bool {
        guard let id = editingEntryID else { return false }
        return editDraft != entries.first(where: { $0.id == id })?.body
    }

    /// Opens the entry above the one being edited — or the last entry, when
    /// coming from the composer. False means there is nothing above, so the
    /// caret should stay where it is.
    func editEntryAbove() -> Bool {
        guard let current = editingIndex else {
            guard let last = entries.last else { return false }
            beginEdit(last)
            return true
        }
        guard current > 0 else { return false }
        return moveEdit(from: current, to: current - 1)
    }

    /// Mirror of `editEntryAbove`. Past the last entry it returns to the
    /// composer; from the composer there is nowhere to go.
    func editEntryBelow() -> Bool {
        guard let current = editingIndex else { return false }
        guard current + 1 < entries.count else {
            endEdit()
            return true
        }
        return moveEdit(from: current, to: current + 1)
    }

    private var editingIndex: Int? {
        guard let id = editingEntryID else { return nil }
        return entries.firstIndex(where: { $0.id == id })
    }

    /// Steps the editor to a neighbouring entry.
    ///
    /// Closing the current editor can *delete* it (an emptied body is a delete),
    /// which shifts every later entry up one — and renumbers the occurrence in
    /// the ids of any that share its minute, so the destination's id can end up
    /// naming a different entry. Positions are adjusted instead of re-finding by
    /// id, which is what used to drop navigation on the floor.
    private func moveEdit(from source: Int, to destination: Int) -> Bool {
        let countBefore = entries.count
        endEdit()
        let removed = entries.count < countBefore
        let index = (removed && destination > source) ? destination - 1 : destination
        guard entries.indices.contains(index) else { return false }
        beginEdit(entries[index])
        return true
    }

    /// Resolves or reopens one checkbox in the entry. Writes to the entry's own
    /// day file, and is undoable like any other change.
    func setTaskDone(_ entry: Entry, line: Int, done: Bool) {
        guard entries.contains(where: { $0.id == entry.id }) else { return }
        // A click that hits no checkbox would otherwise write the body back
        // unchanged: no write, no error, nothing on screen. Say so instead.
        guard TaskLine.items(in: entry.body).contains(where: { $0.line == line }) else {
            lastError = "That checkbox is no longer there — reloaded from disk."
            loadSelectedDay()
            return
        }
        let day = selectedDay
        let body = TaskLine.setDone(in: entry.body, line: line, done: done)
        mutate(day) {
            try storage.updateEntry(dayKey: day, id: entry.id, body: body)
        }
    }

    func delete(_ entry: Entry) {
        guard entries.contains(where: { $0.id == entry.id }) else { return }
        let day = selectedDay
        mutate(day) {
            try storage.deleteEntry(dayKey: day, id: entry.id)
            if editingEntryID == entry.id { cancelEdit() }
        }
    }
}
