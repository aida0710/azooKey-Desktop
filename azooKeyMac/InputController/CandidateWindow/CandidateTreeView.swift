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
    var onLayoutChanged: (() -> Void)?
    private var tree = CandidateTree(entries: [])
    private var entries: [CandidateTree.Entry] = []
    private var candidatePage = CandidatePage(entries: [], selectionIndex: nil)
    private var selection = CandidateTreeSelection(tree: CandidateTree(entries: []), candidateIndex: nil)
    private let scrollView = NSScrollView()
    private let navigation = CandidateNavigationView(frame: .zero)
    private let canvas = TreeCanvas()
    private var nodeButtons: [Int: TreeButton] = [:]
    private var nodeFrames: [Int: NSRect] = [:]
    private var numberLabels: [Int: String] = [:]
    private var rebuilding = false
    private var displayedColumns: [[Int]] = []
    private var documentWidths: [CGFloat]?
    private var scores: [Int: Int] = [:]
    private var scorePresentations: [Int: CandidateScorePresentation] = [:]
    private var showsScores = Config.ShowRelativeScores().value
    private var announcedCandidate: Int?
    private var announcedNode: Int?
    private var textSize = Config.CandidateTextSize.Value.standard
    private var fontSize: CGFloat { MacCandidateMetrics.fontSize(textSize) }
    let definitions: WordDefinitionsModel
    private let definitionCard = WordDefinitionsSideView(frame: .zero)
    private var treeExpanded = false
    private var generation: UInt = 0
    private var enterConfirmsCandidate = false
    private var revealedTreeSelection: TreeViewportSelection?
    private struct TreeViewportSelection: Equatable {
        var candidateIndex: Int?
        var nodeID: Int?
        var generation: UInt
        var isEditing: Bool
    }
    // Long paths remain scrollable inside the small input window.
    private let maximumTreeHeight: CGFloat = 160
    var hasDocumentAlignment: Bool { documentWidths != nil }
    private var treePreferredSize = NSSize(width: 80, height: 26)
    private var showsTree: Bool { !tree.nodes.isEmpty && !enterConfirmsCandidate }
    private var candidateWidth: CGFloat { enterConfirmsCandidate ? navigation.preferredWidth : treePreferredSize.width }
    private var candidateHeight: CGFloat {
        enterConfirmsCandidate ? navigation.preferredHeight(width: candidateWidth) : min(maximumTreeHeight, treePreferredSize.height)
    }
    private var showsDefinition: Bool { enterConfirmsCandidate && definitionCard.hasDefinition }
    var preferredSize: NSSize {
        let width = candidateWidth + (showsDefinition ? MacCandidateMetrics.cardGap + MacCandidateMetrics.definitionWidth : 0)
        let height = max(candidateHeight, showsDefinition ? navigation.selectedRowTop + definitionCard.preferredHeight : 0)
        return NSSize(width: width, height: height)
    }

    init(frame: NSRect, definitions: WordDefinitionsModel) {
        self.definitions = definitions
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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAppearance),
                                                           name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        addSubview(scrollView)
        addSubview(navigation)
        addSubview(definitionCard)
        navigation.onSelection = { [weak self] index in self?.selectCandidate(index) }
        definitions.onChange = { [weak self] in self?.refreshDefinitionCard() }
        definitions.availability.onChange = { [weak self] in
            guard let self else {
                return
            }
            self.navigation.updateDefinitions(availableIndices: self.definitions.availability.availableCandidateIndices)
        }
        scrollView.isHidden = true
        scrollView.setAccessibilityIdentifier("candidate-segments")
        setAccessibilityLabel(Localization.text("candidate.proposal"))
        refreshAppearance()
    }

    override convenience init(frame: NSRect) { self.init(frame: frame, definitions: WordDefinitionsModel()) }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = min(bounds.width, candidateWidth)
        let height = min(bounds.height, candidateHeight)
        let candidateFrame = NSRect(x: 0, y: bounds.height - height, width: width, height: height)
        navigation.frame = candidateFrame
        navigation.layoutSubtreeIfNeeded()
        scrollView.frame = candidateFrame
        definitionCard.isHidden = !showsDefinition
        if showsDefinition {
            let cardHeight = min(bounds.height, definitionCard.preferredHeight)
            definitionCard.frame = NSRect(x: width + MacCandidateMetrics.cardGap,
                y: max(0, bounds.height - navigation.selectedRowTop - cardHeight),
                width: MacCandidateMetrics.definitionWidth, height: cardHeight)
        }
        updateVisibleControls()
    }

    override func draw(_ dirtyRect: NSRect) {
        CandidateTheme.palette(for: effectiveAppearance).background.setFill()
        let frame = NSRect(x: 0, y: max(0, bounds.height - candidateHeight),
                           width: min(bounds.width, candidateWidth), height: min(bounds.height, candidateHeight))
        NSBezierPath(roundedRect: frame, xRadius: MacCandidateMetrics.cornerRadius,
                     yRadius: MacCandidateMetrics.cornerRadius).fill()
    }

    @objc private func viewportChanged() { updateVisibleControls() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    @objc private func refreshAppearance() {
        needsDisplay = true
        canvas.needsDisplay = true
        nodeButtons.values.forEach { $0.needsDisplay = true }
        let palette = CandidateTheme.palette(for: effectiveAppearance)
        definitionCard.applyPalette(palette)
        navigation.applyPalette(palette)
    }

    func update(entries: [CandidateTree.Entry], selectionIndex: Int?, numbers: [Int: String] = [:],
                documentWidths: [CGFloat]? = nil, enterConfirmsCandidate: Bool = false) {
        let updatedTree = CandidateTree(entries: entries)
        let size = Config.CandidateTextSize().value
        let scoresVisible = Config.ShowRelativeScores().value
        let minimumColumnWidth = MacCandidateMetrics.fontSize(size) + 8
        let readableWidths = documentWidths?.allSatisfy { $0 >= minimumColumnWidth } == true ? documentWidths : nil
        let changed = updatedTree != tree || self.documentWidths != readableWidths || textSize != size || showsScores != scoresVisible
        let phaseChanged = self.enterConfirmsCandidate != enterConfirmsCandidate
        if updatedTree != tree || phaseChanged {
            generation &+= 1
            retireTreeControls()
        }
        if phaseChanged {
            treeExpanded = false
            revealedTreeSelection = nil
        }
        self.documentWidths = readableWidths
        textSize = size
        showsScores = scoresVisible
        self.entries = entries
        self.enterConfirmsCandidate = enterConfirmsCandidate
        setAccessibilityLabel(Localization.text(enterConfirmsCandidate ? "candidate.composition" : "candidate.proposal"))
        tree = updatedTree
        if entries.isEmpty {
            treeExpanded = false
        }
        numberLabels = numbers
        candidatePage = CandidatePage(entries: entries, selectionIndex: selectionIndex, pageStart: numbers.keys.min())
        selection.synchronize(tree: tree, candidateIndex: selectionIndex)
        if changed {
            rebuild()
        }
        refreshSelection()
    }

    @discardableResult
    func movePage(forward: Bool) -> Bool {
        guard enterConfirmsCandidate, !entries.isEmpty else {
            return false
        }
        if let index = forward ? candidatePage.nextIndex : candidatePage.previousIndex {
            selectCandidate(index)
        }
        return true
    }

    @discardableResult
    func navigate(_ direction: CandidateTreeSelection.Direction) -> Bool {
        if !treeExpanded && (direction == .up || direction == .down) {
            guard !entries.isEmpty else {
                return false
            }
            guard let position = entries.firstIndex(where: { $0.candidateIndex == selection.selectedCandidateIndex }) else {
                selectCandidate(direction == .up ? entries[entries.count - 1].candidateIndex : entries[0].candidateIndex)
                return true
            }
            let offset = direction == .up ? entries.count - 1 : 1
            selectCandidate(entries[(position + offset) % entries.count].candidateIndex)
            return true
        }
        if !treeExpanded && !tree.nodes.isEmpty {
            treeExpanded = true
            generation &+= 1
            retireTreeControls()
            refreshSelection()
            onLayoutChanged?()
        }
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

    private func selectCandidate(_ index: Int) {
        guard tree.paths[index] != nil else {
            return
        }
        selection.synchronize(tree: tree, candidateIndex: index)
        refreshSelection()
        // Selecting the already-highlighted composing candidate must still enter selection mode.
        onSelectionChanged?(index)
    }

    private func selectNode(_ nodeID: Int) {
        guard let index = selection.select(nodeID: nodeID, in: tree) else {
            return
        }
        refreshSelection()
        onSelectionChanged?(index)
    }

    private func rebuild() {
        rebuilding = true
        defer { rebuilding = false }
        nodeFrames.removeAll()
        var rows: [Int: CGFloat] = [:]
        displayedColumns = presentationColumns
        var widths: [Int: CGFloat] = [:]
        let aligned = documentWidths?.count == displayedColumns.count
        let rowHeight = TreeButton.preferredHeight(fontSize: fontSize)
        let scoreHeight = showsScores ? CandidateScoreBadge.lineHeight : 0
        let rowGap: CGFloat = 2 // Separate candidate actions even when the score line is hidden.
        let rowPitch: CGFloat = rowHeight + scoreHeight + rowGap
        for (depth, column) in displayedColumns.enumerated() {
            for (row, id) in column.enumerated() {
                rows[id] = CGFloat(row)
            }
            guard let chosen = column.first else { continue }
            let textWidth = (tree.nodes[chosen].token.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
            widths[depth] = aligned ? documentWidths?[depth] : max(CGFloat(fontSize) + 12, min(240, textWidth + 12))
        }
        var xPositions: [Int: CGFloat] = [:]
        var x: CGFloat = 12
        for depth in widths.keys.sorted() {
            xPositions[depth] = x
            x += (widths[depth] ?? rowHeight) + (aligned ? 0 : 12)
        }
        let rowCount = displayedColumns.map(\.count).max() ?? 0
        let contentSize = NSSize(width: max(60, x), height: max(26, CGFloat(rowCount) * rowPitch + 6))
        canvas.frame = NSRect(origin: .zero, size: contentSize)
        treePreferredSize = NSSize(width: aligned ? contentSize.width : min(640, contentSize.width),
                                  height: contentSize.height)
        canvas.edges = []
        for id in displayedColumns.flatMap({ $0 }) {
            let node = tree.nodes[id]
            let frame = NSRect(x: xPositions[node.depth] ?? 12, y: (rows[id] ?? 0) * rowPitch + 6,
                               width: widths[node.depth] ?? rowHeight, height: rowHeight)
            nodeFrames[node.id] = frame
        }
        for id in displayedColumns.flatMap({ $0 }) {
            let node = tree.nodes[id]
            guard let to = nodeFrames[id] else { continue }
            let from = node.parentID.flatMap { nodeFrames[$0] }
            canvas.edges.append(.init(nodeID: id, from: NSPoint(x: from?.maxX ?? 4, y: from?.midY ?? 18),
                                      to: NSPoint(x: to.minX, y: to.midY)))
        }
    }

    private var presentationColumns: [[Int]] {
        var columns = tree.compactColumns(candidateIndex: selection.selectedCandidateIndex)
        guard treeExpanded, let id = selection.focusedNodeID else {
            return columns
        }
        let node = tree.nodes[id]
        let siblings = node.parentID.map { tree.nodes[$0].children } ?? tree.roots
        columns[node.depth] = [id] + siblings.filter { $0 != id }
        return columns
    }

    private func retireTreeControls() {
        nodeButtons.values.forEach { $0.removeFromSuperview() }
        nodeButtons.removeAll()
    }

    private func updateVisibleControls() {
        guard !rebuilding else {
            return
        }
        guard showsTree else {
            retireTreeControls()
            setAccessibilitySelectedChildren(enterConfirmsCandidate ? navigation.selectedCandidateControls : [])
            return
        }
        let viewport = canvas.visibleRect.isEmpty ? NSRect(origin: .zero, size: preferredSize) : canvas.visibleRect
        // Keep one row around the viewport ready while scrolling, without allocating the whole tree.
        let visible = viewport.insetBy(dx: -16, dy: -64)
        for (id, button) in nodeButtons where nodeFrames[id]?.intersects(visible) != true {
            button.removeFromSuperview()
            nodeButtons.removeValue(forKey: id)
        }
        for (id, frame) in nodeFrames where frame.intersects(visible) && nodeButtons[id] == nil {
            let node = tree.nodes[id]
            let button = TreeButton(frame: frame)
            button.title = node.token.text
            button.font = .systemFont(ofSize: fontSize)
            button.reading = node.token.reading
            button.toolTip = node.token.reading.isEmpty ? node.token.text : "\(node.token.text)（\(node.token.reading)）"
            button.setAccessibilityLabel(button.toolTip)
            button.clicked = { [weak self, weak button] _ in
                guard let self, let button, self.nodeButtons[node.id] === button else {
                    return
                }
                self.selectNode(node.id)
            }
            canvas.addSubview(button)
            nodeButtons[id] = button
        }
        refreshControlAppearance()
    }

    private func refreshControlAppearance() {
        let path = Set(displayedColumns.compactMap(\.first))
        for (id, button) in nodeButtons {
            if let frame = nodeFrames[id] { button.frame = frame }
            let token = tree.nodes[id].token
            button.title = token.text
            button.font = .systemFont(ofSize: fontSize)
            button.toolTip = token.reading.isEmpty ? token.text : "\(token.text)（\(token.reading)）"
            button.setAccessibilityLabel(button.toolTip)
            if let presentation = scorePresentations[id] {
                button.toolTip! += "\n" + presentation.detailDescription
            }
            if let preview = tree.preview(at: id, preserving: selection.selectedCandidateIndex) {
                button.toolTip! += "\n" + preview.detailDescription
            }
            button.setAccessibilityHelp(Localization.text("candidate.select") + "\n" + (button.toolTip ?? ""))
            button.highlightedPath = path.contains(id)
            button.focusedNode = selection.focusedNodeID == id
            button.setAccessibilityValue(button.focusedNode ? Localization.text("candidate.focused") : "")
            button.documentAligned = documentWidths?.count == displayedColumns.count
            button.needsDisplay = true
        }
        let selectedButtons = displayedColumns.compactMap(\.first).compactMap { nodeButtons[$0] }
        setAccessibilitySelectedChildren((enterConfirmsCandidate ? navigation.selectedCandidateControls : []) + selectedButtons)
    }

    private func refreshSelection() {
        candidatePage = CandidatePage(entries: entries, selectionIndex: selection.selectedCandidateIndex,
                                      pageStart: numberLabels.keys.min())
        navigation.update(page: candidatePage, numbers: numberLabels, fontSize: fontSize, generation: generation)
        navigation.isHidden = !enterConfirmsCandidate || entries.isEmpty
        scrollView.isHidden = !showsTree
        updateDefinitions()
        needsLayout = true
        if displayedColumns != presentationColumns { rebuild() }
        scores = tree.relativeScores(candidateIndex: selection.selectedCandidateIndex)
        scorePresentations = showsScores ? Dictionary(uniqueKeysWithValues: nodeFrames.keys.map {
            ($0, CandidateScorePresentation(relativeScore: scores[$0]))
        }) : [:]
        canvas.scorePresentations = scorePresentations
        canvas.nodeFrames = nodeFrames
        canvas.selectedPath = Set(displayedColumns.compactMap(\.first))
        canvas.needsDisplay = true
        let viewportSelection = TreeViewportSelection(candidateIndex: selection.selectedCandidateIndex,
                                                      nodeID: selection.focusedNodeID, generation: generation, isEditing: treeExpanded)
        if showsTree, revealedTreeSelection != viewportSelection,
           let id = selection.focusedNodeID, let frame = nodeFrames[id] {
            canvas.scrollToVisible(frame.insetBy(dx: -16, dy: -16))
            revealedTreeSelection = viewportSelection
        } else if !showsTree {
            revealedTreeSelection = nil
        }
        updateVisibleControls()
        if announcedCandidate != selection.selectedCandidateIndex {
            announcedCandidate = selection.selectedCandidateIndex
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        } else if announcedNode != selection.focusedNodeID,
                  let id = selection.focusedNodeID, let button = nodeButtons[id] {
            NSAccessibility.post(element: button, notification: .valueChanged)
        }
        announcedNode = selection.focusedNodeID
    }

    private func updateDefinitions() {
        let targets: [WordDefinitionsModel.Target] = enterConfirmsCandidate ? candidatePage.items.map {
            .init(generation: generation, candidateIndex: $0.index, nodeID: 0, word: $0.text, reading: $0.reading)
        } : []
        definitions.availability.update(targets: targets)
        definitions.update(target: targets.first { $0.candidateIndex == selection.selectedCandidateIndex })
        navigation.updateDefinitions(availableIndices: definitions.availability.availableCandidateIndices)
        refreshDefinitionCard()
    }

    private func refreshDefinitionCard() {
        let previousSize = preferredSize
        definitionCard.update(word: definitions.target?.word, result: definitions.result, fontSize: fontSize)
        definitionCard.isHidden = !showsDefinition
        needsLayout = true
        needsDisplay = true
        if preferredSize != previousSize { onLayoutChanged?() }
    }
}
