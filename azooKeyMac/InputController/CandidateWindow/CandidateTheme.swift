import AppKit

@MainActor
enum CandidateTheme {
    // Preserve the existing visual split without changing the conditional score.
    private static let relativeScoreColorSplit = 75

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

    static func scoreColor(_ score: Int?, palette: CandidatePalette) -> NSColor {
        guard let score else {
            return palette.scoreUnknown
        }
        return score < relativeScoreColorSplit ? palette.scoreLow : palette.scoreHigh
    }
}
