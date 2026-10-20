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
    private var previewText = ""

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
        case .definition(let definition)?: previewText = definition.components(separatedBy: .newlines).joined(separator: " ")
        case .notFound?: previewText = Localization.text("candidate.definition.notFound")
        case .loading?: previewText = Localization.text("candidate.definition.loading")
        case nil: previewText = ""
        }
        summary.stringValue = previewText
        let fullText: String
        if case .definition(let definition)? = result {
            fullText = definition
        } else {
            fullText = previewText
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
        let horizontalInset = min(inset, max(0, bounds.width / 2))
        let width = max(0, bounds.width - horizontalInset * 2)
        let visibleRows = min(rowCount, floor(max(0, bounds.height) / lineHeight))
        title.isHidden = visibleRows < rowCount
        source.isHidden = title.isHidden
        summary.isHidden = visibleRows == 0 || width == 0
        guard !summary.isHidden else {
            title.isHidden = true
            source.isHidden = true
            for label in [title, source, summary] { label.frame = .zero }
            return
        }
        // The candidate window may scale this region. Use fewer whole lines,
        // rather than shrinking fonts or drawing beyond the allocated region.
        let verticalInset = min(inset, max(0, (bounds.height - lineHeight * visibleRows) / 2))
        summary.stringValue = title.isHidden ? [title.stringValue, previewText].joined(separator: " · ") : previewText
        summary.frame = NSRect(x: horizontalInset, y: verticalInset, width: width, height: lineHeight)
        guard !title.isHidden else {
            title.frame = .zero
            source.frame = .zero
            return
        }
        let sourceWidth = min(source.intrinsicContentSize.width, width * maximumSourceWidthRatio)
        let sourceHeight = min(source.intrinsicContentSize.height, lineHeight)
        let titleWidth = max(0, width - sourceWidth - inset)
        title.frame = NSRect(x: horizontalInset, y: summary.frame.maxY, width: titleWidth, height: lineHeight)
        source.frame = NSRect(x: horizontalInset + width - sourceWidth, y: title.frame.midY - sourceHeight / 2,
                              width: sourceWidth, height: sourceHeight)
    }
}
