import SwiftUI
import BoardGeometry

// Right-to-left support (#185, Persian). SwiftUI mirrors the chrome by itself under an
// RTL locale; these helpers cover the exceptions. Every one is a no-op under a
// left-to-right layout, so English / German / Dutch render exactly as before.
//
// - The physical board never mirrors: `boardLayoutDirection()` pins the board, its
//   checkers / dice / highlights / animations and the win-probability chart to LTR
//   geometry (point numbering, drag gestures and hit-testing rely on it).
// - Back / forward glyphs flip (`DirectionalSymbol`); board and dice glyphs don't.
// - Move notation is LTR-isolated; running scores follow the mirrored name order.

extension View {
    /// Pins this subtree to left-to-right layout: the physical board (#185).
    func boardLayoutDirection() -> some View {
        environment(\.layoutDirection, .leftToRight)
    }
}

/// An SF Symbol that mirrors under RTL when it points along the reading direction
/// (`chevron.left/right`, `arrow.left/right`, see `BidiText.isDirectionalSymbol`).
struct DirectionalSymbol: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name)
            .flipsForRightToLeftLayoutDirection(BidiText.isDirectionalSymbol(name))
    }
}

/// Number formatting for chrome numbers that are pre-formatted as Western-digit
/// strings (win chance "63%", equity "+0.52", running scores): the locale's own
/// digits in prose (Persian ۶۳). Board-bound numbers (move notation, checker counts
/// on the board) stay Western and never go through here.
enum ChromeDigits {
    /// The locale's zero digit ("0" for en/de/nl, "۰" for fa). Read once per launch.
    static let zero: Character = {
        let f = NumberFormatter()
        f.locale = .current
        return f.string(from: 0)?.first(where: \.isNumber) ?? "0"
    }()

    /// The locale's decimal separator ("." for en/de/nl, so their equity output stays as it
    /// was; "٫" for fa). Only consulted for non-Western digit locales.
    static let decimalSeparator: Character = {
        let f = NumberFormatter()
        f.locale = .current
        return f.decimalSeparator?.first ?? "."
    }()

    /// True when the locale itself is right-to-left (independent of a view's layout direction).
    static let isRightToLeft = Locale.current.language.characterDirection == .rightToLeft

    /// " · " between summary items; the Arabic comma for Persian (a "·" next to ۰ reads as
    /// a zero). One source for every list, so lists never mix separators.
    static var listSeparator: String { BidiText.listSeparator(rightToLeft: isRightToLeft) }

    /// `text` with its ASCII digits in the locale's digits and its decimal point as the
    /// locale's separator ("+0.52" -> "+۰٫۵۲"); for a non-Western locale also LTR-isolated,
    /// so a signed value keeps its sign (and the number stays in one piece) in front.
    /// Unchanged (byte-identical) for Western-digit locales.
    static func localized(_ text: String) -> String {
        BidiText.localizedNumber(text, zero: zero, decimalSeparator: decimalSeparator)
    }
}

/// A running score "1 – 0" whose left number belongs to the player shown on the
/// leading side. LTR: the exact pre-#185 string. RTL: locale digits in an RTL isolate,
/// so each number stays beside its (mirrored) player.
struct ScoreLineText: View {
    let left: Int
    let right: Int
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        Text(verbatim: Self.string(left, right, direction))
    }

    static func string(_ left: Int, _ right: Int, _ direction: LayoutDirection) -> String {
        guard direction == .rightToLeft else { return "\(left) – \(right)" }
        return BidiText.score(ChromeDigits.localized(String(left)),
                              ChromeDigits.localized(String(right)), rightToLeft: true)
    }
}
