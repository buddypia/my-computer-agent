import Foundation

/// Builds AppleScript string literals from untrusted text.
///
/// Anything that came from a model, a window title or an OCR line must go
/// through here before it is spliced into script source. Interpolating it raw
/// lets a value such as `Notes" & (do shell script "…") & "` close the literal
/// and run its own code.
public enum AppleScriptLiteral {
    /// The text escaped for use *between* the quotes of an AppleScript string.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// A complete literal, quotes included.
    public static func quoted(_ text: String) -> String {
        "\"" + escape(text) + "\""
    }
}
