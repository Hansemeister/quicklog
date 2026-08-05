import Combine
import Foundation

/// One journal entry: a timestamp plus a markdown body.
struct Entry: Identifiable, Hashable {
    let id = UUID()
    /// `HH:mm` as written to disk.
    var time: String
    var body: String
}

/// One day of entries, keyed by `YYYY-MM-DD`.
struct Day: Identifiable, Hashable {
    var id: String { key }
    /// `YYYY-MM-DD`
    var key: String
}

/// Reads/writes flat markdown files — one per day — in
/// `~/Library/Application Support/quicklog/`.
///
/// File format:
/// ```
/// # 2026-08-05
///
/// ## 14:32
/// entry body, may span
/// multiple lines
///
/// ## 15:01
/// next entry
/// ```
/// Entries are delimited by a line matching exactly `## HH:mm`.
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
        guard let text = try? String(contentsOf: fileURL(for: dayKey), encoding: .utf8) else {
            return []
        }
        var entries: [Entry] = []
        var currentTime: String?
        var buffer: [String] = []

        func flush() {
            guard let time = currentTime else { return }
            let body = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(Entry(time: time, body: body))
            buffer = []
        }

        for line in text.components(separatedBy: "\n") {
            if let time = entryHeaderTime(line) {
                flush()
                currentTime = time
            } else if currentTime != nil {
                buffer.append(line)
            }
        }
        flush()
        return entries
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
    var storageDirectory: URL { storage.directory }

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
        selectedDay = key
        loadSelectedDay()
    }

    /// Saves the draft as a new entry on today's file.
    func saveDraft() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        do {
            let key = try storage.append(body)
            draft = ""
            lastError = nil
            selectedDay = key
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
