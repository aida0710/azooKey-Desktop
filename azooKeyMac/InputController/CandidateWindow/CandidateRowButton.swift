import AppKit
import Core

/// One complete converter candidate; the small number is a shortcut, never a replacement for the text.
@MainActor
final class CandidateRowButton: CandidatePresentationButton {
    let candidateIndex: Int
    private let candidateText: String
    private let number: String?
    private let horizontalInset: CGFloat = 8
    private let numberWidth: CGFloat = 28
    private let checkWidth: CGFloat = 24
    private let verticalInset: CGFloat = 8
    private let compact: Bool
    // The denser list keeps its font size and grows for the actual glyphs in each page.
    private let compactMinimumHeight: CGFloat = 32
    private let compactVerticalInsets: CGFloat = 6
    private let compactTextHeight: CGFloat

    init(item: CandidatePage.Item, number: String?, fontSize: CGFloat, compact: Bool = false) {
        candidateIndex = item.index
        candidateText = item.text
        self.number = number
        self.compact = compact
        let candidateFont = NSFont.systemFont(ofSize: fontSize)
        let glyphHeight = (item.text as NSString).size(withAttributes: [.font: candidateFont]).height
        compactTextHeight = ceil(max(glyphHeight, candidateFont.ascender - candidateFont.descender + candidateFont.leading))
        super.init()
        title = number.map { "\($0). \(item.text)" } ?? item.text
        font = candidateFont
        toolTip = item.detailDescription
        setAccessibilityLabel([item.text, item.reading].filter { !$0.isEmpty }.joined(separator: " "))
        setAccessibilityHelp(Localization.text("candidate.select") + "\n" + item.detailDescription)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var textInset: CGFloat { horizontalInset + (number == nil ? 0 : numberWidth + (compact ? 0 : 10)) }

    private var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 3
        return [.font: font ?? NSFont.systemFont(ofSize: 18), .paragraphStyle: paragraph]
    }

    var candidateTextFrame: NSRect {
        let textHeight = compact ? compactTextHeight : max(1, bounds.height - verticalInset * 2)
        return NSRect(x: textInset, y: compact ? (bounds.height - textHeight) / 2 : verticalInset,
                      width: max(1, bounds.width - textInset - (compact ? 0 : checkWidth) - horizontalInset),
                      height: textHeight)
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        if compact {
            return max(compactMinimumHeight, compactTextHeight + compactVerticalInsets)
        }
        let textWidth = max(1, width - textInset - checkWidth - horizontalInset)
        let height = (candidateText as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: textAttributes
        ).height
        // Keep a 44-point pointer target while reducing the space around each line.
        return max(44, ceil(height) + verticalInset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = CandidateTheme.palette(for: effectiveAppearance)
        let foreground = selected ? palette.selectionText : palette.text
        let radius: CGFloat = compact ? 3 : 9
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: radius, yRadius: radius)
        if selected || !compact {
            (selected ? palette.selection : palette.surface).setFill()
            shape.fill()
        }
        if selected {
            palette.border.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        var attributes = textAttributes
        attributes[.foregroundColor] = foreground
        if compact {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = paragraph
        }
        (candidateText as NSString).draw(with: candidateTextFrame, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                       attributes: attributes)
        if let number {
            let badge = NSRect(x: horizontalInset, y: compact ? bounds.midY - numberWidth / 2 : bounds.height - verticalInset - numberWidth,
                               width: numberWidth, height: numberWidth)
            if !compact {
                foreground.setStroke()
                NSBezierPath(roundedRect: badge.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).stroke()
            }
            let numberAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: max(14, (font?.pointSize ?? 18) - 4), weight: .medium),
                .foregroundColor: foreground
            ]
            let size = (number as NSString).size(withAttributes: numberAttributes)
            (number as NSString).draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2),
                                     withAttributes: numberAttributes)
        }
        if selected && !compact {
            ("✓" as NSString).draw(at: NSPoint(x: bounds.width - checkWidth - horizontalInset, y: bounds.height - 34),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .medium),
                                                     .foregroundColor: foreground])
        }
    }
}
