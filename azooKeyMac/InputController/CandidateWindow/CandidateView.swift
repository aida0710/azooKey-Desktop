import Cocoa
import Core
import KanaKanjiConverterModule

@MainActor
protocol CandidatesViewControllerDelegate: AnyObject {
    func candidateSubmitted()
    func candidateSubmitted(_ row: Int)
    func candidateSelectionChanged(_ row: Int)
}

extension CandidatesViewControllerDelegate {
    func candidateSubmitted(_ row: Int) {
        candidateSelectionChanged(row)
        candidateSubmitted()
    }
}

class CandidatesViewController: BaseCandidateViewController {
    weak var delegate: (any CandidatesViewControllerDelegate)?
    private var showedRows: ClosedRange = 0...8
    var showCandidateIndex = false
    private let treeView = CandidateTreeView()
    private var treeEntries: [CandidateTree.Entry] = []
    private var lastCursorLocation: CGPoint?
    private var documentGeometry: CandidateDocumentGeometry?
    private var alignmentReason = "client-rectangles-unavailable"
    private var usesTree: Bool { Config.TreeCandidates().value }

    override func loadView() {
        super.loadView()
        treeView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(treeView)
        NSLayoutConstraint.activate([
            treeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            treeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            treeView.topAnchor.constraint(equalTo: view.topAnchor),
            treeView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        treeView.onSelectionChanged = { [weak self] row in
            self?.updateSelection(to: row)
        }
        treeView.onLayoutChanged = { [weak self] in
            guard let self, let cursor = self.lastCursorLocation else {
                return
            }
            self.resizeWindowToFitContent(cursorLocation: cursor)
        }
        treeView.onCandidateSubmitted = { [weak self] row in
            guard let self, self.candidates.indices.contains(row) else {
                return
            }
            self.updateSelection(to: row, notifySelectionChange: false)
            self.delegate?.candidateSubmitted(row)
        }
    }

    private func refreshTree(selectionIndex: Int?) {
        var numbers: [Int: String] = [:]
        if showCandidateIndex {
            for index in showedRows where candidates.indices.contains(index) {
                numbers[index] = String(index - showedRows.lowerBound + 1)
            }
        }
        treeView.update(entries: treeEntries, selectionIndex: selectionIndex, numbers: numbers, documentWidths: documentGeometry?.widths)
        if usesTree, let cursor = lastCursorLocation { resizeWindowToFitContent(cursorLocation: cursor) }
    }

    func handleTreeNavigation(_ direction: CandidateTreeSelection.Direction) -> Bool {
        guard usesTree, !candidates.isEmpty else {
            return false
        }
        treeView.navigate(direction)
        // At the end of a path, Right must not fall through to upstream's commit.
        return true
    }

    func scrollTreeDetails(forward: Bool) -> Bool {
        usesTree && !candidates.isEmpty && treeView.scrollDetails(forward: forward)
    }

    override func resizeWindowToFitContent(cursorLocation: CGPoint) {
        guard usesTree else {
            super.resizeWindowToFitContent(cursorLocation: cursorLocation)
            return
        }
        guard let window = view.window,
              let screen = ScreenLookup.screen(containing: cursorLocation, fallbackWindow: window) else {
            return
        }
        let size = treeView.preferredSize
        let frame = WindowPositioning.frameNearCursor(
            currentFrame: .init(window.frame), screenRect: .init(screen.visibleFrame),
            cursorLocation: .init(documentGeometry?.anchor ?? cursorLocation),
            desiredSize: .init(width: min(size.width, screen.visibleFrame.width), height: min(size.height, screen.visibleFrame.height))
        ).cgRect
        window.setFrame(frame, display: true, animate: false)
        CandidateLayoutDiagnostics.record(
            reason: treeView.hasDocumentAlignment ? "client-rectangles" :
                (documentGeometry == nil ? alignmentReason : "column-too-narrow"),
            cursor: cursorLocation, popup: frame, workArea: screen.visibleFrame)
    }

    override func updateCandidatePresentations(_ candidates: [CandidatePresentation], selectionIndex: Int?, cursorLocation: CGPoint) {
        lastCursorLocation = cursorLocation
        self.showedRows = selectionIndex == nil ? 0...8 : self.showedRows
        treeView.isHidden = !usesTree
        tableView.enclosingScrollView?.isHidden = usesTree
        view.subviews.compactMap { $0 as? NSVisualEffectView }.forEach { $0.isHidden = usesTree }
        configureWindowForRoundedCorners()
        treeEntries = candidates.enumerated().map { $0.element.treeEntry(index: $0.offset) }
        treeView.update(entries: treeEntries, selectionIndex: selectionIndex, documentWidths: documentGeometry?.widths)
        super.updateCandidatePresentations(
            candidates,
            selectionIndex: selectionIndex,
            cursorLocation: cursorLocation
        )
    }

    func alignWithDocument(_ candidates: [CandidatePresentation], selectionIndex: Int?, preedit: String,
                           rectAtOffset: (Int) -> NSRect) {
        documentGeometry = nil
        alignmentReason = "client-rectangles-unavailable"
        guard usesTree, let selectionIndex, candidates.indices.contains(selectionIndex) else {
            return
        }
        let projection = CandidateTree(entries: candidates.enumerated().map { $0.element.treeEntry(index: $0.offset) })
        let words = (projection.paths[selectionIndex] ?? []).map { projection.nodes[$0].token.text }
        let geometry = CandidateDocumentGeometry(
            words: words, preedit: preedit, rectAtOffset: rectAtOffset
        )
        if let geometry, NSScreen.screens.contains(where: { geometry.fits(in: $0.visibleFrame) }) {
            documentGeometry = geometry
        } else if geometry != nil {
            alignmentReason = "outside-workarea"
        }
    }

    override func configureWindowForRoundedCorners() {
        super.configureWindowForRoundedCorners()
        if usesTree {
            view.window?.hasShadow = false
            view.window?.contentView?.layer?.cornerRadius = 0
        }
    }

    override internal func updateSelectionCallback(_ row: Int, notifySelectionChange: Bool) {
        if usesTree {
            let start = max(0, row) / CandidatePage.size * CandidatePage.size
            showedRows = start...(start + CandidatePage.size - 1)
        } else if !self.showedRows.contains(row) {
            if row < self.showedRows.lowerBound {
                self.showedRows = row...(row + 8)
            } else {
                self.showedRows = (row - 8)...row
            }
        }
        refreshTree(selectionIndex: candidates.indices.contains(row) ? row : nil)
        if notifySelectionChange {
            delegate?.candidateSelectionChanged(row)
        }
    }

    override internal func configureCellView(_ cell: CandidateTableCellView, forRow row: Int) {
        let candidate = self.candidates[row].candidate
        let annotationText = self.candidates[row].displayContext.annotationText
        let isWithinShowedRows = self.showedRows.contains(row)
        let displayIndex = row - self.showedRows.lowerBound + 1 // showedRowsの下限からの相対的な位置
        let displayText: String

        if isWithinShowedRows && self.showCandidateIndex {
            if displayIndex > 9 {
                displayText = " " + candidate.text // 行番号が10以上の場合、インデントを調整
            } else {
                displayText = "\(displayIndex). " + candidate.text
            }
        } else {
            displayText = candidate.text // showedRowsの範囲外では番号を付けない
        }

        // 数字部分と候補部分を別々に設定
        let attributedString = NSMutableAttributedString(string: displayText)
        let numberRange = (displayText as NSString).range(of: "\(displayIndex).")

        if numberRange.location != NSNotFound {
            attributedString.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: max(14, Config.CandidateTextSize().value.pointSize - 4), weight: .regular),
                .foregroundColor: currentSelectedRow == row ? NSColor.white : NSColor.gray,
                .baselineOffset: 2
            ], range: numberRange)
        }

