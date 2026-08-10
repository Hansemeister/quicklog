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

/// The id of the nth entry of a day. The storage API names its target by id, so
/// tests do too.
func entryID(_ s: StorageManager, _ day: String, _ index: Int) -> String {
    s.entries(for: day)[index].id
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

func testNearMissHeadersInBodyAreNotDelimiters() {
    withStorage { s in
        // Markdown the user might legitimately write. None of these is an exact
        // `## HH:mm` line, so none may split the entry.
        let body = "## 12:00 lunch\n### notes\n## 1:2\n##12:00\n## 12:60x\n##  12:00\n## 12:0a"
        try s.append(body, date: date("2026-08-05 08:00"))
        let entries = s.entries(for: "2026-08-05")
        expect(entries.count, 1, "near-miss ## headers do not split the entry")
        expect(entries.first?.body, body, "body preserved verbatim")
    }
}

/// Deliberate limitation, not a bug: a body line that is *exactly* `## HH:mm` is
/// indistinguishable from an entry stamp, and reading the file back splits the
/// note in two. The alternative was escaping bodies on write, which was rejected
/// to keep the files free of `\` noise. Pinned here so it stays a known property
/// of the format rather than a surprise.
func testExactHeaderInBodySplitsEntry() {
    withStorage { s in
        try s.append("meeting notes\n## 14:00\nstandup went long",
                     date: date("2026-08-05 09:15"))
        let entries = s.entries(for: "2026-08-05")
        expect(entries.count, 2, "an exact `## HH:mm` body line reads back as a delimiter")
        expect(entries.map(\.time), ["09:15", "14:00"], "the split half takes the time it names")
        expect(entries.map(\.body), ["meeting notes", "standup went long"],
               "the body is divided at that line")
        // The file itself is untouched by the split — it is only how the parser
        // reads it back, so a hand-fixed file recovers.
        check(s.rawText(for: "2026-08-05")?.contains("## 14:00\nstandup went long") == true,
              "the line is on disk exactly as typed")
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

        try s.updateEntry(dayKey: day, id: entryID(s, day, 1), body: "two edited")

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
        try s.updateEntry(dayKey: "2026-08-05", id: entryID(s, "2026-08-05", 1), body: "   \n  ")
        expect(s.entries(for: "2026-08-05").map(\.body), ["keep"], "blank edit deletes")
    }
}

func testDeleteLastEntryRemovesGeneratedFileOnly() {
    withStorage { s in
        try s.append("only", date: date("2026-08-05 08:00"))
        try s.deleteEntry(dayKey: "2026-08-05", id: entryID(s, "2026-08-05", 0))
        check(s.rawText(for: "2026-08-05") == nil, "auto-titled file removed when empty")

        // Same, but the user wrote something outside the entries: keep the file.
        let day = "2026-08-06"
        try "# 2026-08-06\nmy own notes\n\n## 08:00\nonly\n"
            .write(to: s.fileURL(for: day), atomically: true, encoding: .utf8)
        try s.deleteEntry(dayKey: day, id: entryID(s, day, 0))
        let text = s.rawText(for: day)
        check(text != nil, "file with hand-written preamble is kept")
        check(text?.contains("my own notes") == true, "preamble kept")
        expect(s.entries(for: day).count, 0, "no entries left")
    }
}

// MARK: - Entry identity and the id-based edit API

func testEntryIDIgnoresTheBody() {
    withStorage { s in
        let day = try s.append("before", date: date("2026-08-05 08:00"))
        let id = entryID(s, day, 0)
        expect(id, "08:00#0", "id is time plus occurrence")
        try s.updateEntry(dayKey: day, id: id, body: "after, much longer text")
        expect(entryID(s, day, 0), id, "editing the body does not change the id")
        expect(s.entries(for: day).first?.body, "after, much longer text", "the edit landed")
    }
}

func testDuplicateMinutesAreToldApart() {
    withStorage { s in
        let day = "2026-08-05"
        try s.append("first", date: date("2026-08-05 09:15"))
        try s.append("second", date: date("2026-08-05 09:15"))
        expect(s.entries(for: day).map(\.id), ["09:15#0", "09:15#1"],
               "same minute is disambiguated by occurrence")
        try s.updateEntry(dayKey: day, id: "09:15#1", body: "second edited")
        expect(s.entries(for: day).map(\.body), ["first", "second edited"],
               "the second of two in a minute is addressable")
    }
}

/// The list the caller edits from can be stale — there is no file watcher. An
/// index would silently rewrite whatever now sits at that position; an id either
/// finds its entry or throws.
func testExternalInsertDoesNotMisdirectAnEdit() {
    withStorage { s in
        let day = "2026-07-01"
        try s.append("morning", date: date("2026-07-01 08:00"))
        try s.append("noon", date: date("2026-07-01 12:30"))
        let target = entryID(s, day, 1) // "noon", index 1
        expect(target, "12:30#0", "target id")

        // Something outside the app inserts an entry above it, shifting indices.
        try """
        # 2026-07-01

        ## 06:00
        inserted by hand

        ## 08:00
        morning

        ## 12:30
        noon

        """.write(to: s.fileURL(for: day), atomically: true, encoding: .utf8)

        try s.updateEntry(dayKey: day, id: target, body: "noon edited")
        expect(s.entries(for: day).map(\.body), ["inserted by hand", "morning", "noon edited"],
               "the edit follows the id, not the stale index")
    }
}

func testUnknownIDThrows() {
    withStorage { s in
        let day = try s.append("only", date: date("2026-08-05 08:00"))
        var threw = false
        do {
            try s.updateEntry(dayKey: day, id: "23:59#0", body: "nope")
        } catch StorageManager.StorageError.entryNotFound {
            threw = true
        }
        check(threw, "editing an id that is not in the file throws entryNotFound")

        threw = false
        do {
            try s.deleteEntry(dayKey: day, id: "23:59#0")
        } catch StorageManager.StorageError.entryNotFound {
            threw = true
        }
        check(threw, "deleting an id that is not in the file throws entryNotFound")
        expect(s.entries(for: day).map(\.body), ["only"], "and nothing else was touched")
    }
}

func testWriteRawReportsFailureButToleratesAnAbsentFile() {
    withStorage { s in
        let day = "2026-08-05"
        try s.append("gone soon", date: date("2026-08-05 08:00"))
        try s.writeRaw(nil, to: day)
        check(s.rawText(for: day) == nil, "a nil snapshot removes the file")
        // Undo of a change that created the file restores "no file", and doing it
        // twice must not be an error — the intent is already satisfied.
        try s.writeRaw(nil, to: day)
        check(true, "removing an already-absent file is not a failure")

        // An unwritable path is a real failure and must not be swallowed: a
        // silently failed undo looks exactly like one that worked. A regular file
        // standing where the storage directory should be is the cheapest way to
        // make every write fail.
        let blocker = s.directory.appendingPathComponent("blocker")
        try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
        let blocked = StorageManager(directory: blocker.appendingPathComponent("inside"))
        var threw = false
        do {
            try blocked.writeRaw("text", to: day)
        } catch {
            threw = true
        }
        check(threw, "a failed snapshot write throws")
    }
}

// MARK: - Checkboxes

func testTaskLines() {
    let body = """
    - [ ] send email to X
      - [x] already done
    - not a task
    -[ ] no space after the bullet
    * [ ] star bullet
    """
    let boxes = TaskLine.items(in: body)
    expect(boxes.count, 4, "finds the four checkboxes")
    expect(boxes.map(\.line), [0, 1, 3, 4], "reports source line numbers")
    expect(boxes.map(\.done), [false, true, false, false], "reads each state")
    expect(boxes.map(\.text),
           ["send email to X", "already done", "no space after the bullet", "star bullet"],
           "strips the box and indentation from the label")
    check(TaskLine.items(in: "- plain bullet").isEmpty, "plain bullets aren't checkboxes")
    check(TaskLine.items(in: "-5 degrees outside").isEmpty, "a dash without a box isn't a checkbox")

    expect(TaskLine.setDone(in: body, line: 0, done: true), """
    - [x] send email to X
      - [x] already done
    - not a task
    -[ ] no space after the bullet
    * [ ] star bullet
    """, "resolving one box leaves the others, the indentation and non-tasks alone")

    expect(TaskLine.setDone(in: body, line: 1, done: false), """
    - [ ] send email to X
      - [ ] already done
    - not a task
    -[ ] no space after the bullet
    * [ ] star bullet
    """, "reopening one box keeps its indentation")

    expect(TaskLine.setDone(in: body, line: 2, done: true), body, "a non-checkbox line is untouched")
    expect(TaskLine.setDone(in: body, line: 99, done: true), body, "out-of-range line is untouched")

    // `- []` and `-[]` are what you type in a hurry. Accepted as unchecked, and
    // normalised — box and missing space both — the first time they're resolved.
    let short = "- [] no space in the box"
    expect(TaskLine.items(in: short).count, 1, "`- []` counts as a checkbox")
    expect(TaskLine.items(in: short).first?.done, false, "`- []` is unchecked")
    expect(TaskLine.items(in: short).first?.text, "no space in the box", "`- []` label strips the box")
    expect(TaskLine.setDone(in: short, line: 0, done: true), "- [x] no space in the box",
           "resolving `- []` normalises the marker")
    expect(TaskLine.setDone(in: short, line: 0, done: false), "- [ ] no space in the box",
           "reopening `- []` normalises it too")
    expect(TaskLine.parse(short)?.text, "no space in the box", "parse handles the short box")

    for cramped in ["-[] both shorthands", "-[ ] both shorthands", "  -[x] both shorthands"] {
        expect(TaskLine.items(in: cramped).count, 1, "`\(cramped)` counts as a checkbox")
        expect(TaskLine.items(in: cramped).first?.text, "both shorthands",
               "`\(cramped)` label strips the box")
    }
    expect(TaskLine.setDone(in: "-[] thing", line: 0, done: true), "- [x] thing",
           "resolving `-[]` inserts the missing space after the bullet")
    expect(TaskLine.setDone(in: "  -[x] thing", line: 0, done: false), "  - [ ] thing",
           "the inserted space keeps the indentation")

    // Tabs. The renderer treats a tab as two spaces, so these draw a box — and a
    // box that draws must be resolvable, or the click is a silent no-op.
    expect(TaskLine.items(in: "-\t[ ] tabbed").count, 1, "a tab after the bullet is a checkbox")
    expect(TaskLine.setDone(in: "-\t[ ] tabbed", line: 0, done: true), "-\t[x] tabbed",
           "resolving keeps the tab after the bullet")
    expect(TaskLine.setDone(in: "\t- [ ] indented", line: 0, done: true), "\t- [x] indented",
           "resolving keeps tab indentation")
    expect(TaskLine.parse("\t\t- [ ] deep")?.indent, 2, "a tab counts as two indent columns")

    expect(TaskLine.parse("- [ ] thing")?.text, "thing", "parse strips the box")
    check(TaskLine.parse("- [x] thing")?.done == true, "parse reads the state")
    check(TaskLine.parse("- [X] thing")?.done == true, "an upper-case X is done too")
    expect(TaskLine.parse("- [] thing")?.text, "thing", "parse handles the short box")
    check(TaskLine.parse("- plain") == nil, "parse rejects non-tasks")
    check(TaskLine.parse("plain") == nil, "parse rejects a line with no bullet")
    check(TaskLine.parse("- [ ]")?.text == "", "a box with no label still parses")
    check(TaskLine.parse("- []")?.text == "", "a short box with no label still parses")
    check(TaskLine.parse("- [x") == nil, "an unclosed box is not a checkbox")
    check(TaskLine.parse("+ [ ] plus")?.spacedBullet == true, "reports the space after the bullet")
    check(TaskLine.parse("+[ ] plus")?.spacedBullet == false, "reports a missing space")
}

// MARK: - Markdown blocks
//
// The renderer's parser. Same detector as the writer above, which is the point:
// what draws as a checkbox is what a click can resolve.

func testMarkdownBlocks() {
    expect(MarkdownBlock.parse("# one\n## two\n### three\n#### four"),
           [.heading(level: 1, text: "one"),
            .heading(level: 2, text: "two"),
            .heading(level: 3, text: "three"),
            .heading(level: 3, text: "four")],
           "heading levels, clamped at three")
    check(MarkdownBlock.parse("#nospace") == [.paragraph("#nospace")],
          "a header needs a space")
    check(MarkdownBlock.parse("####### seven") == [.paragraph("####### seven")],
          "seven hashes is not a header")

    expect(MarkdownBlock.parse("a\n\n\n\nb"),
           [.paragraph("a"), .blank, .paragraph("b")],
           "runs of blank lines collapse to one")
    check(MarkdownBlock.parse("a\n\n\n") == [.paragraph("a")], "trailing blanks are dropped")
    check(MarkdownBlock.parse("") == [], "empty text has no blocks")

    expect(MarkdownBlock.parse("- one\n  - two\n    - three\n\t- tabbed"),
           [.bullet(indent: 0, text: "one"),
            .bullet(indent: 1, text: "two"),
            .bullet(indent: 2, text: "three"),
            .bullet(indent: 1, text: "tabbed")],
           "bullets nest by two-space indentation, tab counts as two")
    check(MarkdownBlock.parse("-5 degrees") == [.paragraph("-5 degrees")],
          "a dash with no space stays a paragraph")

    expect(MarkdownBlock.parse("intro\n- [ ] a\n- [x] b"),
           [.paragraph("intro"),
            .task(line: 1, indent: 0, done: false, text: "a"),
            .task(line: 2, indent: 0, done: true, text: "b")],
           "task line numbers are body line numbers, not block numbers")
    expect(MarkdownBlock.parse("\n\n- [ ] a"),
           [.blank, .task(line: 2, indent: 0, done: false, text: "a")],
           "collapsed blanks do not shift a task's line number")

    // Every shorthand the writer accepts must also render as a box.
    for shorthand in ["- [] x", "-[] x", "-[ ] x", "*[x] x", "+ [X] x", "-\t[ ] x", "  -[x] x"] {
        let blocks = MarkdownBlock.parse(shorthand)
        if case .task = blocks.first {
            check(true, "`\(shorthand)` renders as a checkbox")
        } else {
            check(false, "`\(shorthand)` renders as a checkbox — got \(blocks)")
        }
    }
    expect(MarkdownBlock.parse("- [ ]\ttabbed label"),
           [.task(line: 0, indent: 0, done: false, text: "tabbed label")],
           "a tab between box and label is stripped")
}

// MARK: - Run

testAppendCreatesTitledFile()
testNearMissHeadersInBodyAreNotDelimiters()
testExactHeaderInBodySplitsEntry()
testEditMiddleEntryPreservesEverything()
testEmptyEditDeletesEntry()
testDeleteLastEntryRemovesGeneratedFileOnly()
testEntryIDIgnoresTheBody()
testDuplicateMinutesAreToldApart()
testExternalInsertDoesNotMisdirectAnEdit()
testUnknownIDThrows()
testWriteRawReportsFailureButToleratesAnAbsentFile()
testTaskLines()
testMarkdownBlocks()

if failures == 0 {
    print("ok — \(checks) checks passed")
    exit(0)
} else {
    print("\(failures) of \(checks) checks FAILED")
    exit(1)
}
