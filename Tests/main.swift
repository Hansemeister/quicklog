// Storage tests. Run with `just test`.
//
// Not an XCTest target on purpose: XCTest and swift-testing ship with Xcode,
// and this machine has Command Line Tools only. This is a plain executable
// compiled straight against StorageManager.swift — zero dependencies, exits
// non-zero on failure.

import Foundation

// MARK: - Tiny harness

var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: String, line: UInt = #line) {
    checks += 1
    if !ok {
        failures += 1
        print("FAIL (line \(line)): \(what)")
    }
}

func expect<T: Equatable>(_ got: T, _ want: T, _ what: String, line: UInt = #line) {
    checks += 1
    if got != want {
        failures += 1
        print("FAIL (line \(line)): \(what)\n  got:  \(got)\n  want: \(want)")
    }
}

/// A storage manager over a throwaway directory, cleaned up afterwards.
func withStorage(_ body: (StorageManager) throws -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("quicklog-tests-\(UUID().uuidString)")
    let storage = StorageManager(directory: dir)
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        try body(storage)
    } catch {
        failures += 1
        print("FAIL: threw \(error)")
    }
}

func date(_ s: String) -> Date {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.date(from: s)!
}

// MARK: - Append and parse

func testAppendCreatesTitledFile() {
    withStorage { s in
        let day = try s.append("hello", date: date("2026-08-05 14:32"))
        expect(day, "2026-08-05", "append returns the day key")
        let text = s.rawText(for: day) ?? ""
        expect(text, "# 2026-08-05\n\n## 14:32\nhello\n", "file layout")
        let entries = s.entries(for: day)
        expect(entries.count, 1, "one entry parsed")
        expect(entries.first?.time, "14:32", "timestamp")
        expect(entries.first?.body, "hello", "body")
    }
}

func testUserHeadersInBodyAreNotDelimiters() {
    withStorage { s in
        // Markdown the user might legitimately write. None of these is an exact
        // `## HH:mm` line, so none may split the entry.
        let body = "## 12:00 lunch\n### notes\n## 1:2\n##12:00\n## 12:60x"
        try s.append(body, date: date("2026-08-05 08:00"))
        let entries = s.entries(for: "2026-08-05")
        expect(entries.count, 1, "user's ## headers do not split the entry")
        expect(entries.first?.body, body, "body preserved verbatim")
    }
}

// MARK: - Editing an old day must not move or rename anything

func testEditMiddleEntryPreservesEverything() {
    withStorage { s in
        let day = "2026-07-01"
        // A file as it might exist after hand-editing: custom title line plus a
        // hand-written preamble note.
        let original = """
        # 2026-07-01
        hand-written preamble note

        ## 08:00
        one

        ## 12:30
        two

        ## 18:45
        three

        """
        try original.write(to: s.fileURL(for: day), atomically: true, encoding: .utf8)

        try s.updateEntry(dayKey: day, index: 1, body: "two edited")

        let text = s.rawText(for: day) ?? ""
        check(FileManager.default.fileExists(atPath: s.fileURL(for: day).path),
              "file keeps its name")
        check(text.hasPrefix("# 2026-07-01\nhand-written preamble note\n"),
              "title and preamble preserved")
        let entries = s.entries(for: day)
        expect(entries.map(\.time), ["08:00", "12:30", "18:45"], "all stamps preserved")
        expect(entries.map(\.body), ["one", "two edited", "three"], "only the target body changed")
        // Nothing leaked into today's file.
        check(s.rawText(for: s.dayKey()) == nil, "today's file not created")
    }
}

func testEmptyEditDeletesEntry() {
    withStorage { s in
        try s.append("keep", date: date("2026-08-05 08:00"))
        try s.append("drop", date: date("2026-08-05 09:00"))
        try s.updateEntry(dayKey: "2026-08-05", index: 1, body: "   \n  ")
        expect(s.entries(for: "2026-08-05").map(\.body), ["keep"], "blank edit deletes")
    }
}

func testDeleteLastEntryRemovesGeneratedFileOnly() {
    withStorage { s in
        try s.append("only", date: date("2026-08-05 08:00"))
        try s.deleteEntry(dayKey: "2026-08-05", index: 0)
        check(s.rawText(for: "2026-08-05") == nil, "auto-titled file removed when empty")

        // Same, but the user wrote something outside the entries: keep the file.
        let day = "2026-08-06"
        try "# 2026-08-06\nmy own notes\n\n## 08:00\nonly\n"
            .write(to: s.fileURL(for: day), atomically: true, encoding: .utf8)
        try s.deleteEntry(dayKey: day, index: 0)
        let text = s.rawText(for: day)
        check(text != nil, "file with hand-written preamble is kept")
        check(text?.contains("my own notes") == true, "preamble kept")
        expect(s.entries(for: day).count, 0, "no entries left")
    }
}

// MARK: - Run

testAppendCreatesTitledFile()
testUserHeadersInBodyAreNotDelimiters()
testEditMiddleEntryPreservesEverything()
testEmptyEditDeletesEntry()
testDeleteLastEntryRemovesGeneratedFileOnly()

if failures == 0 {
    print("ok — \(checks) checks passed")
    exit(0)
} else {
    print("\(failures) of \(checks) checks FAILED")
    exit(1)
}
