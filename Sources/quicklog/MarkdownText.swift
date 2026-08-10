import SwiftUI

/// Minimal block-level markdown renderer: headers (`#`..`###`), bullet lists
/// (`-`/`*`/`+`) with nesting by indentation, checkboxes, and paragraphs. Inline
/// `**bold**`, `*italic*`, and `` `code` `` are handled by Foundation's markdown
/// parser. Blocks come from `MarkdownBlock.parse`.
struct MarkdownText: View {
    private let blocks: [MarkdownBlock]
    /// Called as the cursor enters/leaves a checkbox, so the entry row's tap
    /// gesture knows whether a click means "resolve this box" or "edit the
    /// entry". The composer preview leaves it nil and stays inert.
    private let onHoverBox: ((TaskLine.Item, Bool) -> Void)?

    init(_ text: String, onHoverBox: ((TaskLine.Item, Bool) -> Void)? = nil) {
        self.blocks = MarkdownBlock.parse(text)
        self.onHoverBox = onHoverBox
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
                case let .task(line, indent, done, text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: done ? "checkmark.square" : "square")
                            .foregroundStyle(done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                            .contentShape(Rectangle())
                            .onHover { inside in
                                onHoverBox?(TaskLine.Item(line: line, done: done, text: text), inside)
                            }
                        inline(text)
                            .foregroundStyle(done ? .secondary : .primary)
                            .strikethrough(done, color: .secondary)
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
