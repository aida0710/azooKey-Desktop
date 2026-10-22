/// Candidate text sizes shared by every renderer, in logical pixels (96 dpi).
/// AppKit points and Windows DIPs use the same unit; GTK/GNOME logical
/// pixels too. Platforms convert only device pixels.
public struct CandidateTextMetrics: Codable, Equatable, Sendable {
    /// The configured candidate size before the desktop text scale.
    public static func baseFontSize(_ textSize: Config.CandidateTextSize.Value) -> Double {
        textSize == .large ? 24 : 18
    }

    /// Smaller desktop scales keep the configured size so candidates never
    /// become smaller than the setting.
    public static func fontSize(textSize: Config.CandidateTextSize.Value, textScale: Double) -> Double {
        baseFontSize(textSize) * max(1, textScale)
    }

    // Leaves room above and below a word without growing past the 44px target.
    static let wordVerticalPadding = 14.0
    // Keeps the number badge readable at the standard size.
    static let minimumNumberFontSize = 12.0
    static let numberFontRatio = 2.0 / 3.0
    static let numberVerticalPadding = 6.0
    // Candidate words retain the larger configured font beside the score.
    static let scoreFontSize = 12.0
    static let scoreLineHeight = 16.0

    public let fontSize: Double
    public let numberFontSize: Double
    public let scoreFontSize: Double
    /// Height of the word line inside a node.
    public let wordHeight: Double
    /// Height of the number badge line, reserved only when numbers are shown.
    public let numberHeight: Double
    /// Height of the score badge line, reserved only when scores are shown.
    public let scoreHeight: Double

    /// - Parameter lineHeight: A measured line height at `fontSize`, when a
    ///   platform font is taller than the shared padding allows.
    public init(textSize: Config.CandidateTextSize.Value, textScale: Double, lineHeight: Double? = nil) {
        fontSize = Self.fontSize(textSize: textSize, textScale: textScale)
        numberFontSize = max(Self.minimumNumberFontSize, fontSize * Self.numberFontRatio)
        scoreFontSize = Self.scoreFontSize
        wordHeight = max(fontSize + Self.wordVerticalPadding, lineHeight ?? 0)
        numberHeight = numberFontSize + Self.numberVerticalPadding
        scoreHeight = Self.scoreLineHeight
    }
}
