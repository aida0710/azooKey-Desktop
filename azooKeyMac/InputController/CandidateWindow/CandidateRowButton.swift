import AppKit
import Core

/// One complete converter candidate; the small number is a shortcut, never a replacement for the text.
@MainActor
final class CandidateRowButton: CandidatePresentationButton {
    let candidateIndex: Int
    private let candidateText: String
    private let number: String?
    private let horizontalInset: CGFloat = 5
    private let numberWidth: CGFloat = 16
    private let definitionIconWidth: CGFloat = 16
    private let verticalInset: CGFloat = 3
    var hasDefinition = false {
        didSet { needsDisplay = true }
    }

    init(item: CandidatePage.Item, number: String?, fontSize: CGFloat) {
        candidateIndex = item.index
        candidateText = item.text
        self.number = number
        super.init()
        title = number.map { "\($0). \(item.text)" } ?? item.text
        font = .systemFont(ofSize: fontSize)
        toolTip = item.detailDescription
        setAccessibilityLabel([item.text, item.reading].filter { !$0.isEmpty }.joined(separator: " "))
        setAccessibilityHelp(Localization.text("candidate.select") + "\n" + item.detailDescription)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var textInset: CGFloat { horizontalInset + (number == nil ? 0 : numberWidth + 4) }

    private var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 0
        return [.font: font ?? NSFont.systemFont(ofSize: 18), .paragraphStyle: paragraph]
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - textInset - definitionIconWidth - horizontalInset)
        let height = (candidateText as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: textAttributes
        ).height
        return ceil(height) + verticalInset * 2
    }

    var preferredWidth: CGFloat {
        ceil((candidateText as NSString).size(withAttributes: textAttributes).width) +
            textInset + definitionIconWidth + horizontalInset
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = CandidateTheme.palette(for: effectiveAppearance)
        let foreground = selected ? palette.selectionText : palette.text
        if selected {
            palette.selection.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        }
        var attributes = textAttributes
        attributes[.foregroundColor] = foreground
        let textRect = NSRect(x: textInset, y: verticalInset,
                              width: max(1, bounds.width - textInset - definitionIconWidth - horizontalInset),
                              height: max(1, bounds.height - verticalInset * 2))
        (candidateText as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                       attributes: attributes)
        if let number {
            let numberAttributes: [NSAttributedString.Key: Any] = [
                .font: CandidateNumberFont.make(size: max(11, (font?.pointSize ?? 14) - 3), weight: .regular),
                .foregroundColor: selected ? foreground : palette.secondaryText
            ]
            let size = (number as NSString).size(withAttributes: numberAttributes)
            (number as NSString).draw(at: NSPoint(x: horizontalInset + (numberWidth - size.width) / 2,
                                                y: (bounds.height - size.height) / 2), withAttributes: numberAttributes)
        }
        if hasDefinition, let icon = NSImage(systemSymbolName: "book", accessibilityDescription: nil) {
            let iconSize: CGFloat = 11 // An availability mark stays secondary to the candidate word.
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: 0, width: iconSize, height: iconSize)
            let iconText = NSMutableAttributedString(attachment: attachment)
            iconText.addAttribute(.foregroundColor, value: foreground, range: NSRange(location: 0, length: iconText.length))
            iconText.draw(in: NSRect(x: bounds.width - definitionIconWidth, y: (bounds.height - iconSize) / 2,
                                    width: iconSize, height: iconSize))
        }
    }
}
