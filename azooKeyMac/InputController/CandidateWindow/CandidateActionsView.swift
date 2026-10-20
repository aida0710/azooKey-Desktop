import AppKit
import Core

/// Explicit disclosure and commit actions, kept separate from candidate selection.
@MainActor
final class CandidateActionsView: NSView {
    var onTreeToggle: (() -> Void)?
    var onDetailsToggle: (() -> Void)?
    var onSubmit: ((Int) -> Void)?
    private let treeToggle = CandidatePresentationButton()
    private let detailsToggle = CandidatePresentationButton()
    private var confirm = CandidatePresentationButton()
    private var candidateIndex: Int?
    private var generation: UInt = 0
    private var enterConfirmsCandidate = false
    private let inset: CGFloat = 8
    private let gap: CGFloat = 6
    private let buttonHeight: CGFloat = 38
    private let buttonTextInset: CGFloat = 16

    private var buttonWidths: [CGFloat] {
        [treeToggle, detailsToggle, confirm].map { $0.intrinsicContentSize.width + buttonTextInset }
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        let stacked = buttonWidths.reduce(0, +) + gap * 2 + inset * 2 > width
        return (stacked ? buttonHeight * 2 + gap : buttonHeight) + inset * 2
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(treeToggle)
        addSubview(detailsToggle)
        treeToggle.activate = { [weak self] in self?.onTreeToggle?() }
        detailsToggle.activate = { [weak self] in self?.onDetailsToggle?() }
        installConfirmButton()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(candidateIndex: Int?, generation: UInt, treeExpanded: Bool, detailsExpanded: Bool,
                enterConfirmsCandidate: Bool) {
        if self.candidateIndex != candidateIndex || self.generation != generation ||
            self.enterConfirmsCandidate != enterConfirmsCandidate {
            self.candidateIndex = candidateIndex
            self.generation = generation
            self.enterConfirmsCandidate = enterConfirmsCandidate
            // An assistive action queued for an old candidate must not acquire the new target.
            confirm.activate = nil
            confirm.removeFromSuperview()
            installConfirmButton()
        }
        treeToggle.title = Localization.text(treeExpanded ? "candidate.closeTree" : "candidate.openTree")
        detailsToggle.title = Localization.text(detailsExpanded ? "candidate.closeDetails" : "candidate.openDetails")
        treeToggle.selected = treeExpanded
        detailsToggle.selected = detailsExpanded
        treeToggle.setAccessibilityValue(treeExpanded)
        detailsToggle.setAccessibilityValue(detailsExpanded)
        needsLayout = true
    }

    private func installConfirmButton() {
        let button = CandidatePresentationButton()
        confirm = button
        button.primary = true
        let titleKey = enterConfirmsCandidate ? "candidate.submit" : "candidate.submitCandidate"
        button.title = Localization.text(titleKey) + (enterConfirmsCandidate ? "  ↵" : "")
        button.setAccessibilityLabel(Localization.text(titleKey))
        button.setAccessibilityIdentifier("candidate-confirm")
        button.isEnabled = candidateIndex != nil
        button.activate = { [weak self, weak button] in
            guard let self, let button, self.confirm === button, let index = self.candidateIndex else {
                return
            }
            // Retire before the callback, which can synchronously replace the candidate page.
            button.activate = nil
            button.isEnabled = false
            self.onSubmit?(index)
        }
        addSubview(button)
    }

    override func layout() {
        super.layout()
        let widths = buttonWidths
        let available = max(0, bounds.width - inset * 2)
        let stacked = widths.reduce(0, +) + gap * 2 > available
        let confirmWidth = stacked ? available : widths[2]
        let toggleWidth = stacked ? available : max(0, available - confirmWidth - gap)
        let treeWidth = min(max(0, toggleWidth - gap) / 2, widths[0])
        let toggleY = inset + (stacked ? buttonHeight + gap : 0)
        treeToggle.frame = NSRect(x: inset, y: toggleY, width: treeWidth, height: buttonHeight)
        detailsToggle.frame = NSRect(x: treeToggle.frame.maxX + gap, y: toggleY,
                                     width: max(0, toggleWidth - treeWidth - gap), height: buttonHeight)
        confirm.frame = NSRect(x: bounds.width - inset - confirmWidth, y: inset,
                               width: confirmWidth, height: buttonHeight)
    }
}