        cell.candidateTextField.attributedStringValue = attributedString

        if let annotationText {
            let annotationString = NSAttributedString(
                string: annotationText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: currentSelectedRow == row ? NSColor.white : NSColor.systemGray
                ]
            )
            cell.showCandidateAnnotationTextField(true)
            cell.candidateAnnotationTextField.attributedStringValue = annotationString
        } else {
            cell.showCandidateAnnotationTextField(false)
            cell.candidateAnnotationTextField.stringValue = ""
        }
    }

    func getNumberCandidate(num: Int) -> Int? {
        let nextRow = self.showedRows.lowerBound + num - 1
        guard (1...CandidatePage.size).contains(num), candidates.indices.contains(nextRow) else {
            return nil
        }
        return nextRow
    }

    func hide() {
        self.currentSelectedRow = -1
        self.showedRows = 0...8
        treeEntries = []
        treeView.update(entries: [], selectionIndex: nil)
    }

    override var numberOfVisibleRows: Int {
        min(9, self.tableView.numberOfRows)
    }

    override func getWindowWidth(maxContentWidth: CGFloat) -> CGFloat {
        let hasAnnotation = self.candidates.contains { $0.displayContext.annotationText != nil }
        if self.showCandidateIndex {
            return maxContentWidth + 48 + (hasAnnotation ? 56 : 0)
        } else {
            return maxContentWidth + 20 + (hasAnnotation ? 56 : 0)
        }
    }
}

class PredictionCandidatesViewController: BaseCandidateViewController {
    private let prefixTabStop: CGFloat = 24
    private let prefixSymbolName = "arrow.forward.to.line.compact"
    private let prefixFontSize: CGFloat = 12

    override var numberOfVisibleRows: Int {
        min(3, self.tableView.numberOfRows)
    }

    override internal func configureCellView(_ cell: CandidateTableCellView, forRow row: Int) {
        let candidateText = candidates[row].candidate.text
        let attributedString = NSMutableAttributedString()

        let isSelected = currentSelectedRow == row
        let candidateColor = isSelected ? NSColor.white : NSColor.labelColor

        if let symbol = NSImage(systemSymbolName: prefixSymbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: prefixFontSize, weight: .regular)
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            let attachment = NSTextAttachment()
            attachment.image = configured
            attachment.bounds = NSRect(x: 0, y: -2, width: prefixFontSize + 2, height: prefixFontSize + 2)
            attributedString.append(NSAttributedString(attachment: attachment))
        }
        attributedString.append(NSAttributedString(string: "\t"))
        let candidateAttributed = NSAttributedString(
            string: candidateText,
            attributes: [
                .font: NSFont.systemFont(ofSize: Config.CandidateTextSize().value.pointSize),
                .foregroundColor: candidateColor
            ]
        )
        attributedString.append(candidateAttributed)

        let fullRange = NSRange(location: 0, length: attributedString.length)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .left, location: prefixTabStop, options: [:])
        ]
        paragraphStyle.defaultTabInterval = prefixTabStop
        attributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

        cell.candidateTextField.attributedStringValue = attributedString
    }

    override func getWindowWidth(maxContentWidth: CGFloat) -> CGFloat {
        maxContentWidth + prefixTabStop + 20
    }
}
