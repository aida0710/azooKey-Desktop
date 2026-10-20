import AppKit
import Core

/// Candidate clicks must never change the document application's focus.
final class CandidateTreePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// IMK character indices are UTF-16 offsets relative to the inline session.
/// Reject wrapped, vertical, missing, or non-increasing client rectangles.
struct CandidateDocumentGeometry {
    let anchor: CGPoint
    let widths: [CGFloat]

    init?(words: [String], preedit: String, rectAtOffset: (Int) -> NSRect) {
        guard !words.isEmpty, words.count <= 64, words.joined() == preedit else {
            return nil
        }
        var offsets = [0]
        for word in words { offsets.append(offsets.last! + word.utf16.count) }
        let rects = offsets.map(rectAtOffset)
        guard let first = rects.first, first.height > 0,
              rects.allSatisfy({ $0.minX.isFinite && $0.minY.isFinite && abs($0.minY - first.minY) <= 1 && abs($0.height - first.height) <= 1 }) else { return nil }
        let widths = zip(rects, rects.dropFirst()).map { $1.minX - $0.minX }
        guard widths.allSatisfy({ $0 >= 6 && $0 < 4000 }) else {
            return nil
        }
        self.anchor = CGPoint(x: first.minX - 12, y: first.minY)
        self.widths = widths
    }
}

/// A projection of complete, real candidates. Rendering never emits input events.
@MainActor
final class CandidateTreeView: NSView {
    var onSelectionChanged: ((Int) -> Void)?
    var onCandidateSubmitted: ((Int) -> Void)?
    private var tree = CandidateTree(entries: [])
    private var selection = CandidateTreeSelection(tree: CandidateTree(entries: []), candidateIndex: nil)
    private let scrollView = NSScrollView()
    private let details = CandidateDetailView(frame: .zero)
    private let canvas = TreeCanvas()
    private var nodeButtons: [Int: TreeButton] = [:]
    private var terminalButtons: [Int: TreeButton] = [:]
    private var nodeFrames: [Int: NSRect] = [:]
    private var terminalFrames: [Int: NSRect] = [:]
    private var numberLabels: [Int: String] = [:]
    private var rebuilding = false
    private var displayedColumns: [[Int]] = []
    private var layoutShowsNumbers = false
    private var documentWidths: [CGFloat]?
    private var scores: [Int: Int] = [:]
    private var announcedCandidate: Int?
    private var announcedNode: Int?
    private var textSize = Config.CandidateTextSize.Value.standard
    // Detail text needs a readable line even when the selected word is one character.
    private let minimumDetailWidth: CGFloat = 320
    private var detailHeight: CGFloat { textSize == .large ? CandidateDetailView.maximumHeight : 112 }
    private(set) var preferredSize = NSSize(width: 80, height: 46)

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.documentView = canvas
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.frame = bounds
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        addSubview(scrollView)
        addSubview(details)
        setAccessibilityLabel("木構造の変換候補")
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let height = min(detailHeight, bounds.height)
        details.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        scrollView.frame = NSRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
        updateVisibleControls()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    @objc private func viewportChanged() { updateVisibleControls() }

    func update(entries: [CandidateTree.Entry], selectionIndex: Int?, numbers: [Int: String] = [:],
                documentWidths: [CGFloat]? = nil) {
        let updatedTree = CandidateTree(entries: entries)
        let size = Config.CandidateTextSize().value
        let minimumColumnWidth = CGFloat(size.pointSize) + 8
        let readableWidths = documentWidths?.allSatisfy { $0 >= minimumColumnWidth } == true ? documentWidths : nil
        let changed = updatedTree != tree || self.documentWidths != readableWidths || textSize != size
        if updatedTree != tree {
            nodeButtons.values.forEach { $0.removeFromSuperview() }
            terminalButtons.values.forEach { $0.removeFromSuperview() }
            nodeButtons.removeAll()
            terminalButtons.removeAll()
        }
        self.documentWidths = readableWidths
        textSize = size
        tree = updatedTree
        numberLabels = numbers
        selection.synchronize(tree: tree, candidateIndex: selectionIndex)
        if changed {
            rebuild()
        }
        refreshSelection()
    }

    @discardableResult
    func scrollDetails(forward: Bool) -> Bool {
        guard !tree.nodes.isEmpty else {
            return false
        }
        details.scrollPage(forward: forward)
        return true
    }

    @discardableResult
    func navigate(_ direction: CandidateTreeSelection.Direction) -> Bool {
        let oldIndex = selection.selectedCandidateIndex
        guard let index = selection.move(direction, in: tree) else {
            return false
        }
        refreshSelection()
        if oldIndex != index { onSelectionChanged?(index) }
        return true
    }

