import AppKit
import Core

/// A small score badge, visually separate from candidate selection.
@MainActor
enum CandidateScoreBadge {
    static let lineHeight: CGFloat = 16
    private static let fontSize: CGFloat = 12 // Candidate words retain the larger configured font.
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
    // Keep one digit and the unavailable mark in an equally readable badge.
    private static let minimumWidth: CGFloat = 22
    private static let horizontalInset: CGFloat = 3

    static func draw(presentation: CandidateScorePresentation, frame: NSRect, palette: CandidatePalette) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: palette.scoreText, .paragraphStyle: style
        ]
        let label = presentation.label as NSString
        let width = min(frame.width, max(minimumWidth, label.size(withAttributes: attributes).width + horizontalInset * 2))
        let badge = NSRect(x: frame.midX - width / 2, y: frame.maxY, width: width, height: lineHeight)
        CandidateTheme.scoreColor(presentation.role, palette: palette).setFill()
        NSBezierPath(rect: badge).fill()
        label.draw(in: badge, withAttributes: attributes)
    }
}
