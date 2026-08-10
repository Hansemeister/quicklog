import Foundation

/// Checkbox lines inside an entry body: `- [ ] send email to X`, resolved as
/// `- [x] send email to X`. Plain GitHub-style markdown, so the file stays
/// readable and editable anywhere — there is no separate todo store.
///
/// `parse` is the *only* checkbox detector in the app: the renderer draws a box
/// for exactly the lines it accepts, and a click writes through the range it
/// reports. Two detectors drifted apart once already — a tab after the bullet
/// rendered a box whose click was a silent no-op.
enum TaskLine {
    /// One checkbox. Named `Item` rather than `Task` to stay clear of Swift's
    /// concurrency `Task`.
    struct Item: Equatable {
        let line: Int
        let done: Bool
        let text: String
    }

    /// A checkbox line taken apart far enough to both render and rewrite it.
    struct Parsed: Equatable {
        /// Nesting depth: leading whitespace in columns (tab = 2) halved, which
        /// is the renderer's 2-space-per-level convention.
        let indent: Int
        let done: Bool
        /// Label after the box.
        let text: String
        /// The `[ ]`/`[x]`/`[]` marker inside the original line. Replacing this
        /// range is what resolves a box, and what normalises the shorthands on
        /// the first click.
        let markerRange: Range<String.Index>
        /// False for `-[]` — the writer fills the missing space in.
        let spacedBullet: Bool
    }

    /// Splits one line into its checkbox parts, or nil if it isn't a checkbox.
    ///
    /// Indentation and the bullet character are whatever the user wrote. The
    /// space after the bullet is optional — `-[]` is a common typo, and only a
    /// box can follow a bullet without one, so it stays unambiguous. `[]` with
    /// nothing between the brackets counts as unchecked: it's what you type when
    /// you're in a hurry.
    static func parse(_ line: String) -> Parsed? {
        var i = line.startIndex
        var columns = 0
        while i < line.endIndex, line[i] == " " || line[i] == "\t" {
            columns += line[i] == "\t" ? 2 : 1
            i = line.index(after: i)
        }
        guard i < line.endIndex, "-*+".contains(line[i]) else { return nil }
        i = line.index(after: i)

        let afterBullet = i
        while i < line.endIndex, line[i] == " " || line[i] == "\t" {
            i = line.index(after: i)
        }
        let spacedBullet = i > afterBullet

        let box = line[i...].prefix(3).lowercased()
        let width: Int
        if box == "[ ]" || box == "[x]" {
            width = 3
        } else if box.hasPrefix("[]") {
            width = 2
        } else {
            return nil
        }
        let end = line.index(i, offsetBy: width)
        return Parsed(
            indent: columns / 2,
            done: box == "[x]",
            text: String(line[end...]).trimmingCharacters(in: .whitespaces),
            markerRange: i..<end,
            spacedBullet: spacedBullet
        )
    }

    /// Every checkbox in the body, in source order. Each one resolves on its own,
    /// so the line number is what identifies it.
    static func items(in body: String) -> [Item] {
        body.components(separatedBy: "\n").enumerated().compactMap { index, line in
            guard let task = parse(line) else { return nil }
            return Item(line: index, done: task.done, text: task.text)
        }
    }

    /// Flips the checkbox on one line. Indentation and bullet character are left
    /// as the user wrote them, but a missing space after the bullet is filled in,
    /// so `-[]` lands as `- [x]`. A line that isn't a checkbox is left alone.
    static func setDone(in body: String, line: Int, done: Bool) -> String {
        var lines = body.components(separatedBy: "\n")
        guard lines.indices.contains(line), let task = parse(lines[line]) else { return body }
        lines[line] = lines[line].replacingCharacters(
            in: task.markerRange,
            with: (task.spacedBullet ? "" : " ") + (done ? "[x]" : "[ ]")
        )
        return lines.joined(separator: "\n")
    }
}
