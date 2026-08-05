import Foundation

/// One journal entry: a timestamp plus a markdown body.
struct Entry: Identifiable {
    /// Stable across reloads — derived from content, not freshly generated — so
    /// SwiftUI can diff the list and animate a single row out on delete.
    /// Duplicate timestamps are disambiguated by occurrence.
    let id: String
    /// `HH:mm` as written to disk.
    var time: String
    var body: String
}

/// One day of entries, keyed by `YYYY-MM-DD`.
struct Day: Identifiable {
    var id: String { key }
    /// `YYYY-MM-DD`
    var key: String
}

/// Reads/writes flat markdown files — one per day — in
/// `~/Library/Application Support/quicklog/`. Format is documented in the
/// README; entries are delimited by a line matching exactly `## HH:mm`.
final class StorageManager {
    static let shared = StorageManager()

    let directory: URL

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("quicklog", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // MARK: Keys

    func dayKey(for date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    func fileURL(for dayKey: String) -> URL {
        directory.appendingPathComponent("\(dayKey).md")
    }

    // MARK: Read

    /// All days that have a file, newest first.
    func days() -> [Day] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        let keys = files
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { isDayKey($0) }
            .sorted(by: >)
        return keys.map(Day.init(key:))
    }

    /// Entries for a day, oldest first.
    func entries(for dayKey: String) -> [Entry] {
        read(dayKey).entries
    }

    /// A parsed day file: everything before the first `## HH:mm` (title and any
    /// hand-written notes) plus the entries.
    struct DayFile {
        var preamble: String
        var entries: [Entry]
    }

    func read(_ dayKey: String) -> DayFile {
        guard let text = try? String(contentsOf: fileURL(for: dayKey), encoding: .utf8) else {
            return DayFile(preamble: "", entries: [])
        }
        var preambleLines: [String] = []
        var entries: [Entry] = []
        var currentTime: String?
        var buffer: [String] = []

        func flush() {
            guard let time = currentTime else { return }
            let body = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let occurrence = entries.reduce(0) { $0 + ($1.time == time ? 1 : 0) }
            entries.append(
                Entry(id: "\(time)#\(occurrence)#\(body)", time: time, body: body)
            )
            buffer = []
        }

        for line in text.components(separatedBy: "\n") {
            if let time = entryHeaderTime(line) {
                flush()
                currentTime = time
            } else if currentTime != nil {
                buffer.append(line)
            } else {
                preambleLines.append(line)
            }
        }
        flush()
        return DayFile(
            preamble: preambleLines.joined(separator: "\n"),
            entries: entries
        )
    }

    // MARK: Write

    /// Appends an entry to today's file, creating the file (with a `# YYYY-MM-DD`
    /// title) if needed. Returns the day key it was written to.
    @discardableResult
    func append(_ body: String, date: Date = Date()) throws -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return dayKey(for: date) }

