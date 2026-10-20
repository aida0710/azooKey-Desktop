import AppKit
import Core

/// One complete converter candidate; the small number is a shortcut, never a replacement for the text.
@MainActor
final class CandidateRowButton: CandidatePresentationButton {
    let candidateIndex: Int
    private let candidateText: String
    private let number: String?
    private let horizontalInset: CGFloat = 12
    private let numberWidth: CGFloat = 28
    private let checkWidth: CGFloat = 24
    private let verticalInset: CGFloat = 12

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

    private var textInset: CGFloat { horizontalInset + (number == nil ? 0 : numberWidth + 10) }

    private var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 3
        return [.font: font ?? NSFont.systemFont(ofSize: 18), .paragraphStyle: paragraph]
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - textInset - checkWidth - horizontalInset)
        let height = (candidateText as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: textAttributes
        ).height
        // 52 points gives the standard 18-point text a comfortable pointer target.
        return max(52, ceil(height) + verticalInset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = CandidateTheme.palette(for: effectiveAppearance)
        let foreground = selected ? palette.selectionText : palette.text
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 9, yRadius: 9)
        (selected ? palette.selection : palette.surface).setFill()
        shape.fill()
        if selected {
            palette.border.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        var attributes = textAttributes
        attributes[.foregroundColor] = foreground
        let textRect = NSRect(x: textInset, y: verticalInset,
                              width: max(1, bounds.width - textInset - checkWidth - horizontalInset),
                              height: max(1, bounds.height - verticalInset * 2))
        (candidateText as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                       attributes: attributes)
        if let number {
            let badge = NSRect(x: horizontalInset, y: bounds.height - verticalInset - numberWidth,
                               width: numberWidth, height: numberWidth)
            foreground.setStroke()
            NSBezierPath(roundedRect: badge.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).stroke()
            let numberAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: max(14, (font?.pointSize ?? 18) - 4), weight: .medium),
                .foregroundColor: foreground
            ]
            let size = (number as NSString).size(withAttributes: numberAttributes)
            (number as NSString).draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2),
                                     withAttributes: numberAttributes)
        }
        if selected {
            ("✓" as NSString).draw(at: NSPoint(x: bounds.width - checkWidth - horizontalInset, y: bounds.height - 34),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .medium),
                                                     .foregroundColor: foreground])
        }
    }
}
