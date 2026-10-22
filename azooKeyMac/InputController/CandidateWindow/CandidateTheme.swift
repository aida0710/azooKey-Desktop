import AppKit
import Core

@MainActor
enum CandidateTheme {
    static func name(for appearance: NSAppearance, increaseContrast: Bool) -> String {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        let contrast = increaseContrast || match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
        return contrast ? (dark ? "highContrastDark" : "highContrastLight") : (dark ? "dark" : "light")
    }

    static func palette(for appearance: NSAppearance) -> CandidatePalette {
        let mode = name(for: appearance, increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        return CandidatePaletteData.palettes[mode]!
    }

    /// Core decides the role; the palette only supplies its color.
    static func scoreColor(_ role: CandidateScoreRole, palette: CandidatePalette) -> NSColor {
        switch role {
        case .scoreLow: palette.scoreLow
        case .scoreHigh: palette.scoreHigh
        case .scoreUnknown: palette.scoreUnknown
        }
    }
}
