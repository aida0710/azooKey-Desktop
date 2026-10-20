import AppKit
import XCTest
@testable import azooKeyMac

@MainActor
final class CandidateThemeTests: XCTestCase {
    func testAppearanceAndAccessibilityPreferenceChooseAllFourPalettes() throws {
        for (appearance, expected) in [
            (NSAppearance.Name.aqua, "light"), (.darkAqua, "dark"),
            (.accessibilityHighContrastAqua, "highContrastLight"),
            (.accessibilityHighContrastDarkAqua, "highContrastDark")
        ] {
            let native = try XCTUnwrap(NSAppearance(named: appearance))
            XCTAssertEqual(CandidateTheme.name(for: native, increaseContrast: false), expected)
        }
        XCTAssertEqual(CandidateTheme.name(for: try XCTUnwrap(NSAppearance(named: .aqua)), increaseContrast: true), "highContrastLight")
        XCTAssertEqual(CandidateTheme.name(for: try XCTUnwrap(NSAppearance(named: .darkAqua)), increaseContrast: true), "highContrastDark")
    }

    func testAppKitSRGBTextColorsMeetTheContrastDesignTarget() throws {
        for (mode, palette) in CandidatePaletteData.palettes {
            for (foreground, background) in [
                (palette.text, palette.background), (palette.text, palette.surface),
                (palette.secondaryText, palette.background), (palette.secondaryText, palette.surface),
                (palette.selectionText, palette.selection), (palette.scoreText, palette.scoreLow),
                (palette.scoreText, palette.scoreHigh), (palette.scoreText, palette.scoreUnknown)
            ] {
                let first = try luminance(foreground)
                let second = try luminance(background)
                XCTAssertGreaterThanOrEqual((max(first, second) + 0.05) / (min(first, second) + 0.05), 4.5, mode)
            }
            XCTAssertEqual(CandidateTheme.scoreColor(nil, palette: palette), palette.scoreUnknown)
            XCTAssertEqual(CandidateTheme.scoreColor(74, palette: palette), palette.scoreLow)
            XCTAssertEqual(CandidateTheme.scoreColor(75, palette: palette), palette.scoreHigh)
        }
    }

    private func luminance(_ color: NSColor) throws -> CGFloat {
        let converted = try XCTUnwrap(color.usingColorSpace(.sRGB))
        XCTAssertEqual(converted.alphaComponent, 1)
        let components = [converted.redComponent, converted.greenComponent, converted.blueComponent]
        let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let weights: [CGFloat] = [0.2126, 0.7152, 0.0722]
        return zip(linear, weights).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
