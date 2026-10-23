/// Candidate text sizes shared by every renderer, in logical pixels (96 dpi).
/// AppKit points and Windows DIPs use the same unit; GTK/GNOME logical
/// pixels too. Platforms convert only device pixels.
public struct CandidateTextMetrics: Codable, Equatable, Sendable {
    /// The configured candidate size before the desktop text scale. The
    /// standard size is close to Microsoft IME's candidate text (about 15px
    /// at 100%); large is one step bigger for readability.
    public static func baseFontSize(_ textSize: Config.CandidateTextSize.Value) -> Double {
        textSize == .large ? 18 : 14
    }

    /// Smaller desktop scales keep the configured size so candidates never
    /// become smaller than the setting.
    public static func fontSize(textSize: Config.CandidateTextSize.Value, textScale: Double) -> Double {
        baseFontSize(textSize) * max(1, textScale)
    }

    // Six pixels above and below a word; Windows' candidate list rows use the same.
    static let wordVerticalPadding = 12.0
    // Keeps the number badge readable at the standard size.
    static let minimumNumberFontSize = 12.0
    static let numberFontRatio = 2.0 / 3.0
    static let numberVerticalPadding = 6.0
    // Candidate words retain the larger configured font beside the score.
    static let scoreFontSize = 12.0
    static let scoreLineHeight = 16.0
    // One digit and the unavailable mark get the same badge width.
    static let scoreBadgeMinimumWidth = 22.0
    static let scoreBadgeHorizontalInset = 3.0

    public let fontSize: Double
    public let numberFontSize: Double
    public let scoreFontSize: Double
    /// Height of the word line inside a node.
    public let wordHeight: Double
    /// Height of the number badge line, reserved only when numbers are shown.
    public let numberHeight: Double
    /// Height of the score badge line, reserved only when scores are shown.
    public let scoreHeight: Double
    /// A score badge is its label width plus both insets, centered in
    /// `scoreFrame`, and never narrower than the minimum.
    public let scoreBadgeMinimumWidth: Double
    public let scoreBadgeHorizontalInset: Double

    /// - Parameter lineHeightRatio: A platform font's measured line height
    ///   divided by its font size. Lines grow when that font is taller than
    ///   the shared padding allows, so no glyph is clipped.
    public init(textSize: Config.CandidateTextSize.Value, textScale: Double, lineHeightRatio: Double? = nil) {
        fontSize = Self.fontSize(textSize: textSize, textScale: textScale)
        numberFontSize = max(Self.minimumNumberFontSize, fontSize * Self.numberFontRatio)
        scoreFontSize = Self.scoreFontSize
        let ratio = lineHeightRatio ?? 0
        wordHeight = max(fontSize + Self.wordVerticalPadding, fontSize * ratio)
        numberHeight = max(numberFontSize + Self.numberVerticalPadding, numberFontSize * ratio)
        scoreHeight = Self.scoreLineHeight
        scoreBadgeMinimumWidth = Self.scoreBadgeMinimumWidth
        scoreBadgeHorizontalInset = Self.scoreBadgeHorizontalInset
    }
}
