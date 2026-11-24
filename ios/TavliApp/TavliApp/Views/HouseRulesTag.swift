import SwiftUI

/// #258 — the **wolf tag**: marks a game played under the family's house rules (the
/// owner's family name is Wolf). A small caramel capsule — light caramel fill, darker
/// caramel edge and ink — holding a front-facing geometric wolf head (`WolfHeadGlyph`)
/// and "House rules". Shown wherever a house-Plakoto game is named and space allows: the
/// start screen's play summary, the game chrome's variant line, the new-game sheet and
/// the online lobby when House rules apply, the Full Tavli between-legs screen.
/// `.glyph` keeps only the head (inside the same capsule) where the words don't fit;
/// VoiceOver always reads "House rules". Colours are `ChromeKit.houseTag*` light/dark
/// pairs, so it reads on the page, on cards and on the solid caramel play button.
struct HouseRulesTag: View {
    enum Style { case full, glyph }

    var style: Style = .full

    private var glyphSize: CGFloat { (17 * ChromeType.scale).rounded() }

    var body: some View {
        HStack(spacing: 4) {
            WolfHeadGlyph(size: glyphSize)
            if style == .full {
                Text("House rules")
                    .font(ChromeType.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(ChromeKit.houseTagInk)
        .padding(.leading, style == .full ? 6 : 5)
        .padding(.trailing, style == .full ? 8 : 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(ChromeKit.houseTagFill))
        .overlay(Capsule().strokeBorder(ChromeKit.houseTagEdge, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("House rules"))
        .accessibilityIdentifier("houseRulesTag")
    }
}

/// The wolf head: a 24-unit outline — pointed ears, a face narrowing to the chin — plus
/// two eyes and a nose, stroked at the weight of the app's SF Symbols (≈ 2/24 of its
/// size, round joins). Template-coloured by the foreground style.
struct WolfHeadGlyph: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            WolfHeadOutline()
                .stroke(style: StrokeStyle(lineWidth: max(1, size * 1.9 / 24),
                                           lineCap: .round, lineJoin: .round))
            WolfHeadFeatures()
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Points in the 24 × 24 design grid, scaled into `rect`.
private func wolfPoint(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + x / 24 * rect.width, y: rect.minY + y / 24 * rect.height)
}

/// The head's outline, refined from the approved sketch `M4 3l5 5h6l5-5-1 9-7 9-7-9z`:
/// upright pointed ears (tips at (5,2.5)/(19,2.5)), the brow between them, a cheek ruff
/// flaring out to (3,13)/(21,13) — what makes it a wolf rather than a fox — and the
/// face narrowing to the chin at (12,21).
struct WolfHeadOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let p = { (x: CGFloat, y: CGFloat) in wolfPoint(x, y, in: rect) }
        var path = Path()
        path.move(to: p(5, 2.5))
        path.addLine(to: p(9.5, 7.5))
        path.addLine(to: p(14.5, 7.5))
        path.addLine(to: p(19, 2.5))
        path.addLine(to: p(19.5, 10.5))
        path.addLine(to: p(21, 13))
        path.addLine(to: p(17, 15))
        path.addLine(to: p(12, 21))
        path.addLine(to: p(7, 15))
        path.addLine(to: p(3, 13))
        path.addLine(to: p(4.5, 10.5))
        path.closeSubpath()
        return path
    }
}

/// Eyes (two small slanted almonds) and the nose (a rounded downward triangle).
struct WolfHeadFeatures: Shape {
    func path(in rect: CGRect) -> Path {
        let p = { (x: CGFloat, y: CGFloat) in wolfPoint(x, y, in: rect) }
        var path = Path()
        // Eyes: slanted toward the brow, like a wolf's.
        for (cx, dir) in [(CGFloat(9.4), CGFloat(1)), (CGFloat(14.6), CGFloat(-1))] {
            path.move(to: p(cx - 1.5 * dir, 11.3))
            path.addQuadCurve(to: p(cx + 1.4 * dir, 12.9), control: p(cx + 0.6 * dir, 11.1))
            path.addQuadCurve(to: p(cx - 1.5 * dir, 11.3), control: p(cx - 0.4 * dir, 13.6))
            path.closeSubpath()
        }
        // Nose.
        path.move(to: p(10.4, 15.6))
        path.addLine(to: p(13.6, 15.6))
        path.addQuadCurve(to: p(12, 17.8), control: p(13.4, 16.9))
        path.addQuadCurve(to: p(10.4, 15.6), control: p(10.6, 16.9))
        path.closeSubpath()
        return path
    }
}

#Preview("Wolf tag") {
    VStack(spacing: 16) {
        HouseRulesTag()
        HouseRulesTag(style: .glyph)
        WolfHeadGlyph(size: 96).foregroundStyle(ChromeKit.houseTagInk)
        Text("Plakoto").padding().background(ChromeTheme.undoTint)
            .overlay(alignment: .trailing) { HouseRulesTag().offset(x: 110) }
    }
    .padding(40)
    .background(ChromeKit.pageColor)
}
