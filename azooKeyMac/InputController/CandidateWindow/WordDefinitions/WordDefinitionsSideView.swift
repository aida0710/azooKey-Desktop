import AppKit

@MainActor
final class WordDefinitionsSideView: NSView {
    private let heading = NSTextField(labelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let inset: CGFloat = 6
    // Only a short excerpt belongs beside a candidate; the full dictionary stays in Dictionary.app.
    private let maximumSummaryCharacters = 180
    private let maximumSummaryLines = 3
    private(set) var hasDefinition = false

    var preferredHeight: CGFloat {
        let width = MacCandidateMetrics.definitionWidth - inset * 2
        let measured = summary.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        let lineHeight = ceil((summary.font?.ascender ?? 0) - (summary.font?.descender ?? 0))
        return inset * 2 + heading.intrinsicContentSize.height + min(measured, lineHeight * CGFloat(maximumSummaryLines))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(heading)
        addSubview(summary)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("candidate-definition")
        summary.maximumNumberOfLines = maximumSummaryLines
        summary.lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(word: String?, result: WordDefinitionsModel.Result?, fontSize: CGFloat) {
        guard let word, case .definition(let text) = result else {
            hasDefinition = false
            heading.stringValue = ""
            summary.stringValue = ""
            setAccessibilityLabel("")
            return
        }
        hasDefinition = true
        heading.stringValue = word
        heading.font = .systemFont(ofSize: fontSize, weight: .medium)
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        summary.stringValue = String(normalized.prefix(maximumSummaryCharacters)) + (normalized.count > maximumSummaryCharacters ? "…" : "")
        summary.font = .systemFont(ofSize: max(10, fontSize - 1))
        setAccessibilityLabel(word + "\n" + summary.stringValue)
        needsLayout = true
    }

    func applyPalette(_ palette: CandidatePalette) {
        heading.textColor = palette.text
        summary.textColor = palette.text
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let headingHeight = heading.intrinsicContentSize.height
        heading.frame = NSRect(x: inset, y: bounds.height - inset - headingHeight,
                               width: bounds.width - inset * 2, height: headingHeight)
        summary.frame = NSRect(x: inset, y: inset, width: bounds.width - inset * 2,
                               height: max(0, heading.frame.minY - inset))
    }

    override func draw(_ dirtyRect: NSRect) {
        CandidateTheme.palette(for: effectiveAppearance).background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: MacCandidateMetrics.cornerRadius,
                     yRadius: MacCandidateMetrics.cornerRadius).fill()
    }
}
