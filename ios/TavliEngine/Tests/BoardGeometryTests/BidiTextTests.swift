import XCTest
@testable import BoardGeometry

final class BidiTextTests: XCTestCase {
    func testIsolatedLeftToRightWrapsInLRIAndPDI() {
        XCTAssertEqual(BidiText.isolatedLeftToRight("13/7^ 8/4"), "\u{2066}13/7^ 8/4\u{2069}")
    }

    func testScoreIsUnchangedLeftToRight() {
        XCTAssertEqual(BidiText.score("1", "0", rightToLeft: false), "1 – 0")
    }

    func testScoreRightToLeftIsAnRTLIsolateOfTheSameLine() {
        let s = BidiText.score("۱", "۰", rightToLeft: true)
        XCTAssertEqual(s, "\u{2067}۱ – ۰\u{2069}")
    }

    func testDirectionalSymbols() {
        for name in ["chevron.left", "chevron.right", "arrow.left", "arrow.right",
                     "chevron.right.circle.fill", "arrow.left.circle"] {
            XCTAssertTrue(BidiText.isDirectionalSymbol(name), name)
        }
        for name in ["arrow.clockwise", "arrow.uturn.backward", "dice", "house", "xmark",
                     "rectangle.portrait.and.arrow.right", "chevron.up", "flag.checkered"] {
            XCTAssertFalse(BidiText.isDirectionalSymbol(name), name)
        }
    }

    func testReplacingASCIIDigits() {
        XCTAssertEqual(BidiText.replacingASCIIDigits(in: "63%", zero: "۰"), "۶۳%")
        XCTAssertEqual(BidiText.replacingASCIIDigits(in: "+0.52", zero: "۰"), "+۰.۵۲")
        XCTAssertEqual(BidiText.replacingASCIIDigits(in: "63%", zero: "0"), "63%")
        XCTAssertEqual(BidiText.replacingASCIIDigits(in: "no digits", zero: "۰"), "no digits")
    }

    func testDecimalPointOnlyBetweenDigits() {
        XCTAssertEqual(BidiText.replacingDecimalPoint(in: "+۰.۵۲", with: "٫"), "+۰.۵۲")  // Persian digits: not ASCII
        XCTAssertEqual(BidiText.replacingDecimalPoint(in: "+0.52", with: "٫"), "+0٫52")
        XCTAssertEqual(BidiText.replacingDecimalPoint(in: "v1. 0.5", with: "٫"), "v1. 0٫5")
        XCTAssertEqual(BidiText.replacingDecimalPoint(in: "+0.52", with: "."), "+0.52")
    }

    func testLocalizedNumberIsByteIdenticalForWesternDigits() {
        XCTAssertEqual(BidiText.localizedNumber("+0.52", zero: "0", decimalSeparator: "."), "+0.52")
        XCTAssertEqual(BidiText.localizedNumber("\u{2212}0.48", zero: "0", decimalSeparator: ","), "\u{2212}0.48")
    }

    func testLocalizedNumberPersianKeepsSignInsideTheIsolate() {
        XCTAssertEqual(BidiText.localizedNumber("\u{2212}0.48", zero: "۰", decimalSeparator: "٫"),
                       "\u{2066}\u{2212}۰٫۴۸\u{2069}")
        XCTAssertEqual(BidiText.localizedNumber("\u{2212}16%", zero: "۰", decimalSeparator: "٫"),
                       "\u{2066}\u{2212}۱۶%\u{2069}")
    }

    func testListSeparator() {
        XCTAssertEqual(BidiText.listSeparator(rightToLeft: false), " \u{00B7} ")
        XCTAssertEqual(BidiText.listSeparator(rightToLeft: true), "\u{060C} ")
    }
}
