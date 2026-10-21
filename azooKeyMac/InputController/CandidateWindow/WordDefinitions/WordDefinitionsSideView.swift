import AppKit
import Core

/// The current word's dictionary entry scrolls independently beside the candidate list.
@MainActor
final class WordDefinitionsSideView: NSView {
    var onLayoutChanged: (() -> Void)?
    var onPointerExit: (() -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let source = NSTextField(labelWithString: "")
    private let text = CandidateDetailView(frame: .zero)
    private var toggle = CandidatePresentationButton()
    private var target: WordDefinitionsModel.Target?
    private var definition: String?
    private var preview = ""
    private var fontSize: CGFloat = 18
    private var pointerTracking: NSTrackingArea?
    private(set) var expanded = false
    private let inset: CGFloat = 6
    private let gap: CGFloat = 6
    private let buttonHeight: CGFloat = 44
    // The short card shows two text lines; the full entry uses its own scroll view.
    private let summaryLineCount: CGFloat = 2
    private let textVerticalInsets: CGFloat = 22
    private let expandedTextHeight: CGFloat = 220
    private let maximumSummaryCharacters = 96
    private let lineHeightScale: CGFloat = 1.35
    // Keep most of the heading row available for the word being defined.
    private let maximumSourceWidthRatio: CGFloat = 0.4

    var preferredHeight: CGFloat {
        let lineHeight = ceil(fontSize * lineHeightScale)
        let textHeight = expanded ? expandedTextHeight : lineHeight * summaryLineCount + textVerticalInsets
        return inset * 2 + lineHeight + gap * 2 + textHeight + buttonHeight
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [title, source] {
            label.isSelectable = false
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        source.font = .systemFont(ofSize: 12)
        source.stringValue = Localization.text("candidate.definition.source")
        source.toolTip = source.stringValue
        source.setAccessibilityHelp(Localization.text("candidate.definition.readingNote"))
        addSubview(text)
        installToggle()
        setAccessibilityIdentifier("candidate-definition-side")
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(target: WordDefinitionsModel.Target?, result: WordDefinitionsModel.Result?, fontSize: CGFloat) {
        let wasHidden = isHidden
        let wasExpanded = expanded
        let targetChanged = self.target != target
        let previouslyHadDefinition = definition != nil
        self.target = target
        self.fontSize = fontSize
        isHidden = target == nil
        title.font = .systemFont(ofSize: fontSize, weight: .medium)
        title.stringValue = target.map { String(format: Localization.text("candidate.definition.title"), $0.word) } ?? ""
        if targetChanged { expanded = false }
        switch result {
        case .definition(let definition)?:
            self.definition = definition
            let characters = Array(definition.components(separatedBy: .newlines).joined(separator: " "))
            preview = String(characters.prefix(maximumSummaryCharacters)) + (characters.count > maximumSummaryCharacters ? "…" : "")
        case .notFound?:
            definition = nil
            preview = Localization.text("candidate.definition.notFound")
        case .loading?:
            definition = nil
            preview = Localization.text("candidate.definition.loading")
        case nil:
            definition = nil
            preview = ""
        }
        if definition == nil { expanded = false }
        if targetChanged || previouslyHadDefinition != (definition != nil) { installToggle() }
        refreshText()
        needsLayout = true
        if wasHidden != isHidden || wasExpanded != expanded { onLayoutChanged?() }
    }

    private func installToggle() {
        toggle.activate = nil
        toggle.isEnabled = false
        toggle.removeFromSuperview()
        let button = CandidatePresentationButton()
        toggle = button
        button.setAccessibilityIdentifier("candidate-definition-toggle")
        button.isEnabled = target != nil && definition != nil
        let originalTarget = target
        button.activate = { [weak self, weak button] in
            guard let self, let button, self.toggle === button, !self.isHidden, !button.isHidden, button.isEnabled,
                  self.target == originalTarget, self.definition != nil else {
                return
            }
            self.expanded.toggle()
            self.refreshText()
            self.needsLayout = true
            self.onLayoutChanged?()
        }
        addSubview(button)
    }

    private func refreshText() {
        toggle.title = Localization.text(expanded ? "candidate.definition.closeFull" : "candidate.definition.openFull")
        toggle.setAccessibilityValue(expanded)
        let body = expanded ? [definition ?? preview, Localization.text("candidate.definition.readingNote")].joined(separator: "\n\n") : preview
        text.update(text: body, fontSize: fontSize)
        text.setAccessibilityIdentifier("candidate-definition-text")
    }

    func applyPalette(_ palette: CandidatePalette) {
        needsDisplay = true
        title.textColor = palette.text
        source.textColor = palette.secondaryText
        text.applyPalette(palette)
        toggle.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = CandidateTheme.palette(for: effectiveAppearance)
        palette.background.setFill()
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        card.fill()
        palette.border.setStroke()
        card.lineWidth = 1
        card.stroke()
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - inset * 2)
        let views = [title as NSView, source, text, toggle]
        guard bounds.height >= inset * 2, width > 0 else {
            for view in views {
                view.isHidden = true
                view.frame = .zero
            }
            return
        }
        views.forEach { $0.isHidden = false }
        let lineHeight = min(ceil(fontSize * lineHeightScale), max(0, bounds.height - inset * 2))
        let sourceWidth = min(source.intrinsicContentSize.width, width * maximumSourceWidthRatio)
        let sourceHeight = min(source.intrinsicContentSize.height, lineHeight)
        title.frame = NSRect(x: inset, y: max(0, bounds.height - inset - lineHeight),
                             width: max(0, width - sourceWidth - gap), height: lineHeight)
        source.frame = NSRect(x: inset + width - sourceWidth, y: title.frame.midY - sourceHeight / 2,
                              width: sourceWidth, height: sourceHeight)
        let actionHeight = min(buttonHeight, max(0, title.frame.minY - gap))
        let actionWidth = min(width, max(buttonHeight, toggle.intrinsicContentSize.width + inset * 2))
        toggle.frame = NSRect(x: bounds.width - inset - actionWidth, y: min(inset, max(0, bounds.height - actionHeight)),
                              width: actionWidth, height: actionHeight)
        let textBottom = toggle.frame.maxY + gap
        text.frame = NSRect(x: 0, y: textBottom, width: bounds.width,
                            height: max(0, title.frame.minY - gap - textBottom))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        pointerTracking = tracking
    }

    override func mouseExited(with event: NSEvent) { onPointerExit?() }
}
