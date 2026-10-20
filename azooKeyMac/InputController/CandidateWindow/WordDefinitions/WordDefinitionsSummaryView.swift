import AppKit
import Core

/// A compact, non-focusable preview. The existing detail area keeps the full text.
@MainActor
final class WordDefinitionsSummaryView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let source = NSTextField(labelWithString: "")
    private let inset: CGFloat = 6
    // Two compact lines retain the full candidate font size, including its Japanese glyphs.
    private let lineHeightScale: CGFloat = 1.35
    private let rowCount: CGFloat = 2
    // Leave most of the heading row available for the word being defined.
    private let maximumSourceWidthRatio: CGFloat = 0.4
    private var fontSize: CGFloat = 18
    private(set) var detailDescription = ""

    var preferredHeight: CGFloat { ceil(fontSize * lineHeightScale) * rowCount + inset * 2 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [title, summary, source] {
            label.isSelectable = false
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        source.font = .systemFont(ofSize: 12)
        setAccessibilityIdentifier("candidate-definition-summary")
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(target: WordDefinitionsModel.Target?, result: WordDefinitionsModel.Result?, fontSize: CGFloat) {
        self.fontSize = fontSize
        isHidden = target == nil
        title.font = .systemFont(ofSize: fontSize, weight: .medium)
        summary.font = .systemFont(ofSize: fontSize)
        title.stringValue = target.map { String(format: Localization.text("candidate.definition.title"), $0.word) } ?? ""
        source.stringValue = Localization.text("candidate.definition.source")
        source.setAccessibilityHelp(Localization.text("candidate.definition.detailsHint"))
        setAccessibilityHelp(Localization.text("candidate.definition.readingNote"))
        switch result {
        case .definition(let definition)?: summary.stringValue = definition.components(separatedBy: .newlines).joined(separator: " ")
        case .notFound?: summary.stringValue = Localization.text("candidate.definition.notFound")
        case .loading?: summary.stringValue = Localization.text("candidate.definition.loading")
        case nil: summary.stringValue = ""
        }
        let fullText: String
        if case .definition(let definition)? = result {
            fullText = definition
        } else {
            fullText = summary.stringValue
        }
        detailDescription = target == nil ? "" : [title.stringValue, Localization.text("candidate.definition.source"),
                                                  Localization.text("candidate.definition.readingNote"), fullText].joined(separator: "\n")
        needsLayout = true
    }

    func applyPalette(_ palette: CandidatePalette) {
        title.textColor = palette.text
        summary.textColor = palette.text
        source.textColor = palette.secondaryText
    }

    override func layout() {
        super.layout()
        let lineHeight = ceil(fontSize * lineHeightScale)
        let width = max(1, bounds.width - inset * 2)
        let sourceWidth = min(source.intrinsicContentSize.width, width * maximumSourceWidthRatio)
        let sourceHeight = min(source.intrinsicContentSize.height, lineHeight)
        summary.frame = NSRect(x: inset, y: inset, width: width, height: lineHeight)
        title.frame = NSRect(x: inset, y: summary.frame.maxY, width: max(1, width - sourceWidth - inset), height: lineHeight)
        source.frame = NSRect(x: bounds.width - inset - sourceWidth, y: title.frame.midY - sourceHeight / 2,
                              width: sourceWidth, height: sourceHeight)
    }
}
