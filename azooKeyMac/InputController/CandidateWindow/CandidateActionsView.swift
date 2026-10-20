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
    private let inset: CGFloat = 12
    private let gap: CGFloat = 8
    private let buttonHeight: CGFloat = 38
    var preferredHeight: CGFloat { buttonHeight + inset * 2 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(treeToggle)
        addSubview(detailsToggle)
        treeToggle.activate = { [weak self] in self?.onTreeToggle?() }
        detailsToggle.activate = { [weak self] in self?.onDetailsToggle?() }
        installConfirmButton()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(candidateIndex: Int?, generation: UInt, treeExpanded: Bool, detailsExpanded: Bool) {
        if self.candidateIndex != candidateIndex || self.generation != generation {
            self.candidateIndex = candidateIndex
            self.generation = generation
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
        button.title = Localization.text("candidate.submit") + "  ↵"
        button.setAccessibilityLabel(Localization.text("candidate.submit"))
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
        let confirmWidth = max(98, confirm.intrinsicContentSize.width + 24)
        let remaining = max(0, bounds.width - inset * 2 - confirmWidth - gap * 2)
        let treeWidth = min(remaining / 2, treeToggle.intrinsicContentSize.width + 16)
        treeToggle.frame = NSRect(x: inset, y: inset, width: treeWidth, height: buttonHeight)
        detailsToggle.frame = NSRect(x: treeToggle.frame.maxX + gap, y: inset,
                                     width: max(0, remaining - treeWidth), height: buttonHeight)
        confirm.frame = NSRect(x: bounds.width - inset - confirmWidth, y: inset,
                               width: confirmWidth, height: buttonHeight)
    }
}
