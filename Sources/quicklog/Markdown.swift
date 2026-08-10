import Foundation

/// Block-level markdown, parsed once per render. Pure and Foundation-only, so
/// it's testable without a view — living inside the view file is why the
/// renderer and the checkbox writer were able to disagree about what a checkbox
/// is.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    /// `- [ ]` / `- [x]` — a bullet that can be resolved. `line` is its line
    /// number in the entry body, which is how a click identifies it.
    case task(line: Int, indent: Int, done: Bool, text: String)
    case paragraph(String)
    case blank

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for (lineNumber, rawLine) in text.components(separatedBy: "\n").enumerated() {
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

            // Checkboxes go through `TaskLine` — the same detector the click path
            // rewrites with, so anything drawn as a box is resolvable.
            if let task = TaskLine.parse(rawLine) {
                blocks.append(
                    .task(line: lineNumber, indent: task.indent, done: task.done, text: task.text)
                )
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

    /// `- text` / `* text` / `+ text` -> `text`. The space is required so `-5` or
    /// `-word` stay paragraphs; the checkbox shorthand `-[]` never reaches here.
    private static func bulletMarker(_ line: String) -> String? {
        guard let first = line.first, "-*+".contains(first) else { return nil }
        let rest = line.dropFirst()
        guard rest.first == " " else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }
}
