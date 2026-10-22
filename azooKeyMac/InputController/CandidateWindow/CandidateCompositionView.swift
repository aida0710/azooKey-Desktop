import AppKit
import Core

/// The selected candidate stays visible independently of hover; the input state defines Enter's meaning.
@MainActor
final class CandidateCompositionView: NSView {
    private let heading = NSTextField(labelWithString: Localization.text("candidate.proposal"))
    private let text = CandidateDetailView(frame: .zero)
    private let remaining = CandidateDetailView(frame: .zero)
    private let headingHeight: CGFloat = 24
    private let horizontalInset: CGFloat = 11
    // Keep a few lines beside the commit target; longer remaining readings scroll independently.
    private let maximumRemainingHeight: CGFloat = 90

    override init(frame: NSRect) {
        super.init(frame: frame)
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        addSubview(heading)
        addSubview(text)
        addSubview(remaining)
        remaining.isHidden = true
        setAccessibilityIdentifier("candidate-composition")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(entry: CandidateTree.Entry?, fontSize: CGFloat, enterConfirmsCandidate: Bool) {
        let titleKey = enterConfirmsCandidate ? "candidate.composition" : "candidate.proposal"
        heading.stringValue = Localization.text(entry == nil ? "candidate.selectHint" : titleKey)
        text.update(text: entry?.text ?? "", fontSize: fontSize + 2)
        let reading = entry?.scope?.remainingReading ?? ""
        remaining.isHidden = reading.isEmpty
        remaining.update(text: reading.isEmpty ? "" : String(format: Localization.text("candidate.preview.remaining"), reading),
                         fontSize: max(14, fontSize - 4))
        needsLayout = true
    }

    private func remainingHeight(width: CGFloat) -> CGFloat {
        remaining.isHidden ? 0 : min(maximumRemainingHeight, remaining.preferredHeight(width: width))
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        headingHeight + text.preferredHeight(width: width) + remainingHeight(width: width)
    }

    func applyPalette(_ palette: CandidatePalette) {
        heading.textColor = palette.secondaryText
        text.applyPalette(palette)
        remaining.applyPalette(palette)
    }

    override func layout() {
        super.layout()
        let headingHeight = min(self.headingHeight, bounds.height)
        let available = max(0, bounds.height - headingHeight)
        let remainingHeight = min(remainingHeight(width: bounds.width), available / 2)
        heading.frame = NSRect(x: horizontalInset, y: bounds.height - headingHeight,
                               width: max(1, bounds.width - horizontalInset * 2), height: headingHeight)
        text.frame = NSRect(x: 0, y: remainingHeight, width: bounds.width, height: available - remainingHeight)
        // Keep the remaining reading outside the text's scroll area, including long commit targets.
        remaining.frame = NSRect(x: 0, y: 0, width: bounds.width, height: remainingHeight)
    }

    func scrollPage(forward: Bool) { text.scrollPage(forward: forward) }
}
