import AppKit

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

    static func scoreColor(_ score: Int?, palette: CandidatePalette) -> NSColor {
        guard let score else { return palette.scoreUnknown }
        // Preserve the existing relative-score threshold, independent of selection.
        return score < 75 ? palette.scoreLow : palette.scoreHigh
    }
}
