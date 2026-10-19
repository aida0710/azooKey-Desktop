import AppKit
import Core

/// Candidate clicks must never change the document application's focus.
final class CandidateTreePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A projection of complete, real candidates. Rendering never emits input events.
@MainActor
final class CandidateTreeView: NSView {
    var onSelectionChanged: ((Int) -> Void)?
    var onCandidateSubmitted: ((Int) -> Void)?
    private var tree = CandidateTree(entries: [])
    private var selection = CandidateTreeSelection(tree: CandidateTree(entries: []), candidateIndex: nil)
    private let scrollView = NSScrollView()
    private let canvas = TreeCanvas()
    private var nodeButtons: [Int: TreeButton] = [:]
    private var terminalButtons: [Int: TreeButton] = [:]
    private var nodeFrames: [Int: NSRect] = [:]
    private var terminalFrames: [Int: NSRect] = [:]
    private var numberLabels: [Int: String] = [:]
    private var rebuilding = false
    private var displayedColumns: [[Int]] = []
    private var layoutShowsNumbers = false
    private(set) var preferredSize = NSSize(width: 80, height: 46)

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.documentView = canvas
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        addSubview(scrollView)
        setAccessibilityLabel("木構造の変換候補")
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        updateVisibleControls()
    }

    @objc private func viewportChanged() { updateVisibleControls() }

    func update(entries: [CandidateTree.Entry], selectionIndex: Int?, numbers: [Int: String] = [:]) {
        let updatedTree = CandidateTree(entries: entries)
        let changed = updatedTree != tree
        tree = updatedTree
        numberLabels = numbers
        selection.synchronize(tree: tree, candidateIndex: selectionIndex)
        if changed {
            rebuild()
        }
        refreshSelection()
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
        for (depth, column) in displayedColumns.enumerated() {
            for (row, id) in column.enumerated() {
                rows[id] = CGFloat(row)
                let textWidth = (tree.nodes[id].token.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
                widths[depth] = max(widths[depth] ?? 24, min(160, textWidth + 12))
            }
        }
        var xPositions: [Int: CGFloat] = [:]
        var x: CGFloat = 12
        for depth in widths.keys.sorted() {
            xPositions[depth] = x
            x += (widths[depth] ?? 24) + (layoutShowsNumbers ? 22 : 12)
        }
        let rowCount = displayedColumns.map(\.count).max() ?? 0
        let contentSize = NSSize(width: max(60, x), height: max(32, CGFloat(rowCount) * 30 + 6))
        canvas.frame = NSRect(origin: .zero, size: contentSize)
        preferredSize = NSSize(width: min(760, contentSize.width), height: contentSize.height)
        canvas.edges = []
        for id in displayedColumns.flatMap({ $0 }) {
            let node = tree.nodes[id]
            let frame = NSRect(x: xPositions[node.depth] ?? 12, y: (rows[id] ?? 0) * 30 + 6,
                               width: widths[node.depth] ?? 24, height: 24)
            nodeFrames[node.id] = frame
            for index in node.terminalCandidateIndices {
                terminalFrames[index] = NSRect(x: frame.maxX + 1, y: frame.minY + 2, width: 20, height: 20)
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
            button.reading = node.token.reading
            button.toolTip = node.token.reading.isEmpty ? node.token.text : "\(node.token.text)（\(node.token.reading)）"
            button.setAccessibilityLabel(button.toolTip)
            // The chosen word moves to the top row. Commit on the first click
            // so a second click cannot hit a different word at the old position.
            button.clicked = { [weak self] _ in self?.selectNode(node.id, submit: true) }
            canvas.addSubview(button)
            nodeButtons[id] = button
        }
        for (index, frame) in terminalFrames where frame.intersects(visible) && terminalButtons[index] == nil && visibleTerminals.contains(index) {
            let terminal = TreeButton(frame: frame)
            terminal.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            terminal.toolTip = "候補 \(index + 1) を確定"
            terminal.setAccessibilityLabel(terminal.toolTip)
            terminal.clicked = { [weak self] _ in self?.submit(candidateIndex: index) }
            canvas.addSubview(terminal)
            terminalButtons[index] = terminal
        }
        let path = Set(displayedColumns.compactMap(\.first))
        for (id, button) in nodeButtons {
            if let frame = nodeFrames[id] { button.frame = frame }
            let token = tree.nodes[id].token
            button.title = token.text
            button.toolTip = token.reading.isEmpty ? token.text : "\(token.text)（\(token.reading)）"
            button.setAccessibilityLabel(button.toolTip)
            button.highlightedPath = path.contains(id)
            button.focusedNode = selection.focusedNodeID == id
            button.needsDisplay = true
        }
        for (index, button) in terminalButtons {
            if let frame = terminalFrames[index] { button.frame = frame }
            let title = numberLabels[index] ?? "↵"
            if button.title != title { button.title = title }
            button.highlightedPath = selection.selectedCandidateIndex == index
            button.needsDisplay = true
        }
    }

    private func refreshSelection() {
        if displayedColumns != tree.compactColumns(candidateIndex: selection.selectedCandidateIndex) || layoutShowsNumbers != !numberLabels.isEmpty { rebuild() }
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
    }
}

@MainActor
private final class TreeCanvas: NSView {
    struct Edge { var nodeID: Int; var from: NSPoint; var to: NSPoint }
    var edges: [Edge] = []
    var selectedPath: Set<Int> = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        for edge in edges {
            let selected = selectedPath.contains(edge.nodeID)
            (selected ? NSColor(red: 0.25, green: 0.45, blue: 0.8, alpha: 1) : NSColor.gray.withAlphaComponent(0.5)).setStroke()
            let path = NSBezierPath()
            path.lineWidth = selected ? 2 : 0.75
            path.move(to: edge.from)
            let middle = (edge.from.x + edge.to.x) / 2
            path.curve(to: edge.to, controlPoint1: NSPoint(x: middle, y: edge.from.y), controlPoint2: NSPoint(x: middle, y: edge.to.y))
            path.stroke()
        }
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 15, width: 6, height: 6)).fill()
    }
}

@MainActor
private final class TreeButton: NSButton {
    var clicked: ((Bool) -> Void)?
    var reading = ""
    var highlightedPath = false
    var focusedNode = false
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        font = .systemFont(ofSize: 13)
        target = self
        action = #selector(activate)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { clicked?(false) }
    override func mouseDown(with event: NSEvent) { clicked?(event.clickCount > 1) }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        (highlightedPath ? NSColor(red: 0.25, green: 0.45, blue: 0.8, alpha: 1) : NSColor.controlBackgroundColor.withAlphaComponent(0.5)).setFill()
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
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let textFont = font ?? NSFont.systemFont(ofSize: 13)
        let height = textFont.ascender - textFont.descender + 2
        (title as NSString).draw(in: NSRect(x: 4, y: (bounds.height - height) / 2, width: bounds.width - 8, height: height),
                                withAttributes: [.font: textFont, .foregroundColor: highlightedPath ? NSColor.white : NSColor.labelColor,
                                                 .paragraphStyle: style])
    }
}
