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
    private let scroll = NSScrollView()
    private let document = CandidateListDocument()
    private var rows: [CandidateRowButton] = []
    private var page = CandidatePage(entries: [], selectionIndex: nil)
    private var numbers: [Int: String] = [:]
    private var fontSize: CGFloat = 18
    private var generation: UInt = 0
    private var revealSelection = false
    // The list scrolls instead of hiding long candidates behind ellipses.
    private let statusHeight: CGFloat = 18
    private let inset: CGFloat = 3
    var selectedCandidateControls: [NSButton] { rows.filter(\.selected) }

    func preferredHeight(width: CGFloat) -> CGFloat {
        guard page.totalCount > 0 else {
            return 0
        }
        let rowWidth = max(1, width - inset * 2)
        let contentHeight = rows.reduce(CGFloat.zero) { $0 + $1.preferredHeight(width: rowWidth) }
        let visibleHeight = rows.prefix(MacCandidateMetrics.visibleRows).reduce(CGFloat.zero) {
            $0 + $1.preferredHeight(width: rowWidth)
        }
        return statusHeight + inset * 2 + min(visibleHeight, contentHeight)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        for view in [status, scroll] { addSubview(view) }
        status.font = CandidateNumberFont.make(size: 11, weight: .regular)
        status.alignment = .right
        status.setAccessibilityIdentifier("candidate-position")
        setAccessibilityIdentifier("candidate-list")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
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

    func update(page: CandidatePage, numbers: [Int: String], fontSize: CGFloat, generation: UInt = 0) {
        isHidden = page.totalCount == 0
        guard page != self.page || numbers != self.numbers || fontSize != self.fontSize || generation != self.generation else {
            return
        }
        let rebuild = page.items != self.page.items || numbers != self.numbers ||
            fontSize != self.fontSize || generation != self.generation
        revealSelection = page.position != self.page.position || rebuild
        self.generation = generation
        self.page = page
        self.numbers = numbers
        self.fontSize = fontSize
        if rebuild { rebuildRows() }
        for (offset, button) in rows.enumerated() {
            button.selected = page.position == page.start + offset + 1
            button.state = button.selected ? .on : .off
            button.setAccessibilityValue(button.selected ? Localization.text("candidate.selected") : "")
        }
        status.stringValue = "\(page.position.map(String.init) ?? "—")/\(page.totalCount)"
        needsLayout = true
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = page.items.map { item in
            let button = CandidateRowButton(item: item, number: numbers[item.index], fontSize: fontSize)
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

    var preferredWidth: CGFloat {
        min(MacCandidateMetrics.maximumListWidth,
            max(MacCandidateMetrics.minimumListWidth, (rows.map(\.preferredWidth).max() ?? 0) + inset * 2))
    }

    var selectedRowTop: CGFloat {
        let width = preferredWidth - inset * 2
        let preceding = rows.prefix(while: { !$0.selected }).reduce(CGFloat.zero) { $0 + $1.preferredHeight(width: width) }
        let rowHeight = rows.first(where: \.selected)?.preferredHeight(width: width) ?? 0
        let viewportHeight = preferredHeight(width: preferredWidth) - statusHeight - inset * 2
        // Match scrollToVisible when a keyboard selection moves below the viewport.
        let scrollOffset = max(scroll.documentVisibleRect.minY, preceding + rowHeight - viewportHeight)
        return inset + max(0, preceding - scrollOffset)
    }

    func updateDefinitions(availableIndices: Set<Int>) {
        rows.forEach { $0.hasDefinition = availableIndices.contains($0.candidateIndex) }
    }

    func applyPalette(_ palette: CandidatePalette) {
        status.textColor = palette.secondaryText
        rows.forEach { $0.needsDisplay = true }
    }

    override func layout() {
        super.layout()
        status.frame = NSRect(x: inset, y: inset, width: max(1, bounds.width - inset * 2), height: statusHeight)
        scroll.frame = NSRect(x: inset, y: statusHeight + inset, width: max(1, bounds.width - inset * 2),
                              height: max(0, bounds.height - statusHeight - inset * 2))
        var y: CGFloat = 0
        for button in rows {
            let height = button.preferredHeight(width: scroll.contentSize.width)
            button.frame = NSRect(x: 0, y: y, width: scroll.contentSize.width, height: height)
            y += height
        }
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: y)
        if revealSelection, let button = rows.first(where: \.selected) {
            document.scrollToVisible(button.frame)
            revealSelection = false
        }
    }
}
