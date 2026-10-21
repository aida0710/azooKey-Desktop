import AppKit
import Core

@MainActor
private final class CandidateListDocument: NSView {
    override var isFlipped: Bool { true }
}

/// The primary list shows complete existing candidates, bounded to the nine number keys.
@MainActor
final class CandidateNavigationView: NSView {
    var onSelection: ((Int) -> Void)?
    var onPreview: ((Int, NSButton, Bool) -> Void)?
    private let status = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private var previous = CandidatePresentationButton()
    private var next = CandidatePresentationButton()
    private let scroll = NSScrollView()
    private let document = CandidateListDocument()
    private var rows: [CandidateRowButton] = []
    private var page = CandidatePage(entries: [], selectionIndex: nil)
    private var numbers: [Int: String] = [:]
    private var fontSize: CGFloat = 18
    private var generation: UInt = 0
    private var revealSelection = false
    private var compact = false
    private var visibleRows = Config.CandidateVisibleRows.Value.seven
    // The list scrolls instead of hiding long candidates behind ellipses.
    private let maximumListHeight: CGFloat = 260
    private let headerHeight: CGFloat = 36
    private let hintHeight: CGFloat = 22
    private let inset: CGFloat = 8
    // Preserve at least one complete candidate row before optional sections.
    private let minimumRowViewportHeight: CGFloat = 44
    private let compactInset: CGFloat = 4
    var selectedCandidateControls: [NSButton] { rows.filter(\.selected) }
    var minimumHeight: CGFloat {
        guard page.totalCount > 0 else {
            return 0
        }
        return compact ? compactInset * 2 + compactRowHeight : headerHeight + hintHeight + minimumRowViewportHeight
    }