    func submit(candidateIndex: Int) {
        guard tree.paths[candidateIndex] != nil else {
            return
        }
        selection.synchronize(tree: tree, candidateIndex: candidateIndex)
        refreshSelection()
        // Submission carries its index so a click can't commit an old selection.
        onCandidateSubmitted?(candidateIndex)
    }

    private func selectNode(_ nodeID: Int, submit: Bool) {
        let oldIndex = selection.selectedCandidateIndex
        guard let index = selection.select(nodeID: nodeID, in: tree) else {
            return
        }
        refreshSelection()
        if submit {
            onCandidateSubmitted?(index)
        } else if oldIndex != index {
            onSelectionChanged?(index)
        }
    }

    private func rebuild() {
        rebuilding = true
        defer { rebuilding = false }
        nodeFrames.removeAll()
        terminalFrames.removeAll()
        var rows: [Int: CGFloat] = [:]
        displayedColumns = tree.compactColumns(candidateIndex: selection.selectedCandidateIndex)
        layoutShowsNumbers = !numberLabels.isEmpty
        var widths: [Int: CGFloat] = [:]
        let aligned = documentWidths?.count == displayedColumns.count
        let rowHeight = CGFloat(textSize.pointSize) + 14
        let rowPitch: CGFloat = rowHeight + (aligned && layoutShowsNumbers ? 40 : 20)
        for (depth, column) in displayedColumns.enumerated() {
            for (row, id) in column.enumerated() {
                rows[id] = CGFloat(row)
            }
            guard let chosen = column.first else { continue }
            let textWidth = (tree.nodes[chosen].token.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: textSize.pointSize)]).width
            widths[depth] = aligned ? documentWidths?[depth] : max(CGFloat(textSize.pointSize) + 12, min(240, textWidth + 12))
        }
        var xPositions: [Int: CGFloat] = [:]
        var x: CGFloat = 12
        for depth in widths.keys.sorted() {
            xPositions[depth] = x
            x += (widths[depth] ?? rowHeight) + (aligned ? 0 : (layoutShowsNumbers ? rowHeight + 2 : 12))
        }
        let rowCount = displayedColumns.map(\.count).max() ?? 0
        let contentSize = NSSize(width: max(60, x), height: max(44, CGFloat(rowCount) * rowPitch + 6))
        canvas.frame = NSRect(origin: .zero, size: contentSize)
        preferredSize = NSSize(width: max(minimumDetailWidth, aligned ? contentSize.width : min(760, contentSize.width)),
                               height: contentSize.height + detailHeight)
        canvas.edges = []
        for id in displayedColumns.flatMap({ $0 }) {
            let node = tree.nodes[id]
            let frame = NSRect(x: xPositions[node.depth] ?? 12, y: (rows[id] ?? 0) * rowPitch + 6,
                               width: widths[node.depth] ?? rowHeight, height: rowHeight)
            nodeFrames[node.id] = frame
            for index in node.terminalCandidateIndices {
                terminalFrames[index] = aligned
                    ? NSRect(x: frame.maxX - rowHeight, y: frame.maxY + 16, width: rowHeight, height: 24)
                    : NSRect(x: frame.maxX + 1, y: frame.minY, width: rowHeight, height: rowHeight)
            }
        }
        for id in displayedColumns.flatMap({ $0 }) {
            let node = tree.nodes[id]
            guard let to = nodeFrames[id] else { continue }
            let from = node.parentID.flatMap { nodeFrames[$0] }
            canvas.edges.append(.init(nodeID: id, from: NSPoint(x: from?.maxX ?? 4, y: from?.midY ?? 18),
                                      to: NSPoint(x: to.minX, y: to.midY)))
        }
    }

    private var numberedTerminals: Set<Int> {
        Set(displayedColumns.flatMap { $0 }.compactMap { id -> Int? in
            let terminals = tree.nodes[id].terminalCandidateIndices.filter { numberLabels[$0] != nil }
            if let index = selection.selectedCandidateIndex, terminals.contains(index) {
                return index
            }
            return terminals.first
        })
    }

    private func updateVisibleControls() {
        guard !rebuilding else {
            return
        }
        let viewport = canvas.visibleRect.isEmpty ? NSRect(origin: .zero, size: preferredSize) : canvas.visibleRect
        // Keep one row around the viewport ready while scrolling, without allocating the whole tree.
        let visible = viewport.insetBy(dx: -16, dy: -64)
        let visibleTerminals = numberedTerminals
        for (id, button) in nodeButtons where nodeFrames[id]?.intersects(visible) != true {
            button.removeFromSuperview()
            nodeButtons.removeValue(forKey: id)
        }
        for (index, button) in terminalButtons where terminalFrames[index]?.intersects(visible) != true || !visibleTerminals.contains(index) {
            button.removeFromSuperview()
            terminalButtons.removeValue(forKey: index)
        }
        for (id, frame) in nodeFrames where frame.intersects(visible) && nodeButtons[id] == nil {
            let node = tree.nodes[id]
            let button = TreeButton(frame: frame)
            button.title = node.token.text
            button.font = .systemFont(ofSize: textSize.pointSize)
            button.reading = node.token.reading
            button.toolTip = node.token.reading.isEmpty ? node.token.text : "\(node.token.text)（\(node.token.reading)）"
            button.setAccessibilityLabel(button.toolTip)
            // The chosen word moves to the top row. Commit on the first click
            // so a second click cannot hit a different word at the old position.
            button.clicked = { [weak self, weak button] _ in
                guard let self, let button, self.nodeButtons[node.id] === button else {
                    return
                }
                self.selectNode(node.id, submit: true)
            }
            button.hovered = { [weak self] in self?.showDetails(nodeID: node.id) }
            canvas.addSubview(button)
            nodeButtons[id] = button
        }
        for (index, frame) in terminalFrames where frame.intersects(visible) && terminalButtons[index] == nil && visibleTerminals.contains(index) {
            let terminal = TreeButton(frame: frame)
            terminal.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            terminal.toolTip = "候補 \(index + 1) を確定"
            terminal.setAccessibilityLabel(terminal.toolTip)
            terminal.clicked = { [weak self, weak terminal] _ in
                guard let self, let terminal, self.terminalButtons[index] === terminal else {
                    return
                }
                self.submit(candidateIndex: index)
            }
            canvas.addSubview(terminal)
            terminalButtons[index] = terminal
        }
        refreshControlAppearance()
    }

    private func refreshControlAppearance() {
        let path = Set(displayedColumns.compactMap(\.first))
        for (id, button) in nodeButtons {
            if let frame = nodeFrames[id] { button.frame = frame }
            let token = tree.nodes[id].token
            button.title = token.text
            button.font = .systemFont(ofSize: textSize.pointSize)
            button.toolTip = token.reading.isEmpty ? token.text : "\(token.text)（\(token.reading)）"
            button.setAccessibilityLabel(button.toolTip)
            button.relativeScore = scores[id]
            button.toolTip! += scores[id].map { "\n相対スコア \($0)（取得候補内の評価。正解の確率ではありません）" } ?? "\n比較可能なスコアなし"
            if let preview = tree.preview(at: id, preserving: selection.selectedCandidateIndex) {
                button.toolTip! += "\n" + preview.detailDescription
            }
            button.setAccessibilityHelp(button.toolTip)
            button.highlightedPath = path.contains(id)
            button.focusedNode = selection.focusedNodeID == id
            button.setAccessibilityValue(button.focusedNode ? Localization.text("candidate.focused") : "")
            button.documentAligned = documentWidths?.count == displayedColumns.count
            button.needsDisplay = true
        }
        let selectedButtons = displayedColumns.compactMap(\.first).compactMap { nodeButtons[$0] }
        setAccessibilitySelectedChildren(selectedButtons)
        for (index, button) in terminalButtons {
            if let frame = terminalFrames[index] { button.frame = frame }
            let title = numberLabels[index] ?? "↵"
            if button.title != title { button.title = title }
            button.highlightedPath = selection.selectedCandidateIndex == index
            button.font = .monospacedSystemFont(ofSize: max(14, textSize.pointSize - 4), weight: .medium)
            button.compactBadge = documentWidths?.count == displayedColumns.count
            button.needsDisplay = true
        }
    }

    private func refreshSelection() {
        if displayedColumns != tree.compactColumns(candidateIndex: selection.selectedCandidateIndex) || layoutShowsNumbers != !numberLabels.isEmpty { rebuild() }
        scores = tree.relativeScores(candidateIndex: selection.selectedCandidateIndex)
        canvas.scores = scores
        canvas.nodeFrames = nodeFrames
        canvas.selectedPath = Set(displayedColumns.compactMap(\.first))
        canvas.needsDisplay = true
        if let id = selection.focusedNodeID, let frame = nodeFrames[id] {
            var reveal = frame
            if let index = selection.selectedCandidateIndex,
               numberLabels[index] != nil, tree.nodes[id].terminalCandidateIndices.contains(index), let terminal = terminalFrames[index] {
                reveal = reveal.union(terminal)
            }
            canvas.scrollToVisible(reveal.insetBy(dx: -16, dy: -16))
        }
        updateVisibleControls()
        showDetails(nodeID: selection.focusedNodeID ?? displayedColumns.first?.first)
        if announcedCandidate != selection.selectedCandidateIndex {
            announcedCandidate = selection.selectedCandidateIndex
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        } else if announcedNode != selection.focusedNodeID,
                  let id = selection.focusedNodeID, let button = nodeButtons[id] {
            NSAccessibility.post(element: button, notification: .valueChanged)
        }
        announcedNode = selection.focusedNodeID
    }

    private func showDetails(nodeID: Int?) {
        guard let nodeID, tree.nodes.indices.contains(nodeID) else {
            details.update(text: "", fontSize: CGFloat(textSize.pointSize))
            return
        }
        let token = tree.nodes[nodeID].token
        let word = token.reading.isEmpty ? token.text : "\(token.text)\n\(token.reading)"
        let preview = tree.preview(at: nodeID, preserving: selection.selectedCandidateIndex)?.detailDescription
        let description = [word, preview, Localization.text("candidate.detailKeys")].compactMap { $0 }.joined(separator: "\n")
        details.update(text: description, fontSize: CGFloat(textSize.pointSize))
    }
}

