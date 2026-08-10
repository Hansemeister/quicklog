import Foundation

/// One journal entry: a timestamp plus a markdown body.
struct Entry: Identifiable {
    /// `HH:mm#occurrence` — position in the day file, not content. Two entries
    /// in the same minute are told apart by occurrence, and editing a body does
    /// *not* change the id, so SwiftUI updates the row in place instead of
    /// animating it out and back in on every checkbox click. It is also the
    /// handle the storage edit API takes, so an external change to the file
    /// can't make an edit land on the wrong entry.
    let id: String
    /// `HH:mm` as written to disk.
    var time: String
    var body: String

    static func id(time: String, occurrence: Int) -> String { "\(time)#\(occurrence)" }
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
            let body = buffer.joined(separator: "\n").trimmed
            let occurrence = entries.reduce(0) { $0 + ($1.time == time ? 1 : 0) }
            entries.append(
                Entry(id: Entry.id(time: time, occurrence: occurrence), time: time, body: body)
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
        let trimmed = body.trimmed
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
    //
    // The target is named by `Entry.id`, re-resolved against the file as it is on
    // disk *now*. There is no file watcher, so the caller's list can be stale; an
    // index would then silently rewrite whichever entry happens to sit there,
    // while an id that is no longer present throws instead.

    /// Replaces the body of the entry with `id` in `dayKey`.
    func updateEntry(dayKey: String, id: String, body: String) throws {
        var file = read(dayKey)
        guard let index = file.entries.firstIndex(where: { $0.id == id }) else {
            throw StorageError.entryNotFound
        }
        let trimmed = body.trimmed
        guard !trimmed.isEmpty else {
            // An emptied entry is a delete.
            try deleteEntry(dayKey: dayKey, id: id)
            return
        }
        file.entries[index].body = trimmed
        try write(file, to: dayKey)
    }

    /// Removes the entry with `id` from `dayKey`.
    func deleteEntry(dayKey: String, id: String) throws {
        var file = read(dayKey)
        guard let index = file.entries.firstIndex(where: { $0.id == id }) else {
            throw StorageError.entryNotFound
        }
        file.entries.remove(at: index)

        // Nothing left but the title we generated -> drop the file so the day
        // stops showing up in the sidebar. Any hand-written preamble is kept.
        if file.entries.isEmpty,
           file.preamble.trimmed == "# \(dayKey)" {
            try writeRaw(nil, to: dayKey)
            return
        }
        try write(file, to: dayKey)
    }

    /// Serialises a day file back to disk in the same shape `append` produces.
    private func write(_ file: DayFile, to dayKey: String) throws {
        var preamble = file.preamble.trimmed
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
    ///
    /// Throws, unlike a fire-and-forget restore: a failed undo that looks like a
    /// success leaves the UI showing state that is not on disk. A file that is
    /// already gone is the one exception — the snapshot's intent is "no file
    /// here", and that is satisfied.
    func writeRaw(_ text: String?, to dayKey: String) throws {
        let url = fileURL(for: dayKey)
        if let text {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as NSError
                        where error.domain == NSCocoaErrorDomain
                        && error.code == NSFileNoSuchFileError {
                return
            } catch let error as NSError
                        where error.domain == NSPOSIXErrorDomain
                        && error.code == Int(ENOENT) {
                return
            }
        }
    }

    // MARK: Helpers

    /// `## HH:mm` (exact) -> `HH:mm`. Anything else -> nil.
    ///
    /// A line the *user* wrote as exactly `## 14:00` is indistinguishable from a
    /// stamp and does split the entry. That is a known constraint of the format,
    /// accepted to keep the files free of escape characters — near misses
    /// (`## 12:00 lunch`, `##12:00`, `## 1:2`) are all safe. The README says so,
    /// and the test suite pins it.
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
