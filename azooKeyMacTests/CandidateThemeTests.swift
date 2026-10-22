import AppKit
@testable import azooKeyMac
import Core
import XCTest

@MainActor
final class CandidateThemeTests: XCTestCase {
    func testAppearanceAndAccessibilityPreferenceChooseAllFourPalettes() throws {
        for (appearance, increaseContrast, expected) in [
            (NSAppearance.Name.aqua, false, "light"), (.darkAqua, false, "dark"),
            (.aqua, true, "highContrastLight"), (.darkAqua, true, "highContrastDark")
        ] {
            let native = try XCTUnwrap(NSAppearance(named: appearance))
            XCTAssertEqual(CandidateTheme.name(for: native, increaseContrast: increaseContrast), expected)
        }
    }

    func testHighContrastAppearanceRequestsKeepTheirBaseColorWithContrastEnabled() throws {
        // Apple directs views to use Aqua/Dark Aqua plus the accessibility
        // preference, not to assign a high-contrast appearance directly:
        // https://developer.apple.com/documentation/appkit/nsappearance/name-swift.struct/accessibilityhighcontrastaqua
        let supported: [NSAppearance.Name] = [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
        ]
        for (requested, expected) in [
            (NSAppearance.Name.accessibilityHighContrastAqua, "highContrastLight"),
            (.accessibilityHighContrastDarkAqua, "highContrastDark")
        ] {
            let native = try XCTUnwrap(NSAppearance(named: requested))
            let systemContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let observation: [String: Any] = [
                "requested": requested.rawValue, "native": native.name.rawValue,
                "bestMatch": native.bestMatch(from: supported)?.rawValue ?? "nil",
                "workspaceIncreaseContrast": systemContrast,
                "withoutContrast": CandidateTheme.name(for: native, increaseContrast: false),
                "withContrast": CandidateTheme.name(for: native, increaseContrast: true)
            ]
            let encoded = try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys])
            let description = try XCTUnwrap(String(data: encoded, encoding: .utf8))
            print("candidate-appearance: " + description)
            XCTAssertEqual(CandidateTheme.name(for: native, increaseContrast: true), expected)
        }
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
            XCTAssertEqual(CandidateTheme.scoreColor(CandidateScorePresentation(relativeScore: nil).role, palette: palette),
                           palette.scoreUnknown)
            XCTAssertEqual(CandidateTheme.scoreColor(CandidateScorePresentation(relativeScore: 74).role, palette: palette),
                           palette.scoreLow)
            XCTAssertEqual(CandidateTheme.scoreColor(CandidateScorePresentation(relativeScore: 75).role, palette: palette),
                           palette.scoreHigh)
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
