/// Pure right-to-left text helpers for the chrome (#185, Persian). No SwiftUI: the views
/// decide *when* to apply them (only under a right-to-left layout, so left-to-right
/// languages keep byte-identical strings and pixel-identical rendering).
public enum BidiText {
    /// U+2066 LEFT-TO-RIGHT ISOLATE.
    public static let leftToRightIsolate = "\u{2066}"
    /// U+2067 RIGHT-TO-LEFT ISOLATE.
    public static let rightToLeftIsolate = "\u{2067}"
    /// U+2069 POP DIRECTIONAL ISOLATE.
    public static let popDirectionalIsolate = "\u{2069}"

    /// `text` wrapped in an LTR isolate, so a board token run like `13/7^ 8/4` or
    /// `bar/22*` keeps its left-to-right order inside right-to-left text instead of
    /// the bidi algorithm reordering its number groups.
    public static func isolatedLeftToRight(_ text: String) -> String {
        leftToRightIsolate + text + popDirectionalIsolate
    }

    /// A running score "left – right", where `left` belongs to the player shown on the
    /// *leading* side. Left-to-right: exactly `"1 – 0"`. Right-to-left (the names
    /// mirror, so the leading player sits on the right): the same logical string in an
    /// RTL isolate, so it renders `0 – 1` and each number stays next to its player —
    /// deterministically, whatever digits (Western or Persian) the numbers use.
    public static func score(_ left: String, _ right: String, rightToLeft: Bool) -> String {
        let line = "\(left) – \(right)"
        return rightToLeft ? rightToLeftIsolate + line + popDirectionalIsolate : line
    }

    /// SF Symbols that point *along the reading direction* (back / forward / next) and so
    /// must mirror under RTL. `chevron.left/right` and `arrow.left/right` don't flip on
    /// their own; symbols with a built-in RTL variant (`arrow.uturn.backward`) and
    /// symbols that depict something physical (dice, board, `arrow.clockwise`) must not
    /// be flipped again.
    public static func isDirectionalSymbol(_ name: String) -> Bool {
        let base = name.split(separator: ".").prefix(2).joined(separator: ".")
        return ["chevron.left", "chevron.right", "arrow.left", "arrow.right"].contains(base)
    }

    /// `text` with its ASCII digits 0–9 replaced by the run starting at `zero` (e.g.
    /// `"۰"` for Persian), for values pre-formatted with Western digits (win chance
    /// `63%`, equity `+0.52`). Returns `text` unchanged when `zero` is `"0"`.
    public static func replacingASCIIDigits(in text: String, zero: Character) -> String {
        guard zero != "0", let base = zero.unicodeScalars.first?.value,
              zero.unicodeScalars.count == 1 else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x30, scalar.value <= 0x39,
               let mapped = Unicode.Scalar(base + scalar.value - 0x30) {
                out.append(mapped)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// `text` with the "." between two digits replaced by `separator` (Persian "٫"), for
    /// values pre-formatted with `String(format:)` ("+0.52"). Returns `text` unchanged when
    /// `separator` is ".". A "." that is not between digits ("v1.") is left alone.
    public static func replacingDecimalPoint(in text: String, with separator: Character) -> String {
        guard separator != "." else { return text }
        let chars = Array(text)
        var out = ""
        for (i, c) in chars.enumerated() {
            if c == ".", i > 0, i + 1 < chars.count,
               chars[i - 1].isASCII, chars[i - 1].isNumber,
               chars[i + 1].isASCII, chars[i + 1].isNumber {
                out.append(separator)
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// A pre-formatted Western number string (sign "-" / "+" / "\u{2212}", digits, ".", "%") in
    /// the locale's digits and decimal separator, wrapped in an LTR isolate so the sign stays
    /// in front of its number (inside the isolate) in right-to-left text. Unchanged
    /// (byte-identical) when `zero` is "0", i.e. for Western-digit locales.
    public static func localizedNumber(_ text: String, zero: Character,
                                       decimalSeparator: Character) -> String {
        guard zero != "0" else { return text }
        // Decimal point first: it is recognised between ASCII digits.
        let decimal = replacingDecimalPoint(in: text, with: decimalSeparator)
        return isolatedLeftToRight(replacingASCIIDigits(in: decimal, zero: zero))
    }

    /// The separator between summary items ("Level 6 \u{00B7} Plakoto"): " \u{00B7} " normally, the
    /// Arabic comma in right-to-left text, where a "\u{00B7}" beside a Persian digit reads like a zero.
    public static func listSeparator(rightToLeft: Bool) -> String {
        rightToLeft ? "\u{060C} " : " \u{00B7} "
    }
}
