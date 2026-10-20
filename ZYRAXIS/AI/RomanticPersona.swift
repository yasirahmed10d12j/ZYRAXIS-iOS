import Foundation

/// Loads the romantic-mode persona from `Resources/RomanticPersona.txt`.
///
/// The persona is deliberately kept in a text file rather than hardcoded so
/// it can be edited freely — add pet names, shayari, new rules — without
/// touching Swift. The file supports comments so the editable document can
/// carry its own instructions:
///
/// - Lines starting with `#` are comments and are stripped.
/// - Blank lines are stripped as well (the AI does not need prettiness).
/// - Everything else is passed through verbatim.
///
/// Loading is cached, and if the resource is ever missing (a packaging
/// mistake, a test bundle without resources, a stripped build) it falls back
/// to the compiled-in constant. Romantic mode must never break because a
/// text file moved.
public enum RomanticPersona {

    /// The persona text actually sent to the model.
    public static var text: String { load() }

    /// Kept separate from the raw file so tests can assert both the parsing
    /// rules and the fallback independently of bundle contents.
    ///
    /// A line is a comment only when its FIRST character is `#`. `##` is a
    /// section heading, not a comment: it is useful structure for the model,
    /// and treating it as a comment silently deleted every heading in the
    /// file. The distinction is exactly the length of the `#` run.
    static func parse(_ raw: String) -> String {
        let kept = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && !isComment(line)
            }
        guard !kept.isEmpty else { return "" }
        return "\n\n" + kept.joined(separator: "\n")
    }

    /// True only for lines that begin with a single `#`. `##` and deeper are
    /// headings and are kept.
    private static func isComment(_ line: String) -> Bool {
        guard line.hasPrefix("#") else { return false }
        return !line.hasPrefix("##")
    }

    private static let cached: String = {
        guard
            let url = Bundle.main.url(forResource: "RomanticPersona", withExtension: "txt"),
            let raw = try? String(contentsOf: url, encoding: .utf8)
        else {
            ZyraxisLogger.log(.ai, "RomanticPersona.txt missing — using built-in persona")
            return ConversationManager.romanticSuffixFallback
        }
        let parsed = parse(raw)
        if parsed.isEmpty {
            ZyraxisLogger.log(.ai, "RomanticPersona.txt had no usable text — using built-in persona")
            return ConversationManager.romanticSuffixFallback
        }
        return parsed
    }()

    private static func load() -> String { cached }
}
