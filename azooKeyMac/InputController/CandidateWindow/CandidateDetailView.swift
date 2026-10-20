import AppKit
import Core

@MainActor
private final class CandidateDetailDocument: NSView {
    override var isFlipped: Bool { true }
}

/// A keyboard-readable detail area that leaves the document as first responder.
@MainActor
final class CandidateDetailView: NSScrollView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let content = CandidateDetailDocument()
    private var displayedText = ""
    private let inset: CGFloat = 8
    static let maximumHeight: CGFloat = 160

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        label.isSelectable = false
        label.setAccessibilityLabel(Localization.text("candidate.detail"))
        content.addSubview(label)
        documentView = content
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyPalette(_ palette: CandidatePalette) {
        label.textColor = palette.text
    }

    func update(text: String, fontSize: CGFloat) {
        label.font = .systemFont(ofSize: fontSize)
        label.stringValue = text
        if text != displayedText {
            displayedText = text
            contentView.scroll(to: .zero)
        }
        resizeLabel()
    }

    override func layout() {
        super.layout()
        resizeLabel()
    }

    private func resizeLabel() {
        let width = max(1, contentSize.width - inset * 2)
        let height = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        label.frame = NSRect(x: inset, y: inset, width: width, height: height)
        content.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: height + inset * 2)
    }

    func scrollPage(forward: Bool) {
        let step = max(1, contentSize.height - inset * 2)
        let limit = max(0, label.frame.maxY - contentSize.height)
        let offset = max(0, min(limit, contentView.bounds.minY + (forward ? step : -step)))
        contentView.scroll(to: NSPoint(x: 0, y: offset))
        reflectScrolledClipView(contentView)
    }
}
