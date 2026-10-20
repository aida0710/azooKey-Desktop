import AppKit
import Core

@MainActor
private final class CandidateNavigationButton: NSButton {
    var activate: (() -> Void)?
    var preview: ((Bool) -> Void)?
    var selected = false
    override var acceptsFirstResponder: Bool { false }
    override func isAccessibilitySelected() -> Bool { selected }

    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(invoke)
        bezelStyle = .rounded
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { performClick(nil) }
    @objc private func invoke() { activate?() }
    override func mouseEntered(with event: NSEvent) { preview?(true) }
    override func mouseExited(with event: NSEvent) { preview?(false) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
}

@MainActor
private final class CandidateListDocument: NSView {
    override var isFlipped: Bool { true }
}

/// The list shows complete existing candidates, bounded to the nine number keys.
@MainActor
final class CandidateNavigationView: NSView {
    var onSelection: ((Int, Bool) -> Void)?
    var onExpansion: (() -> Void)?
    var onPreview: ((Int, NSButton, Bool) -> Void)?
    private let status = NSTextField(labelWithString: "")
    private let toggle = CandidateNavigationButton()
    private let previous = CandidateNavigationButton()
    private let next = CandidateNavigationButton()
    private let scroll = NSScrollView()
    private let document = CandidateListDocument()
    private var rows: [CandidateNavigationButton] = []
    private var page = CandidatePage(entries: [], selectionIndex: nil)
    private var numbers: [Int: String] = [:]
    private var fontSize: CGFloat = 18
    private var expanded = false
    // A large candidate set must not make the popup grow beyond a single screen.
    private let maximumListHeight: CGFloat = 240
    private let headerHeight: CGFloat = 36
    var preferredHeight: CGFloat {
        page.totalCount == 0 ? 0 : headerHeight +
            (expanded ? min(maximumListHeight, CGFloat(rows.count) * (fontSize + 12)) : 0)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        for view in [status, toggle, previous, next, scroll] { addSubview(view) }
        status.lineBreakMode = .byTruncatingTail
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        toggle.activate = { [weak self] in
            guard let self else {
                return
            }
            self.expanded.toggle()
            self.refreshHeader()
            self.needsLayout = true
            self.onExpansion?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func isCurrentCandidateButton(_ button: NSButton, candidateIndex: Int) -> Bool {
        expanded && zip(rows, page.items).contains { row, item in row === button && item.index == candidateIndex }
    }

    func update(page: CandidatePage, numbers: [Int: String], fontSize: CGFloat) {
        isHidden = page.totalCount == 0
        guard page != self.page || numbers != self.numbers || fontSize != self.fontSize else {
            return
        }
        let rebuild = page.items != self.page.items || numbers != self.numbers || fontSize != self.fontSize
        self.page = page
        if page.totalCount == 0 { expanded = false }
        self.numbers = numbers
        self.fontSize = fontSize
        if rebuild { rebuildRows() }
        for (offset, button) in rows.enumerated() {
            button.selected = page.position == page.start + offset + 1
            button.state = button.selected ? .on : .off
        }
        for (button, index) in [(previous, page.previousIndex), (next, page.nextIndex)] {
            button.isEnabled = index != nil
            button.activate = { [weak self] in
                guard let self, let index, self.expanded, self.page == page else {
                    return
                }
                self.onSelection?(index, false)
            }
        }
        refreshHeader()
        needsLayout = true
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = page.items.map { item in
            let button = CandidateNavigationButton()
            button.setButtonType(.pushOnPushOff)
            button.title = numbers[item.index].map { "\($0). \(item.text)" } ?? item.text
            button.font = .systemFont(ofSize: fontSize)
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = item.detailDescription
            button.setAccessibilityLabel([item.text, item.reading].filter { !$0.isEmpty }.joined(separator: " "))
            button.setAccessibilityHelp(item.detailDescription)
            button.activate = { [weak self, weak button] in
                guard let self, let button, self.expanded, self.rows.contains(button) else {
                    return
                }
                self.onSelection?(item.index, true)
            }
            button.preview = { [weak self, weak button] hovered in
                guard let self, let button, self.expanded, self.rows.contains(button) else {
                    return
                }
                self.onPreview?(item.index, button, hovered)
            }
            document.addSubview(button)
            return button
        }
    }

    private func refreshHeader() {
        status.stringValue = String(format: Localization.text("candidate.position"),
                                    page.position.map(String.init) ?? "—", String(page.totalCount))
        toggle.title = Localization.text(expanded ? "candidate.closeList" : "candidate.openList")
        previous.title = Localization.text("candidate.previousPage")
        next.title = Localization.text("candidate.nextPage")
        previous.isHidden = !expanded
        next.isHidden = !expanded
        scroll.isHidden = !expanded
    }

    override func layout() {
        super.layout()
        let buttonWidth: CGFloat = 58
        let visibleButtons = expanded ? 3 : 1
        status.frame = NSRect(x: 8, y: bounds.height - headerHeight + 8,
                              width: max(1, bounds.width - CGFloat(visibleButtons) * buttonWidth - 16), height: 24)
        for (offset, button) in (expanded ? [toggle, previous, next] : [toggle]).enumerated() {
            button.frame = NSRect(x: bounds.width - CGFloat(visibleButtons - offset) * buttonWidth,
                                  y: bounds.height - headerHeight, width: buttonWidth, height: headerHeight)
        }
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - headerHeight))
        let rowHeight = fontSize + 12
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: CGFloat(rows.count) * rowHeight)
        for (offset, button) in rows.enumerated() {
            button.frame = NSRect(x: 0, y: CGFloat(offset) * rowHeight, width: document.bounds.width, height: rowHeight)
        }
    }
}
