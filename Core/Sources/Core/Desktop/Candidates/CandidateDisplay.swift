import Foundation

/// What the candidate window shows for one snapshot: the display mode, the
/// nodes to draw with their numbers and accessible text, the full-sentence
/// list, and the announcement. Renderers draw this; they do not decide it.
public struct CandidateDisplay: Encodable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// Live input: only the tree with its branches.
        case tree
        /// Conversion: the full-sentence list, with the tree on request.
        case list
        case hidden
    }

    public struct Node: Encodable, Equatable, Sendable {
        public let id: Int
        /// The 1...9 badge of the candidate this node selects on the current page.
        public let number: Int?
        /// On the selected sentence's path.
        public let selected: Bool
        /// The word that arrow keys move.
        public let focused: Bool
        public let accessibleName: String
        public let accessibleDescription: String
        public let detailText: String
    }

    public struct ListItem: Encodable, Equatable, Sendable {
        public let index: Int
        public let number: Int?
        public let text: String
        public let selected: Bool
        public let accessibleName: String
        public let accessibleDescription: String
        public let detailText: String
    }

    public struct List: Encodable, Equatable, Sendable {
        public let title: String
        public let commitText: String
        public let readingText: String?
        public let remainingText: String?
        public let positionText: String
        /// Enter confirms the selected candidate; otherwise it commits the reading.
        public let keyboardConfirmsCandidate: Bool
        public let confirmLabel: String
        public let confirmAccessibleName: String
        public let confirmAccessibleDescription: String
        /// The candidate the confirm action submits; nil disables the action.
        public let confirmIndex: Int?
        public let previousIndex: Int?
        public let nextIndex: Int?
        public let items: [ListItem]
    }

    public let mode: Mode
    /// Node ids to draw, one array per column; the first row is the selected path.
    public let columns: [[Int]]
    /// Some drawn node has a number badge, so every node reserves its line.
    public let showsNumbers: Bool
    /// Candidate font size before the desktop text scale; measure text at this size.
    public let baseFontSize: Double
    public let nodes: [Node]
    /// The node whose details are shown when nothing is hovered.
    public let detailNode: Int?
    /// The focus moved to another word of the same candidate; show the tree.
    public let expandTree: Bool
    /// Spoken when it differs from the previous announcement in the same input context.
    public let announcement: String?
    public let list: List?

    public init(_ input: CandidateDisplayInput) {
        let mode = Self.mode(input)
        let columns = Self.columns(input, mode: mode)
        let numbers = Self.nodeNumbers(input, mode: mode, columns: columns)
        let nodesByID = Dictionary(input.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let selectedPath = Set(input.selectedPath)
        self.mode = mode
        self.columns = columns
        self.showsNumbers = !numbers.isEmpty
        self.baseFontSize = CandidateTextMetrics.baseFontSize(input.candidateTextSize)
        self.nodes = columns.flatMap { $0 }.compactMap { id in
            nodesByID[id].map { node in
                Self.node(node, number: numbers[id], selected: selectedPath.contains(id),
                          focused: id == input.focusedNode, showScores: input.showRelativeScores)
            }
        }
        self.detailNode = input.focusedNode ?? input.columns.first?.first
        self.expandTree = Self.focusMovedWithinCandidate(input)
        self.announcement = CandidateAnnouncement.text(input)
        self.list = Self.list(input)
    }

    private static let selectionStates: Set<String> = ["previewing", "selecting", "replaceSuggestion"]

    static func keyboardConfirmsCandidate(_ input: CandidateDisplayInput) -> Bool {
        selectionStates.contains(input.inputState)
    }

    private static func mode(_ input: CandidateDisplayInput) -> Mode {
        guard !input.nodes.isEmpty, !input.columns.isEmpty else {
            return .hidden
        }
        return keyboardConfirmsCandidate(input) ? .list : .tree
    }

    /// The list expands only the column being edited; other words show the
    /// selected sentence. Live input shows every branch.
    private static func columns(_ input: CandidateDisplayInput, mode: Mode) -> [[Int]] {
        guard mode == .list else {
            return mode == .tree ? input.columns : []
        }
        let focusedColumn = input.columns.firstIndex { $0.contains(input.focusedNode ?? -1) } ?? 0
        return input.columns.enumerated().map { depth, column in
            depth == focusedColumn ? column : [input.selectedPath.indices.contains(depth) ? input.selectedPath[depth] : column[0]]
        }
    }

    /// A shared node can end a shorter candidate than the one it selects, so
    /// the number always comes from its preview's candidate.
    private static func nodeNumbers(_ input: CandidateDisplayInput, mode: Mode, columns: [[Int]]) -> [Int: Int] {
        // Live badges identify the preview; selection advertises number keys.
        guard mode == .tree || input.showCandidateIndex else {
            return [:]
        }
        let visible = Set(columns.flatMap { $0 })
        var numbers: [Int: Int] = [:]
        for node in input.nodes where visible.contains(node.id) {
            guard let index = node.preview?.candidateIndex,
                  let number = pageNumber(index: index, page: input.candidatePage) else {
                continue
            }
            numbers[node.id] = number
        }
        return numbers
    }

    private static func pageNumber(index: Int, page: CandidateDisplayInput.Page) -> Int? {
        let number = index - page.start + 1
        return (1...CandidatePage.size).contains(number) ? number : nil
    }

    private static func node(_ node: CandidateDisplayInput.Node, number: Int?, selected: Bool,
                             focused: Bool, showScores: Bool) -> Node {
        let score = showScores ? CandidateScorePresentation(relativeScore: node.relativeScore).detailDescription : nil
        let action = Localization.text(focused ? "candidate.focusedSelect" : "candidate.select")
        let numberBadge = number.map { String(format: Localization.text("candidate.numberBadge"), String($0)) }
        return Node(
            id: node.id, number: number, selected: selected, focused: focused,
            accessibleName: CandidateText.withReading(node.text, reading: node.reading),
            accessibleDescription: CandidateText.lines([action, node.previewDescription, score, numberBadge]),
            detailText: CandidateText.lines([node.text, node.reading, node.previewDescription, score,
                                             Localization.text("candidate.detailKeys")])
        )
    }

    private static func focusMovedWithinCandidate(_ input: CandidateDisplayInput) -> Bool {
        guard let previous = input.previous, let selection = input.selection, selection == previous.selection,
              let focused = input.focusedNode, let previousFocused = previous.focusedNode else {
            return false
        }
        return focused != previousFocused
    }

    private static func list(_ input: CandidateDisplayInput) -> List? {
        let page = input.candidatePage
        guard page.totalCount > 0 || input.selection != nil else {
            return nil
        }
        let selection = input.selection
        let candidate = input.candidates.first { $0.index == selection }
        let pageItem = page.items.first { $0.index == selection }
        let preview = input.nodes.lazy.compactMap(\.preview).first { $0.candidateIndex == selection }
        let commitText = candidate?.text ?? pageItem?.text ?? preview?.text ?? input.preedit
        let scope = candidate?.commitScope ?? preview?.scope
        let reading = scope?.consumedReading ?? input.reading
        let remaining = scope?.remainingReading ?? ""
        let keyboardConfirms = keyboardConfirmsCandidate(input)
        let confirmAction = Localization.text(keyboardConfirms ? "candidate.submit" : "candidate.submitCandidate")
        return List(
            title: Localization.text(keyboardConfirms ? "candidate.composition" : "candidate.proposal"),
            commitText: commitText,
            readingText: reading.isEmpty ? nil : String(format: Localization.text("candidate.announceReading"), reading),
            remainingText: remaining.isEmpty ? nil : String(format: Localization.text("candidate.announceRemaining"), remaining),
            positionText: String(format: Localization.text("candidate.position"),
                                 page.position.map(String.init) ?? "—", String(page.totalCount)),
            keyboardConfirmsCandidate: keyboardConfirms,
            // The return mark advertises Enter only when Enter confirms this candidate.
            confirmLabel: keyboardConfirms ? confirmAction + " ↵" : confirmAction,
            confirmAccessibleName: confirmAction + " " + commitText,
            confirmAccessibleDescription: Localization.text("candidate.confirm"),
            confirmIndex: selection,
            previousIndex: page.previousIndex,
            nextIndex: page.nextIndex,
            items: page.items.map { item in
                ListItem(
                    index: item.index,
                    number: input.showCandidateIndex ? pageNumber(index: item.index, page: page) : nil,
                    text: item.text, selected: item.index == selection,
                    accessibleName: CandidateText.withReading(item.text, reading: item.reading),
                    accessibleDescription: CandidateText.lines([Localization.text("candidate.select"), item.detailDescription]),
                    detailText: item.detailDescription
                )
            }
        )
    }
}