        let key = dayKey(for: date)
        let url = fileURL(for: key)
        let fm = FileManager.default

        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if text.isEmpty {
            text = "# \(key)\n"
        }
        if !text.hasSuffix("\n") { text += "\n" }
        if !text.hasSuffix("\n\n") { text += "\n" }
        text += "## \(timeFormatter.string(from: date))\n\(trimmed)\n"

        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return key
    }

    // MARK: Edit / delete
    //
    // Both rewrite the day's own file in place. The file name, the `# YYYY-MM-DD`
    // title, any hand-written preamble, and every `## HH:mm` stamp are preserved
    // — editing an old entry never moves it to today's file.

    /// Replaces the body of the entry at `index` in `dayKey`.
    func updateEntry(dayKey: String, index: Int, body: String) throws {
        var file = read(dayKey)
        guard file.entries.indices.contains(index) else { throw StorageError.entryNotFound }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // An emptied entry is a delete.
            try deleteEntry(dayKey: dayKey, index: index)
            return
        }
        file.entries[index].body = trimmed
        try write(file, to: dayKey)
    }

    /// Removes the entry at `index` from `dayKey`.
    func deleteEntry(dayKey: String, index: Int) throws {
        var file = read(dayKey)
        guard file.entries.indices.contains(index) else { throw StorageError.entryNotFound }
        file.entries.remove(at: index)

        // Nothing left but the title we generated -> drop the file so the day
        // stops showing up in the sidebar. Any hand-written preamble is kept.
        if file.entries.isEmpty,
           file.preamble.trimmingCharacters(in: .whitespacesAndNewlines) == "# \(dayKey)" {
            try? FileManager.default.removeItem(at: fileURL(for: dayKey))
            return
        }
        try write(file, to: dayKey)
    }

    /// Serialises a day file back to disk in the same shape `append` produces.
    private func write(_ file: DayFile, to dayKey: String) throws {
        var preamble = file.preamble.trimmingCharacters(in: .whitespacesAndNewlines)
        if preamble.isEmpty { preamble = "# \(dayKey)" }

        var text = preamble + "\n"
        for entry in file.entries {
            text += "\n## \(entry.time)\n\(entry.body)\n"
        }
        try text.write(to: fileURL(for: dayKey), atomically: true, encoding: .utf8)
    }

    enum StorageError: LocalizedError {
        case entryNotFound

        var errorDescription: String? {
            switch self {
            case .entryNotFound: return "Entry no longer exists — reloaded from disk."
            }
        }
    }

    // MARK: Raw access (undo/redo snapshots)

    /// Whole-file contents, or nil if the day has no file.
    func rawText(for dayKey: String) -> String? {
        try? String(contentsOf: fileURL(for: dayKey), encoding: .utf8)
    }

    /// Restores a whole-file snapshot. `nil` means "the file did not exist".
    func writeRaw(_ text: String?, to dayKey: String) {
        let url = fileURL(for: dayKey)
        if let text {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Helpers

    /// `## HH:mm` (exact) -> `HH:mm`. Anything else -> nil, so the user's own
    /// `##` headers inside an entry are left alone.
    private func entryHeaderTime(_ line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        let rest = String(line.dropFirst(3))
        guard rest.count == 5 else { return nil }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 2, parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }
        return rest
    }

    private func isDayKey(_ s: String) -> Bool {
        dayFormatter.date(from: s) != nil && s.count == 10
    }
}

// MARK: - Store

/// Observable view-model layer over `StorageManager`.
@MainActor
final class JournalStore: ObservableObject {
    @Published var days: [Day] = []
    @Published var selectedDay: String
    @Published var entries: [Entry] = []
    @Published var draft: String = ""
    @Published var lastError: String?

    private let storage: StorageManager

    init(storage: StorageManager = .shared) {
        self.storage = storage
        self.selectedDay = storage.dayKey()
        reload()
    }

    var todayKey: String { storage.dayKey() }
    var isViewingToday: Bool { selectedDay == todayKey }

    func reload() {
        var list = storage.days()
        // Today is always selectable, even before its file exists.
        if !list.contains(where: { $0.key == todayKey }) {
            list.insert(Day(key: todayKey), at: 0)
        }
        days = list
        if !days.contains(where: { $0.key == selectedDay }) {
            selectedDay = todayKey
        }
        loadSelectedDay()
    }

    func loadSelectedDay() {
        entries = storage.entries(for: selectedDay)
    }

    func select(_ key: String) {
        cancelEdit()
        selectedDay = key
        loadSelectedDay()
    }

    /// Saves the draft as a new entry on today's file.
    func saveDraft() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let key = todayKey
        mutate(key) {
            try storage.append(body)
            draft = ""
            selectedDay = key
        }
    }

    // MARK: Undo / redo
    //
    // Whole-file snapshots. Cheap (a day file is a few KB), and immune to the
    // entry parser drifting out of sync with the index-based edit API.

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
        do {
            try body()
            let after = storage.rawText(for: dayKey)
            if before != after {
                undoStack.append(Snapshot(dayKey: dayKey, before: before, after: after))
                if undoStack.count > undoLimit { undoStack.removeFirst() }
                redoStack.removeAll()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshUndoFlags()
        reload()
    }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        storage.writeRaw(snap.before, to: snap.dayKey)
        redoStack.append(snap)
        finishTimeTravel(on: snap.dayKey)
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        storage.writeRaw(snap.after, to: snap.dayKey)
        undoStack.append(snap)
        finishTimeTravel(on: snap.dayKey)
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
        guard let id = editingEntryID,
              let index = entries.firstIndex(where: { $0.id == id })
        else {
            cancelEdit()
            return
        }
        let day = selectedDay
        let body = editDraft
        mutate(day) {
            try storage.updateEntry(dayKey: day, index: index, body: body)
            cancelEdit()
        }
    }

    func delete(_ entry: Entry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let day = selectedDay
        mutate(day) {
            try storage.deleteEntry(dayKey: day, index: index)
            if editingEntryID == entry.id { cancelEdit() }
        }
    }
}