@MainActor
private final class TreeCanvas: NSView {
    struct Edge { var nodeID: Int; var from: NSPoint; var to: NSPoint }
    var edges: [Edge] = []
    var selectedPath: Set<Int> = []
    var scores: [Int: Int] = [:]
    var nodeFrames: [Int: NSRect] = [:]
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        for edge in edges {
            let selected = selectedPath.contains(edge.nodeID)
            (selected ? TreeButton.scoreColor(scores[edge.nodeID]) : NSColor.gray.withAlphaComponent(0.5)).setStroke()
            let path = NSBezierPath()
            path.lineWidth = selected ? 2 : 0.75
            path.move(to: edge.from)
            let middle = (edge.from.x + edge.to.x) / 2
            path.curve(to: edge.to, controlPoint1: NSPoint(x: middle, y: edge.from.y), controlPoint2: NSPoint(x: middle, y: edge.to.y))
            path.stroke()
        }
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 15, width: 6, height: 6)).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        for (id, frame) in nodeFrames {
            let label = scores[id].map(String.init) ?? "—"
            (label as NSString).draw(in: NSRect(x: frame.minX, y: frame.maxY, width: frame.width, height: 13),
                                    withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                                                     .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
        }
    }
}

@MainActor
private final class TreeButton: NSButton {
    var clicked: ((Bool) -> Void)?
    var hovered: (() -> Void)?
    private var tracking: NSTrackingArea?
    var reading = ""
    var highlightedPath = false
    var focusedNode = false
    var documentAligned = false
    var relativeScore: Int?
    var compactBadge = false
    override var acceptsFirstResponder: Bool { false }
    override func isAccessibilitySelected() -> Bool { highlightedPath }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        font = .systemFont(ofSize: 12)
        target = self
        action = #selector(activate)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { clicked?(false) }
    override func mouseDown(with event: NSEvent) { clicked?(event.clickCount > 1) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered?() }
    static func scoreColor(_ score: Int?) -> NSColor {
        if let score, score < 75 {
            return NSColor(red: 0.83, green: 0.39, blue: 0.06, alpha: 1)
        }
        return NSColor(red: 0.25, green: 0.45, blue: 0.8, alpha: 1)
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        (highlightedPath ? Self.scoreColor(relativeScore) : NSColor.controlBackgroundColor.withAlphaComponent(1)).setFill()
        shape.fill()
        if focusedNode {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let underline = NSBezierPath()
            underline.lineWidth = 1.5
            underline.move(to: NSPoint(x: 6, y: bounds.height - 4))
            underline.line(to: NSPoint(x: bounds.width - 6, y: bounds.height - 4))
            underline.stroke()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = documentAligned ? .left : .center
        style.lineBreakMode = .byTruncatingTail
        let inset: CGFloat = compactBadge ? 1 : (documentAligned ? 2 : 4)
        let textFont = font ?? NSFont.systemFont(ofSize: 18)
        let height = textFont.ascender - textFont.descender + 2
        (title as NSString).draw(in: NSRect(x: inset, y: (bounds.height - height) / 2, width: bounds.width - inset * 2, height: height),
                                withAttributes: [.font: textFont, .foregroundColor: highlightedPath ? NSColor.white : NSColor.labelColor,
                                                 .paragraphStyle: style])
    }
}
