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
    private let definitions: WordDefinitionsModel
    private let definitionSide = WordDefinitionsSideView(frame: .zero)
    private let bodyViewport = NSScrollView()
    private let body = NSView()
    private let pointerLocation: (NSView) -> NSPoint?
    private var pointerTracking: NSTrackingArea?
    private var retainingDetailHover = false
    private var availableWidth: CGFloat?
    private var definitionsEnabled = true
    private let canvas = TreeCanvas()
    private var nodeButtons: [Int: TreeButton] = [:]
    private var hoveredDetail: DetailTarget?
    private weak var hoveredControl: NSButton?
    private var nodeFrames: [Int: NSRect] = [:]
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
    private var revealedTreeSelection: TreeViewportSelection?
    private struct TreeViewportSelection: Equatable {
        var candidateIndex: Int?
        var nodeID: Int?
        var generation: UInt
        var isEditing: Bool
    }
    // Optional branches stay scrollable without displacing the primary candidate list.
    private let maximumTreeHeight: CGFloat = 220
    // Long commit text scrolls without consuming the candidate body's minimum height.
    private let maximumCompositionHeightFraction: CGFloat = 0.35
    // Detail text needs a readable line even when the selected word is one character.
    private let minimumDetailWidth = CandidateDetailView.minimumWidth
    var hasDocumentAlignment: Bool { documentWidths != nil }
    private var treePreferredSize = NSSize(width: 80, height: 46)
    private var showsTree: Bool { !tree.nodes.isEmpty && (!enterConfirmsCandidate || treeExpanded) }
    var preferredSize: NSSize {
        let columns = columns(availableWidth: availableWidth ?? .greatestFiniteMagnitude)
        let compositionHeight = enterConfirmsCandidate ? composition.preferredHeight(width: columns.viewportWidth) : 0
        let bodyHeight = max(leftHeights(width: columns.leftWidth).total, definitionSide.isHidden ? 0 : definitionSide.preferredHeight)
        let scrollerHeight = columns.contentWidth > columns.viewportWidth ?
            NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return NSSize(width: columns.viewportWidth, height: compositionHeight + bodyHeight + scrollerHeight)
    }

    private func columns(availableWidth: CGFloat) -> WordDefinitionsSideLayout {
        WordDefinitionsSideLayout(availableWidth: availableWidth,
                                  preferredLeftWidth: showsTree ? treePreferredSize.width : minimumDetailWidth,
                                  showsDefinitions: !definitionSide.isHidden)
    }

    private func leftHeights(width: CGFloat) -> WordDefinitionsSideLayout.LeftHeights {
        .init(navigation: enterConfirmsCandidate ? navigation.preferredHeight(width: width) : 0,
              tree: showsTree ? min(maximumTreeHeight, treePreferredSize.height) : 0,
              details: detailsExpanded ? CandidateDetailView.maximumHeight : 0,
              actions: actions.preferredHeight(width: width), minimumNavigation: enterConfirmsCandidate ? navigation.minimumHeight : 0)
    }

    func setAvailableWidth(_ width: CGFloat) {
        guard availableWidth != width else {
            return
        }
        availableWidth = width
        needsLayout = true
    }

    override convenience init(frame: NSRect) {
        self.init(frame: frame, definitions: WordDefinitionsModel())
    }

    init(frame: NSRect, definitions: WordDefinitionsModel, pointerLocation: ((NSView) -> NSPoint?)? = nil) {
        self.definitions = definitions
        self.pointerLocation = pointerLocation ?? { view in
            guard let window = view.window else {
                return nil
            }
            return view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }
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
        addSubview(composition)
        bodyViewport.frame = bounds
        body.frame = bounds
        bodyViewport.documentView = body
        bodyViewport.hasVerticalScroller = false
        bodyViewport.scrollerStyle = .legacy
        bodyViewport.autohidesScrollers = true
        bodyViewport.drawsBackground = false
        bodyViewport.setAccessibilityIdentifier("candidate-side-viewport")
        addSubview(bodyViewport)
        for view in [scrollView as NSView, details, navigation, actions, definitionSide] { body.addSubview(view) }
        definitionSide.onLayoutChanged = { [weak self] in
            self?.needsLayout = true
            self?.onLayoutChanged?()
        }
        definitionSide.onPointerExit = { [weak self] in self?.clearRetainedDetailHoverIfNeeded() }
        definitions.onChange = { [weak self] in self?.refreshDetails() }
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
            self.clearDetailHover()
            self.treeExpanded.toggle()
            self.generation &+= 1
            self.retireTreeControls()
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
        let columns = columns(availableWidth: bounds.width)
        let compositionHeight = enterConfirmsCandidate ?
            min(bounds.height * maximumCompositionHeightFraction, composition.preferredHeight(width: bounds.width)) : 0
        composition.frame = NSRect(x: 0, y: bounds.height - compositionHeight, width: bounds.width, height: compositionHeight)
        bodyViewport.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - compositionHeight))
        bodyViewport.hasHorizontalScroller = columns.contentWidth > bounds.width
        body.frame = NSRect(x: 0, y: 0, width: columns.contentWidth, height: bodyViewport.bounds.height)
        bodyViewport.tile()
        body.setFrameSize(NSSize(width: columns.contentWidth, height: bodyViewport.contentSize.height))
        let frames = columns.frames(height: body.bounds.height, left: leftHeights(width: columns.leftWidth),
                                    definitionHeight: definitionSide.isHidden ? 0 : definitionSide.preferredHeight)
        navigation.frame = frames.navigation
        scrollView.frame = frames.tree
        details.frame = frames.details
        actions.frame = frames.actions
        definitionSide.frame = frames.definitions
        let maximumOffset = max(0, body.bounds.width - bodyViewport.contentSize.width)
        bodyViewport.contentView.scroll(to: NSPoint(x: min(maximumOffset, max(0, bodyViewport.contentView.bounds.minX)), y: 0))
        bodyViewport.reflectScrolledClipView(bodyViewport.contentView)
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
        let palette = CandidateTheme.palette(for: effectiveAppearance)
        details.applyPalette(palette)
        definitionSide.applyPalette(palette)
        composition.applyPalette(palette)
        navigation.applyPalette(palette)
        actions.subviews.forEach { $0.needsDisplay = true }
    }

    func setDefinitionsEnabled(_ enabled: Bool) {
        definitionsEnabled = enabled
        if !enabled {
            definitions.invalidate()
            clearDetailHover()
            definitionSide.update(target: nil, result: nil, fontSize: CGFloat(textSize.pointSize))
        }
    }

    func update(entries: [CandidateTree.Entry], selectionIndex: Int?, numbers: [Int: String] = [:],
                documentWidths: [CGFloat]? = nil, enterConfirmsCandidate: Bool = false) {
        let updatedTree = CandidateTree(entries: entries)
        let size = Config.CandidateTextSize().value
        let scoresVisible = Config.ShowRelativeScores().value
        let minimumColumnWidth = CGFloat(size.pointSize) + (numbers.isEmpty ? 8 : 14)
        let readableWidths = documentWidths?.allSatisfy { $0 >= minimumColumnWidth } == true ? documentWidths : nil
        let changed = updatedTree != tree || self.documentWidths != readableWidths || textSize != size || showsScores != scoresVisible
        let phaseChanged = self.enterConfirmsCandidate != enterConfirmsCandidate
        if (retainingDetailHover && selection.selectedCandidateIndex != selectionIndex) || updatedTree != tree || phaseChanged {
            clearDetailHover()
        }
        if updatedTree != tree || phaseChanged {
            generation &+= 1
            retireTreeControls()
        }
        if phaseChanged {
            treeExpanded = false
            detailsExpanded = false
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
        } else if enterConfirmsCandidate {
            composition.scrollPage(forward: forward)
        } else {
            detailsExpanded = true
            refreshSelection()
            onLayoutChanged?()
            details.scrollPage(forward: forward)
        }
        return true
    }

    @discardableResult
    func navigate(_ direction: CandidateTreeSelection.Direction) -> Bool {
        if retainingDetailHover { clearDetailHover() }
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
        clearDetailHover()
        selection.synchronize(tree: tree, candidateIndex: candidateIndex)
        refreshSelection()
        // Submission carries its index so a click can't commit an old selection.
        onCandidateSubmitted?(candidateIndex)
    }

    private func selectCandidate(_ index: Int) {
        guard tree.paths[index] != nil else {
            return
        }
        clearDetailHover()
        selection.synchronize(tree: tree, candidateIndex: index)
        refreshSelection()
        // Selecting the already-highlighted composing candidate must still enter selection mode.
        onSelectionChanged?(index)
    }

    private func selectNode(_ nodeID: Int) {
        guard let index = selection.select(nodeID: nodeID, in: tree) else {
            return
        }
        clearDetailHover()
        refreshSelection()
        onSelectionChanged?(index)
    }

    private func rebuild() {
        rebuilding = true
        defer { rebuilding = false }
        nodeFrames.removeAll()
        var rows: [Int: CGFloat] = [:]
        displayedColumns = presentationColumns
        layoutShowsNumbers = !numberLabels.isEmpty
        var widths: [Int: CGFloat] = [:]
        let aligned = documentWidths?.count == displayedColumns.count
        // A number shares the word's action and fits below its text, including the 24-point setting.
        let rowHeight = TreeButton.preferredHeight(fontSize: textSize.pointSize, hasNumber: layoutShowsNumbers)
        let scoreHeight = showsScores ? CandidateScoreBadge.lineHeight : 0
        let rowGap: CGFloat = 4 // Separate candidate actions even when the score line is hidden.
        let rowPitch: CGFloat = rowHeight + scoreHeight + rowGap
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
            x += (widths[depth] ?? rowHeight) + (aligned ? 0 : 12)
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

    private func candidateNumber(nodeID: Int) -> String? {
        // A shared word may preserve a full candidate; its badge must name that same action.
        guard let index = tree.preferredCandidate(at: nodeID, preserving: selection.selectedCandidateIndex) else {
            return nil
        }
        return numberLabels[index]
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
            refreshDetails()
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
            button.candidateNumber = candidateNumber(nodeID: id)
            if let number = button.candidateNumber {
                button.toolTip! += "\n" + String(format: Localization.text("candidate.numberBadge"), number)
            }
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
        navigation.update(page: candidatePage, numbers: numberLabels, fontSize: textSize.pointSize, generation: generation)
        navigation.isHidden = !enterConfirmsCandidate || entries.isEmpty
        let currentEntry = selection.selectedCandidateIndex.flatMap { tree.entry(candidateIndex: $0) }
        composition.update(entry: currentEntry, fontSize: textSize.pointSize, enterConfirmsCandidate: enterConfirmsCandidate)
        composition.isHidden = !enterConfirmsCandidate
        actions.update(candidateIndex: selection.selectedCandidateIndex, generation: generation,
                       treeExpanded: treeExpanded, detailsExpanded: detailsExpanded, enterConfirmsCandidate: enterConfirmsCandidate)
        scrollView.isHidden = !showsTree
        details.isHidden = !detailsExpanded
        needsLayout = true
        if displayedColumns != presentationColumns || layoutShowsNumbers != !numberLabels.isEmpty { rebuild() }
        scores = tree.relativeScores(candidateIndex: selection.selectedCandidateIndex)
        scorePresentations = showsScores ? Dictionary(uniqueKeysWithValues: nodeFrames.keys.map {
            ($0, CandidateScorePresentation(relativeScore: scores[$0]))
        }) : [:]
        canvas.scores = scores
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
            return showsTree && nodeButtons[id] === control
        case .candidate(let index):
            return navigation.isCurrentCandidateButton(control, candidateIndex: index)
        }
    }

    private func changeDetailHover(_ target: DetailTarget, control: NSButton, hovered: Bool) {
        if hovered {
            guard isCurrentDetailControl(control, target: target) else {
                return
            }
            hoveredDetail = target
            hoveredControl = control
            retainingDetailHover = false
        } else {
            // A late exit from the previous control must not clear a newer hover.
            guard hoveredControl === control else {
                return
            }
            if pointerRemainsWithinDefinition(control: control) {
                retainingDetailHover = true
                return
            }
            clearDetailHover()
        }
        refreshDetails()
    }

    private func clearDetailHover() {
        hoveredDetail = nil
        hoveredControl = nil
        retainingDetailHover = false
    }

    private func pointerRemainsWithinDefinition(control: NSView) -> Bool {
        guard !definitionSide.isHidden, let point = pointerLocation(self) else {
            return false
        }
        return WordDefinitionsSideLayout.retainsHover(at: point, source: convert(control.bounds, from: control),
                                                     definitions: convert(definitionSide.bounds, from: definitionSide), viewport: bounds)
    }

    private func clearRetainedDetailHoverIfNeeded() {
        guard retainingDetailHover else {
            return
        }
        if let control = hoveredControl, let target = hoveredDetail,
           isCurrentDetailControl(control, target: target), pointerRemainsWithinDefinition(control: control) {
            return
        }
        clearDetailHover()
        refreshDetails()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        pointerTracking = tracking
    }

    override func mouseMoved(with event: NSEvent) { clearRetainedDetailHoverIfNeeded() }
    override func mouseExited(with event: NSEvent) { clearRetainedDetailHoverIfNeeded() }

    private func refreshDetails() {
        if let target = hoveredDetail, let control = hoveredControl, isCurrentDetailControl(control, target: target) {
            switch target {
            case .node(let id): showDetails(nodeID: id)
            case .candidate(let index): showCandidateDetails(candidateIndex: index)
            }
        } else {
            clearDetailHover()
            showDetails(nodeID: selection.focusedNodeID ?? displayedColumns.first?.first)
        }
    }

    private func showDetails(nodeID: Int?, candidateIndex: Int? = nil, previewText: String? = nil) {
        guard let nodeID, tree.nodes.indices.contains(nodeID) else {
            definitions.invalidate()
            definitionSide.update(target: nil, result: nil, fontSize: CGFloat(textSize.pointSize))
            details.update(text: "", fontSize: CGFloat(textSize.pointSize))
            return
        }
        let token = tree.nodes[nodeID].token
        let word = token.reading.isEmpty ? token.text : "\(token.text)\n\(token.reading)"
        let preview = tree.preview(at: nodeID, preserving: selection.selectedCandidateIndex)?.detailDescription
        let description = previewText ?? [word, preview, scorePresentations[nodeID]?.detailDescription, Localization.text("candidate.detailKeys")]
            .compactMap { $0 }.joined(separator: "\n")
        let index = candidateIndex ?? tree.preferredCandidate(at: nodeID, preserving: selection.selectedCandidateIndex)
        let target = definitionsEnabled && enterConfirmsCandidate ? index.map {
            WordDefinitionsModel.Target(generation: generation, candidateIndex: $0, nodeID: nodeID, word: token.text, reading: token.reading)
        } : nil
        definitions.update(target: target)
        definitionSide.update(target: definitions.target, result: definitions.result, fontSize: CGFloat(textSize.pointSize))
        details.update(text: description, fontSize: CGFloat(textSize.pointSize))
    }

    private func showCandidateDetails(candidateIndex: Int) {
        let preview = candidatePage.items.first { $0.index == candidateIndex }?.detailDescription ?? ""
        // A full row keeps its real candidate path and the user's current word depth.
        let depth = selection.focusedNodeID.map { tree.nodes[$0].depth } ?? 0
        let nodeID = tree.paths[candidateIndex].flatMap { path in path.isEmpty ? nil : path[min(depth, path.count - 1)] }
        showDetails(nodeID: nodeID, candidateIndex: candidateIndex, previewText: preview)
    }
}