    private var compactRowHeight: CGFloat {
        rows.map { $0.preferredHeight(width: bounds.width) }.max() ?? 0
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        guard page.totalCount > 0 else {
            return 0
        }
        if compact {
            return compactInset * 2 + CGFloat(min(visibleRows.rawValue, rows.count)) * compactRowHeight
        }
        let rowWidth = max(1, width - inset * 2)
        let contentHeight = rows.reduce(CGFloat.zero) { $0 + $1.preferredHeight(width: rowWidth) }
        return headerHeight + hintHeight + min(maximumListHeight, contentHeight)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        for view in [status, hint, previous, next, scroll] { addSubview(view) }
        status.font = .systemFont(ofSize: 13, weight: .medium)
        hint.font = .systemFont(ofSize: 12)
        hint.stringValue = Localization.text("candidate.selectHint")
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func isCurrentCandidateButton(_ button: NSButton, candidateIndex: Int) -> Bool {
        !isHidden && rows.contains { $0 === button && $0.candidateIndex == candidateIndex }
    }

    func update(page: CandidatePage, numbers: [Int: String], fontSize: CGFloat, generation: UInt = 0, compact: Bool = false,
                visibleRows: Config.CandidateVisibleRows.Value = .seven) {
        isHidden = page.totalCount == 0
        guard page != self.page || numbers != self.numbers || fontSize != self.fontSize ||
                generation != self.generation || compact != self.compact || visibleRows != self.visibleRows else {
            return
        }
        let rebuild = page.items != self.page.items || numbers != self.numbers ||
            fontSize != self.fontSize || generation != self.generation || compact != self.compact
        revealSelection = page.position != self.page.position || rebuild || visibleRows != self.visibleRows
        self.generation = generation
        self.page = page
        self.numbers = numbers
        self.fontSize = fontSize
        self.compact = compact
        self.visibleRows = visibleRows
        status.isHidden = compact
        hint.isHidden = compact
        if rebuild { rebuildRows() }
        for (offset, button) in rows.enumerated() {
            button.selected = page.position == page.start + offset + 1
            button.state = button.selected ? .on : .off
            button.setAccessibilityValue(button.selected ? Localization.text("candidate.selected") : "")
        }
        updatePagingButtons()
        status.stringValue = String(format: Localization.text("candidate.position"),
                                    page.position.map(String.init) ?? "—", String(page.totalCount))
        needsLayout = true
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = page.items.map { item in
            let button = CandidateRowButton(item: item, number: numbers[item.index], fontSize: fontSize, compact: compact)
            button.activate = { [weak self, weak button] in
                guard let self, let button, self.isCurrentCandidateButton(button, candidateIndex: item.index) else {
                    return
                }
                self.onSelection?(item.index)
            }
            button.preview = { [weak self, weak button] hovered in
                guard let self, let button, self.isCurrentCandidateButton(button, candidateIndex: item.index) else {
                    return
                }
                self.onPreview?(item.index, button, hovered)
            }
            document.addSubview(button)
            return button
        }
    }

    private func updatePagingButtons() {
        // A queued page action keeps its original page, even if indices are reused.
        for button in [previous, next] {
            button.activate = nil
            button.removeFromSuperview()
        }
        previous = pageButton(titleKey: "candidate.previousPage", index: page.previousIndex)
        next = pageButton(titleKey: "candidate.nextPage", index: page.nextIndex)
        previous.isHidden = compact
        next.isHidden = compact
        addSubview(previous)
        addSubview(next)
    }

    private func pageButton(titleKey: String, index: Int?) -> CandidatePresentationButton {
        let button = CandidatePresentationButton()
        button.title = Localization.text(titleKey)
        button.isEnabled = index != nil
        button.activate = { [weak self, weak button] in
            guard let self, let button, let index, !self.isHidden, !button.isHidden,
                  self.previous === button || self.next === button else {
                return
            }
            self.onSelection?(index)
        }
        return button
    }

    func applyPalette(_ palette: CandidatePalette) {
        status.textColor = palette.secondaryText
        hint.textColor = palette.secondaryText
        (rows as [NSButton] + [previous, next]).forEach { $0.needsDisplay = true }
    }

    override func layout() {
        super.layout()
        let selectedRow = rows.first(where: \.selected)
        let selectedWasVisible = selectedRow.map { !$0.frame.isEmpty && scroll.documentVisibleRect.contains($0.frame) } ?? false
        let previousViewportHeight = scroll.contentSize.height
        let pageWidth: CGFloat = 62
        let controlsWidth = pageWidth * 2 + 8
        status.frame = NSRect(x: inset, y: bounds.height - headerHeight + 8,
                              width: max(1, bounds.width - inset * 2 - controlsWidth), height: 20)
        previous.frame = NSRect(x: bounds.width - inset - controlsWidth, y: bounds.height - headerHeight + 2,
                                width: pageWidth, height: 32)
        next.frame = NSRect(x: bounds.width - inset - pageWidth, y: previous.frame.minY,
                            width: pageWidth, height: 32)
        hint.frame = NSRect(x: inset + 4, y: 3, width: max(1, bounds.width - inset * 2), height: 20)
        let verticalInset: CGFloat = compact ? compactInset : hintHeight
        scroll.frame = NSRect(x: compact ? compactInset : inset, y: verticalInset,
                              width: max(1, bounds.width - (compact ? compactInset * 2 : inset * 2)),
                              height: max(0, bounds.height - (compact ? compactInset * 2 : headerHeight + hintHeight)))
        let rowHeight = compact ? compactRowHeight : nil
        var y: CGFloat = 0
        for button in rows {
            let height = rowHeight ?? button.preferredHeight(width: scroll.contentSize.width)
            button.frame = NSRect(x: 0, y: y, width: scroll.contentSize.width, height: height)
            y += height
        }
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: y)
        // Resizing may clip a row that was fully visible, but must not undo manual scrolling away from it.
        if revealSelection || (selectedWasVisible && scroll.contentSize.height < previousViewportHeight), let button = selectedRow {
            document.scrollToVisible(button.frame)
            revealSelection = false
        }
    }
}
