import XCTest

/// Small text in amber, green and red has to be readable on the app's light and dark windows
/// (Logic/TextTones.swift, linked into this test target as GUILogic).
final class TextToneTests: XCTestCase {
    func testContrastMathMatchesWCAG() {
        let black = RGB(hex: 0x000000), white = RGB(hex: 0xFFFFFF)
        XCTAssertEqual(black.contrast(with: white), 21, accuracy: 0.001)
        XCTAssertEqual(white.contrast(with: white), 1, accuracy: 0.001)
        // The brand's bright amber and green on white: the numbers behind the bug report.
        XCTAssertEqual(RGB(hex: 0xF59E0B).contrast(with: white), 2.15, accuracy: 0.05)
        XCTAssertEqual(RGB(hex: 0x22C55E).contrast(with: white), 2.29, accuracy: 0.05)
    }

    func testTheBrightColoursReallyAreTooFaintForSmallTextInLightMode() {
        for bright in [RGB(hex: 0xF59E0B), RGB(hex: 0x22C55E)] {
            XCTAssertLessThan(bright.contrast(with: TextTones.lightBackgrounds[0]), 3)
        }
    }

    func testTextTonesAreReadableOnLightBackgrounds() {
        for (name, tone) in [("warning", TextTones.warning), ("live", TextTones.live), ("danger", TextTones.danger)] {
            for background in TextTones.lightBackgrounds {
                XCTAssertGreaterThanOrEqual(tone.light.contrast(with: background), 4.5, "\(name) on light")
            }
        }
    }

    func testTextTonesAreReadableOnDarkBackgrounds() {
        for (name, tone) in [("warning", TextTones.warning), ("live", TextTones.live), ("danger", TextTones.danger)] {
            for background in TextTones.darkBackgrounds {
                XCTAssertGreaterThanOrEqual(tone.dark.contrast(with: background), 4.5, "\(name) on dark")
            }
        }
    }
}
