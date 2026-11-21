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
}
