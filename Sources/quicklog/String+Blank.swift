import Foundation

extension String {
    /// Whitespace stripped from both ends — the form entry bodies are stored in.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nothing but whitespace — the journal's definition of empty. An entry body,
    /// a draft or a preamble that trims to nothing is not content.
    var isBlank: Bool {
        trimmed.isEmpty
    }
}
