import Foundation

public enum ApprovalText {
    /// `text` with control characters, line/paragraph separators, bidi
    /// overrides and invisible format characters (zero-width space and joiner,
    /// BOM, soft hyphen: Unicode category Cf) replaced by `\n`, `\r`, `\t`, `\u{1B}` and the like. With
    /// `keepingLineBreaks`, `\n` and `\t` pass through untouched (for a content
    /// preview, where lines are the point).
    public static func visible(_ text: String, keepingLineBreaks: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n" where keepingLineBreaks, "\t" where keepingLineBreaks:
                out.unicodeScalars.append(scalar)
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if needsEscape(scalar) {
                    out += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        // `.format` covers the bidi embeddings, overrides and isolates that
        // reorder the text shown, and the zero-width characters that make two
        // different paths look the same.
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    /// `text` cut to `limit` characters, saying so when something was left out.
    public static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… \(text.count - limit) more characters not shown"
    }
}
