import AppKit
import Core

/// Explicit disclosure and commit actions, kept separate from candidate selection.
@MainActor
final class CandidateActionsView: NSView {
    var onTreeToggle: (() -> Void)?
    var onDetailsToggle: (() -> Void)?
    var onSubmit: ((Int) -> Void)?
    var onPageSelection: ((Int) -> Void)?
    private var treeToggle = CandidatePresentationButton()
    private var detailsToggle = CandidatePresentationButton()
    private var confirm = CandidatePresentationButton()
    private var candidateIndex: Int?
    private var generation: UInt = 0
    private var enterConfirmsCandidate = false
    private var page: CandidatePage?
    private var pagingButtons: [CandidatePresentationButton] = []
    private var showsDetailsToggle = true
    private let inset: CGFloat = 8
    private let gap: CGFloat = 6
    private let buttonHeight: CGFloat = 38
    private let buttonTextInset: CGFloat = 16
    private let compactInset: CGFloat = 2
    private let compactGap: CGFloat = 2
    // The flat footer stays smaller than a candidate row without reducing its text.
    private let compactButtonHeight: CGFloat = 28

    private var buttonWidths: [CGFloat] {
        [treeToggle, detailsToggle, confirm].map { $0.intrinsicContentSize.width + buttonTextInset }
    }

    private var pageDescription: String? {
        page.map { String(format: Localization.text("candidate.position"), $0.position.map(String.init) ?? "—", String($0.totalCount)) }
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        if page != nil {
            return (compactControlFrames(width: width).map { $0.frame.maxY }.max() ?? 0) + compactInset
        }
        let stacked = buttonWidths.reduce(0, +) + gap * 2 + inset * 2 > width
        return (stacked ? buttonHeight * 2 + gap : buttonHeight) + inset * 2
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        installDisclosureButtons()
        installConfirmButton()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(candidateIndex: Int?, generation: UInt, treeExpanded: Bool, detailsExpanded: Bool,
                enterConfirmsCandidate: Bool, page: CandidatePage? = nil) {
        let compactChanged = (self.page == nil) != (page == nil)
        if self.page != page || self.generation != generation {
            self.page = page
            installPagingButtons()
        }
        if self.generation != generation || self.enterConfirmsCandidate != enterConfirmsCandidate || compactChanged {
            // Queued disclosure actions must not change a later candidate generation's presentation.
            installDisclosureButtons()
        }
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
        let treeTitle = Localization.text(treeExpanded ? "candidate.closeTree" : "candidate.openTree")
        let detailsTitle = Localization.text(detailsExpanded ? "candidate.closeDetails" : "candidate.openDetails")
        treeToggle.title = page == nil ? treeTitle : "⋯"
        detailsToggle.title = page == nil ? detailsTitle : "ⓘ"
        for (button, title) in [(treeToggle, treeTitle), (detailsToggle, detailsTitle)] {
            button.setAccessibilityLabel(title)
            button.toolTip = title
        }
        showsDetailsToggle = page == nil || treeExpanded || detailsExpanded
        detailsToggle.isHidden = !showsDetailsToggle
        for button in pagingButtons + [treeToggle, detailsToggle, confirm] { button.isFlat = page != nil }
        confirm.setAccessibilityHelp(pageDescription)
        treeToggle.selected = treeExpanded
        detailsToggle.selected = detailsExpanded
        treeToggle.setAccessibilityValue(treeExpanded)
        detailsToggle.setAccessibilityValue(detailsExpanded)
        needsLayout = true
    }

    private func installDisclosureButtons() {
        for button in [treeToggle, detailsToggle] {
            button.activate = nil
            button.isEnabled = false
            button.removeFromSuperview()
        }
        let treeButton = CandidatePresentationButton()
        let detailsButton = CandidatePresentationButton()
        treeToggle = treeButton
        detailsToggle = detailsButton
        treeButton.setAccessibilityIdentifier("candidate-tree-toggle")
        detailsButton.setAccessibilityIdentifier("candidate-details-toggle")
        treeButton.activate = { [weak self, weak treeButton] in
            guard let self, let treeButton, self.treeToggle === treeButton, !treeButton.isHidden else {
                return
            }
            self.onTreeToggle?()
        }
        detailsButton.activate = { [weak self, weak detailsButton] in
            guard let self, let detailsButton, self.detailsToggle === detailsButton, !detailsButton.isHidden else {
                return
            }
            self.onDetailsToggle?()
        }
        addSubview(treeButton)
        addSubview(detailsButton)
    }

    private func installPagingButtons() {
        for button in pagingButtons {
            button.activate = nil
            button.removeFromSuperview()
        }
        pagingButtons = []
        guard let page, page.previousIndex != nil || page.nextIndex != nil else {
            return
        }
        for (symbol, key, index) in [("‹", "candidate.previousPage", page.previousIndex), ("›", "candidate.nextPage", page.nextIndex)] {
            let button = CandidatePresentationButton()
            button.title = symbol
            button.setAccessibilityIdentifier(key)
            button.setAccessibilityLabel(Localization.text(key))
            button.setAccessibilityHelp(pageDescription)
            button.toolTip = Localization.text(key)
            button.isEnabled = index != nil
            button.activate = { [weak self, weak button] in
                guard let self, let button, let index, self.pagingButtons.contains(where: { $0 === button }),
                      !self.isHidden, !button.isHidden else {
                    return
                }
                self.onPageSelection?(index)
            }
            pagingButtons.append(button)
            addSubview(button)
        }
    }

    private func compactControlFrames(width: CGFloat) -> [(button: CandidatePresentationButton, frame: NSRect)] {
        let buttons = pagingButtons + [treeToggle] + (showsDetailsToggle ? [detailsToggle] : []) + [confirm]
        let available = max(0, width - compactInset * 2)
        var x = compactInset
        var y = compactInset
        return buttons.map { button in
            let preferredWidth = button === confirm ? max(compactButtonHeight, button.intrinsicContentSize.width + buttonTextInset) : compactButtonHeight
            let buttonWidth = min(available, preferredWidth)
            if x > compactInset && x + buttonWidth > width - compactInset {
                x = compactInset
                y += compactButtonHeight + compactGap
            }
            let frame = NSRect(x: x, y: y, width: buttonWidth, height: compactButtonHeight)
            x += buttonWidth + compactGap
            return (button, frame)
        }
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
            guard let self, let button, self.confirm === button, button.isEnabled, let index = self.candidateIndex else {
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
        if page != nil {
            for (button, frame) in compactControlFrames(width: bounds.width) { button.frame = frame }
            return
        }
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
