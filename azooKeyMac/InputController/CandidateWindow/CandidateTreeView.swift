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
    private enum DetailTarget {
        case node(Int)
        case candidate(Int)
    }

    var onSelectionChanged: ((Int) -> Void)?
    var onCandidateSubmitted: ((Int) -> Void)?
    var onLayoutChanged: (() -> Void)?
    private var tree = CandidateTree(entries: [])
    private var entries: [CandidateTree.Entry] = []
    private var candidatePage = CandidatePage(entries: [], selectionIndex: nil)
    private var selection = CandidateTreeSelection(tree: CandidateTree(entries: []), candidateIndex: nil)
    private let scrollView = NSScrollView()
    private let details = CandidateDetailView(frame: .zero)
    private let composition = CandidateCompositionView(frame: .zero)
    private let navigation = CandidateNavigationView(frame: .zero)
    private let actions = CandidateActionsView(frame: .zero)
    private let canvas = TreeCanvas()
    private var nodeButtons: [Int: TreeButton] = [:]
    private var terminalButtons: [Int: TreeButton] = [:]
    private var hoveredDetail: DetailTarget?
    private weak var hoveredControl: NSButton?
    private var nodeFrames: [Int: NSRect] = [:]
    private var terminalFrames: [Int: NSRect] = [:]
    private var numberLabels: [Int: String] = [:]
    private var rebuilding = false
    private var displayedColumns: [[Int]] = []
    private var layoutShowsNumbers = false
    private var documentWidths: [CGFloat]?
    private var scores: [Int: Int] = [:]
    private var scorePresentations: [Int: CandidateScorePresentation] = [:]
    private var showsScores = Config.ShowRelativeScores().value
    private var announcedCandidate: Int?
    private var announcedNode: Int?
    private var textSize = Config.CandidateTextSize.Value.standard
    private var treeExpanded = false
    private var detailsExpanded = false
    private var generation: UInt = 0
    private var enterConfirmsCandidate = false
    // Optional branches stay scrollable without displacing the primary candidate list.
    private let maximumTreeHeight: CGFloat = 220
    // Detail text needs a readable line even when the selected word is one character.
    private let minimumDetailWidth = CandidateDetailView.minimumWidth
    var hasDocumentAlignment: Bool { documentWidths != nil }
    private var treePreferredSize = NSSize(width: 80, height: 46)
    var preferredSize: NSSize {
        let width = treeExpanded ? treePreferredSize.width : minimumDetailWidth
        let height = composition.preferredHeight(width: width) + navigation.preferredHeight(width: width) +
            actions.preferredHeight(width: width) + (treeExpanded ? min(maximumTreeHeight, treePreferredSize.height) : 0) +
            (detailsExpanded ? CandidateDetailView.maximumHeight : 0)
        return NSSize(width: width, height: height)
    }

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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAppearance),
                                                           name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        addSubview(scrollView)
        addSubview(details)
        addSubview(composition)
        addSubview(navigation)
        addSubview(actions)
        navigation.onSelection = { [weak self] index in
            self?.selectCandidate(index)
        }
        navigation.onPreview = { [weak self] index, button, hovered in
            self?.changeDetailHover(.candidate(index), control: button, hovered: hovered)
        }
        actions.onTreeToggle = { [weak self] in
            guard let self else {
                return
            }
            self.treeExpanded.toggle()
            self.refreshSelection()
            self.onLayoutChanged?()
        }
        actions.onDetailsToggle = { [weak self] in
            guard let self else {
                return
            }
            self.detailsExpanded.toggle()
            self.refreshSelection()
            self.onLayoutChanged?()
        }
        actions.onSubmit = { [weak self] index in self?.submit(candidateIndex: index) }
        scrollView.isHidden = true
        details.isHidden = true
        details.setAccessibilityIdentifier("candidate-details")
        scrollView.setAccessibilityIdentifier("candidate-segments")
        setAccessibilityLabel(Localization.text("candidate.proposal"))
        refreshAppearance()
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let actionHeight = min(actions.preferredHeight(width: bounds.width), bounds.height)
        let available = max(0, bounds.height - actionHeight)
        let compositionHeight = composition.preferredHeight(width: bounds.width)
        let navigationHeight = navigation.preferredHeight(width: bounds.width)
        let treeHeight = treeExpanded ? min(maximumTreeHeight, treePreferredSize.height) : 0
        let detailHeight = detailsExpanded ? CandidateDetailView.maximumHeight : 0
        let scale = min(1, available / max(1, compositionHeight + navigationHeight + treeHeight + detailHeight))
        var top = bounds.height
        for (view, height) in [(composition as NSView, compositionHeight * scale),
                               (navigation, navigationHeight * scale),
                               (scrollView, treeHeight * scale), (details, detailHeight * scale)] {
            top -= height
            view.frame = NSRect(x: 0, y: top, width: bounds.width, height: height)
        }
        actions.frame = NSRect(x: 0, y: 0, width: bounds.width, height: actionHeight)
        updateVisibleControls()
    }

    override func draw(_ dirtyRect: NSRect) {
        CandidateTheme.palette(for: effectiveAppearance).background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
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
        terminalButtons.values.forEach { $0.needsDisplay = true }
        let palette = CandidateTheme.palette(for: effectiveAppearance)
        details.applyPalette(palette)
        composition.applyPalette(palette)
        navigation.applyPalette(palette)
        actions.subviews.forEach { $0.needsDisplay = true }
    }

    func update(entries: [CandidateTree.Entry], selectionIndex: Int?, numbers: [Int: String] = [:],
                documentWidths: [CGFloat]? = nil, enterConfirmsCandidate: Bool = false) {
        let updatedTree = CandidateTree(entries: entries)
        let size = Config.CandidateTextSize().value
        let scoresVisible = Config.ShowRelativeScores().value
        let minimumColumnWidth = CGFloat(size.pointSize) + (numbers.isEmpty ? 8 : 14)
        let readableWidths = documentWidths?.allSatisfy { $0 >= minimumColumnWidth } == true ? documentWidths : nil
        let changed = updatedTree != tree || self.documentWidths != readableWidths || textSize != size || showsScores != scoresVisible
        if updatedTree != tree || self.enterConfirmsCandidate != enterConfirmsCandidate {
            generation &+= 1
            nodeButtons.values.forEach { $0.removeFromSuperview() }
            terminalButtons.values.forEach { $0.removeFromSuperview() }
            nodeButtons.removeAll()
            terminalButtons.removeAll()
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
            detailsExpanded = false
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
    func scrollDetails(forward: Bool) -> Bool {
        guard !tree.nodes.isEmpty else {
            return false
        }
        if detailsExpanded {
            details.scrollPage(forward: forward)
        } else {
            composition.scrollPage(forward: forward)
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
        terminalFrames.removeAll()
        var rows: [Int: CGFloat] = [:]
        displayedColumns = tree.compactColumns(candidateIndex: selection.selectedCandidateIndex)
        layoutShowsNumbers = !numberLabels.isEmpty
        var widths: [Int: CGFloat] = [:]
        let aligned = documentWidths?.count == displayedColumns.count
        let rowHeight = CGFloat(textSize.pointSize) + 14
        let scoreHeight = showsScores ? CandidateScoreBadge.lineHeight : 0
        let rowGap: CGFloat = 4 // Separate candidate actions even when the score line is hidden.
        let rowPitch: CGFloat = rowHeight + scoreHeight + rowGap + (aligned && layoutShowsNumbers ? rowHeight : 0)
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
        treePreferredSize = NSSize(width: max(minimumDetailWidth, aligned ? contentSize.width : min(760, contentSize.width)),
                                  height: contentSize.height)
        canvas.edges = []
        for id in displayedColumns.flatMap({ $0 }) {
            let node = tree.nodes[id]
            let frame = NSRect(x: xPositions[node.depth] ?? 12, y: (rows[id] ?? 0) * rowPitch + 6,
                               width: widths[node.depth] ?? rowHeight, height: rowHeight)
            nodeFrames[node.id] = frame
            for index in node.terminalCandidateIndices {
                terminalFrames[index] = aligned
                    ? NSRect(x: frame.maxX - rowHeight, y: frame.maxY + scoreHeight, width: rowHeight, height: rowHeight)
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
        guard treeExpanded else {
            nodeButtons.values.forEach { $0.removeFromSuperview() }
            terminalButtons.values.forEach { $0.removeFromSuperview() }
            nodeButtons.removeAll()
            terminalButtons.removeAll()
            setAccessibilitySelectedChildren(navigation.selectedCandidateControls)
            refreshDetails()
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
            button.clicked = { [weak self, weak button] _ in
                guard let self, let button, self.nodeButtons[node.id] === button else {
                    return
                }
                self.selectNode(node.id)
            }
            observeDetailHover(button, target: .node(node.id))
            canvas.addSubview(button)
            nodeButtons[id] = button
        }
        for (index, frame) in terminalFrames where frame.intersects(visible) && terminalButtons[index] == nil && visibleTerminals.contains(index) {
            let terminal = TreeButton(frame: frame)
            terminal.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            terminal.toolTip = String(format: Localization.text("candidate.numberSelect"), numberLabels[index] ?? "")
            terminal.setAccessibilityLabel(terminal.toolTip)
            terminal.clicked = { [weak self, weak terminal] _ in
                guard let self, let terminal, self.terminalButtons[index] === terminal else {
                    return
                }
                self.selectCandidate(index)
            }
            observeDetailHover(terminal, target: .candidate(index))
            canvas.addSubview(terminal)
            terminalButtons[index] = terminal
        }
        refreshControlAppearance()
        refreshDetails()
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
        setAccessibilitySelectedChildren(navigation.selectedCandidateControls + selectedButtons)
        for (index, button) in terminalButtons {
            if let frame = terminalFrames[index] { button.frame = frame }
            let title = numberLabels[index] ?? "↵"
            if button.title != title { button.title = title }
            button.setAccessibilityLabel(String(format: Localization.text("candidate.numberSelect"), title))
            let preview = candidatePage.items.first { $0.index == index }?.detailDescription
            button.toolTip = [button.accessibilityLabel(), preview].compactMap { $0 }.joined(separator: "\n")
            button.setAccessibilityHelp(button.toolTip)
            button.highlightedPath = selection.selectedCandidateIndex == index
            button.font = .monospacedSystemFont(ofSize: max(14, textSize.pointSize - 4), weight: .medium)
            button.compactBadge = documentWidths?.count == displayedColumns.count
            button.needsDisplay = true
        }
    }

    private func refreshSelection() {
        candidatePage = CandidatePage(entries: entries, selectionIndex: selection.selectedCandidateIndex,
                                      pageStart: numberLabels.keys.min())
        navigation.update(page: candidatePage, numbers: numberLabels, fontSize: textSize.pointSize, generation: generation)
        let currentEntry = selection.selectedCandidateIndex.flatMap { tree.entry(candidateIndex: $0) }
        composition.update(entry: currentEntry, fontSize: textSize.pointSize, enterConfirmsCandidate: enterConfirmsCandidate)
        actions.update(candidateIndex: selection.selectedCandidateIndex, generation: generation,
                       treeExpanded: treeExpanded, detailsExpanded: detailsExpanded, enterConfirmsCandidate: enterConfirmsCandidate)
        scrollView.isHidden = !treeExpanded
        details.isHidden = !detailsExpanded
        needsLayout = true
        if displayedColumns != tree.compactColumns(candidateIndex: selection.selectedCandidateIndex) || layoutShowsNumbers != !numberLabels.isEmpty { rebuild() }
        scores = tree.relativeScores(candidateIndex: selection.selectedCandidateIndex)
        scorePresentations = showsScores ? Dictionary(uniqueKeysWithValues: nodeFrames.keys.map {
            ($0, CandidateScorePresentation(relativeScore: scores[$0]))
        }) : [:]
        canvas.scores = scores
        canvas.scorePresentations = scorePresentations
        canvas.nodeFrames = nodeFrames
        canvas.selectedPath = Set(displayedColumns.compactMap(\.first))
        canvas.needsDisplay = true
        if treeExpanded, let id = selection.focusedNodeID, let frame = nodeFrames[id] {
            var reveal = frame
            if let index = selection.selectedCandidateIndex,
               numberLabels[index] != nil, tree.nodes[id].terminalCandidateIndices.contains(index), let terminal = terminalFrames[index] {
                reveal = reveal.union(terminal)
            }
            canvas.scrollToVisible(reveal.insetBy(dx: -16, dy: -16))
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

    private func observeDetailHover(_ button: TreeButton, target: DetailTarget) {
        button.hovered = { [weak self, weak button] hovered in
            guard let self, let button else {
                return
            }
            self.changeDetailHover(target, control: button, hovered: hovered)
        }
    }

    private func isCurrentDetailControl(_ control: NSButton, target: DetailTarget) -> Bool {
        switch target {
        case .node(let id):
            return treeExpanded && nodeButtons[id] === control
        case .candidate(let index):
            return (treeExpanded && terminalButtons[index] === control) || navigation.isCurrentCandidateButton(control, candidateIndex: index)
        }
    }

    private func changeDetailHover(_ target: DetailTarget, control: NSButton, hovered: Bool) {
        if hovered {
            guard isCurrentDetailControl(control, target: target) else {
                return
            }
            hoveredDetail = target
            hoveredControl = control
        } else {
            // A late exit from the previous control must not clear a newer hover.
            guard hoveredControl === control else {
                return
            }
            hoveredDetail = nil
            hoveredControl = nil
        }
        refreshDetails()
    }

    private func refreshDetails() {
        if let target = hoveredDetail, let control = hoveredControl, isCurrentDetailControl(control, target: target) {
            switch target {
            case .node(let id): showDetails(nodeID: id)
            case .candidate(let index): showCandidateDetails(candidateIndex: index)
            }
        } else {
            hoveredDetail = nil
            hoveredControl = nil
            showDetails(nodeID: selection.focusedNodeID ?? displayedColumns.first?.first)
        }
    }

    private func showDetails(nodeID: Int?) {
        guard let nodeID, tree.nodes.indices.contains(nodeID) else {
            details.update(text: "", fontSize: CGFloat(textSize.pointSize))
            return
        }
        let token = tree.nodes[nodeID].token
        let word = token.reading.isEmpty ? token.text : "\(token.text)\n\(token.reading)"
        let preview = tree.preview(at: nodeID, preserving: selection.selectedCandidateIndex)?.detailDescription
        let description = [word, preview, scorePresentations[nodeID]?.detailDescription, Localization.text("candidate.detailKeys")]
            .compactMap { $0 }.joined(separator: "\n")
        details.update(text: description, fontSize: CGFloat(textSize.pointSize))
    }

    private func showCandidateDetails(candidateIndex: Int) {
        // A shared word and its adjacent number may commit different entries.
        let preview = candidatePage.items.first { $0.index == candidateIndex }?.detailDescription ?? ""
        details.update(text: preview, fontSize: CGFloat(textSize.pointSize))
    }
}
