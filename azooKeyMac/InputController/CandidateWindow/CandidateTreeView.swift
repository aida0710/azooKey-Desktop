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
    private(set) var preferredSize = NSSize(width: 480, height: 180)

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.documentView = canvas
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        addSubview(scrollView)
        setAccessibilityLabel("木構造の変換候補")
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(entries: [CandidateTree.Entry], selectionIndex: Int?, numbers: [Int: String] = [:]) {
        let updatedTree = CandidateTree(entries: entries)
        let changed = updatedTree != tree
        tree = updatedTree
        selection.synchronize(tree: tree, candidateIndex: selectionIndex)
        if changed || terminalButtons.contains(where: { $0.value.title != (numbers[$0.key] ?? "↵") }) {
            rebuild(numbers: numbers)
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

    private func rebuild(numbers: [Int: String]) {
        canvas.subviews.forEach { $0.removeFromSuperview() }
        nodeButtons.removeAll()
        terminalButtons.removeAll()
        var rows: [Int: CGFloat] = [:]
        var terminalRows: [Int: CGFloat] = [:]
        var nextRow: CGFloat = 0
        func position(_ id: Int) {
            let first = nextRow
            for index in tree.nodes[id].terminalCandidateIndices {
                terminalRows[index] = nextRow
                nextRow += 1
            }
            for child in tree.nodes[id].children { position(child) }
            rows[id] = (first + max(first, nextRow - 1)) / 2
        }
        tree.roots.forEach { position($0) }
        var widths: [Int: CGFloat] = [:]
        for node in tree.nodes {
            let textWidth = (node.token.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 18)]).width
            widths[node.depth] = max(widths[node.depth] ?? 80, min(220, textWidth + 26))
        }
        var xPositions: [Int: CGFloat] = [:]
        var x: CGFloat = 16
        for depth in widths.keys.sorted() {
            xPositions[depth] = x
            x += (widths[depth] ?? 80) + 68
        }
        let contentSize = NSSize(width: max(240, x), height: max(80, nextRow * 64 + 32))
        canvas.frame = NSRect(origin: .zero, size: contentSize)
        preferredSize = NSSize(width: min(760, contentSize.width), height: min(420, contentSize.height))
        canvas.edges = []
        for node in tree.nodes {
            let frame = NSRect(x: xPositions[node.depth] ?? 16, y: (rows[node.id] ?? 0) * 64 + 16,
                               width: widths[node.depth] ?? 80, height: 48)
            let button = TreeButton(frame: frame)
            button.title = node.token.text
            button.reading = node.token.reading
            button.toolTip = node.token.reading.isEmpty ? node.token.text : "\(node.token.text)（\(node.token.reading)）"
            button.setAccessibilityLabel(button.toolTip)
            button.clicked = { [weak self] doubleClick in self?.selectNode(node.id, submit: doubleClick) }
            canvas.addSubview(button)
            nodeButtons[node.id] = button
            for index in node.terminalCandidateIndices {
                let terminal = TreeButton(frame: NSRect(x: frame.maxX + 7, y: (terminalRows[index] ?? 0) * 64 + 26, width: 28, height: 28))
                terminal.title = numbers[index] ?? "↵"
                terminal.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
                terminal.toolTip = "候補 \(index + 1) を確定"
                terminal.setAccessibilityLabel(terminal.toolTip)
                terminal.clicked = { [weak self] _ in self?.submit(candidateIndex: index) }
                canvas.addSubview(terminal)
                terminalButtons[index] = terminal
            }
        }
        for node in tree.nodes {
            guard let parent = node.parentID, let from = nodeButtons[parent], let to = nodeButtons[node.id] else { continue }
            canvas.edges.append(.init(nodeID: node.id, from: NSPoint(x: from.frame.maxX, y: from.frame.midY), to: NSPoint(x: to.frame.minX, y: to.frame.midY)))
        }
    }

    private func refreshSelection() {
        let path = Set(selection.selectedCandidateIndex.flatMap { tree.paths[$0] } ?? [])
        for (id, button) in nodeButtons {
            button.highlightedPath = path.contains(id)
            button.focusedNode = selection.focusedNodeID == id
            button.needsDisplay = true
        }
        for (index, button) in terminalButtons {
            button.highlightedPath = selection.selectedCandidateIndex == index
            button.needsDisplay = true
        }
        canvas.selectedPath = path
        canvas.needsDisplay = true
        if let id = selection.focusedNodeID, let button = nodeButtons[id] {
            canvas.scrollToVisible(button.frame.insetBy(dx: -16, dy: -16))
        }
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
            (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            let path = NSBezierPath()
            path.lineWidth = selected ? 2.5 : 1
            path.move(to: edge.from)
            let middle = (edge.from.x + edge.to.x) / 2
            path.curve(to: edge.to, controlPoint1: NSPoint(x: middle, y: edge.from.y), controlPoint2: NSPoint(x: middle, y: edge.to.y))
            path.stroke()
        }
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
        font = .systemFont(ofSize: 18)
        target = self
        action = #selector(activate)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { clicked?(false) }
    override func mouseDown(with event: NSEvent) { clicked?(event.clickCount > 1) }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        (highlightedPath ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.controlBackgroundColor).setFill()
        shape.fill()
        (focusedNode ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        shape.lineWidth = focusedNode ? 2 : 0.5
        shape.stroke()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: NSRect(x: 6, y: reading.isEmpty ? (bounds.height - 23) / 2 : 19,
                                          width: bounds.width - 12, height: 25),
                                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        if !reading.isEmpty {
            (reading as NSString).draw(in: NSRect(x: 6, y: 5, width: bounds.width - 12, height: 14),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
        }
    }
}
