/// The candidate fields of a desktop snapshot that decide what is displayed.
/// Field names match the bridge snapshot, so the `candidate-display`
/// operation can read a snapshot object directly; missing fields are empty.
public struct CandidateDisplayInput: Decodable, Sendable {
    public struct Candidate: Decodable, Sendable {
        public var index: Int
        public var text: String
        public var commitScope: CandidateCommitScope?

        public init(index: Int, text: String, commitScope: CandidateCommitScope?) {
            self.index = index
            self.text = text
            self.commitScope = commitScope
        }
    }

    public struct Preview: Decodable, Sendable {
        public var candidateIndex: Int
        public var text: String?
        public var scope: CandidateCommitScope?

        public init(candidateIndex: Int, text: String?, scope: CandidateCommitScope?) {
            self.candidateIndex = candidateIndex
            self.text = text
            self.scope = scope
        }
    }

    public struct Node: Decodable, Sendable {
        public var id: Int
        public var text: String
        public var reading: String
        public var relativeScore: Int?
        public var preview: Preview?
        public var previewDescription: String?
        public var parent: Int?

        public init(id: Int, text: String, reading: String, relativeScore: Int?, preview: Preview?, previewDescription: String?, parent: Int? = nil) {
            self.id = id
            self.text = text
            self.reading = reading
            self.relativeScore = relativeScore
            self.preview = preview
            self.previewDescription = previewDescription
            self.parent = parent
        }

        private enum CodingKeys: String, CodingKey {
            case id, text, reading, relativeScore, preview, previewDescription, parent
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            text = try container.decode(String.self, forKey: .text)
            reading = try container.decodeIfPresent(String.self, forKey: .reading) ?? ""
            relativeScore = try container.decodeIfPresent(Int.self, forKey: .relativeScore)
            preview = try container.decodeIfPresent(Preview.self, forKey: .preview)
            previewDescription = try container.decodeIfPresent(String.self, forKey: .previewDescription)
            parent = try container.decodeIfPresent(Int.self, forKey: .parent)
        }
    }

    public struct PageItem: Decodable, Sendable {
        public var index: Int
        public var text: String
        public var reading: String
        public var detailDescription: String

        public init(index: Int, text: String, reading: String, detailDescription: String) {
            self.index = index
            self.text = text
            self.reading = reading
            self.detailDescription = detailDescription
        }

        private enum CodingKeys: String, CodingKey {
            case index, text, reading, detailDescription
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            text = try container.decode(String.self, forKey: .text)
            reading = try container.decodeIfPresent(String.self, forKey: .reading) ?? ""
            detailDescription = try container.decodeIfPresent(String.self, forKey: .detailDescription) ?? text
        }
    }

    public struct Page: Decodable, Sendable {
        public var start: Int
        public var position: Int?
        public var totalCount: Int
        public var items: [PageItem]
        public var previousIndex: Int?
        public var nextIndex: Int?

        public init(_ page: CandidatePage) {
            start = page.start
            position = page.position
            totalCount = page.totalCount
            items = page.items.map { .init(index: $0.index, text: $0.text, reading: $0.reading, detailDescription: $0.detailDescription) }
            previousIndex = page.previousIndex
            nextIndex = page.nextIndex
        }

        private enum CodingKeys: String, CodingKey {
            case start, position, totalCount, items, previousIndex, nextIndex
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            start = try container.decodeIfPresent(Int.self, forKey: .start) ?? 0
            position = try container.decodeIfPresent(Int.self, forKey: .position)
            items = try container.decodeIfPresent([PageItem].self, forKey: .items) ?? []
            totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount) ?? items.count
            previousIndex = try container.decodeIfPresent(Int.self, forKey: .previousIndex)
            nextIndex = try container.decodeIfPresent(Int.self, forKey: .nextIndex)
        }
    }

    /// The previous response's selection, to detect a focus move within one candidate.
    public struct PreviousSelection: Decodable, Sendable {
        public var selection: Int?
        public var focusedNode: Int?

        public init(selection: Int?, focusedNode: Int?) {
            self.selection = selection
            self.focusedNode = focusedNode
        }
    }

    public var inputState: String
    public var preedit: String
    public var reading: String
    public var candidates: [Candidate]
    public var selection: Int?
    public var nodes: [Node]
    public var columns: [[Int]]
    public var selectedPath: [Int]
    public var focusedNode: Int?
    public var candidatePage: Page
    public var showCandidateIndex: Bool
    public var showRelativeScores: Bool
    public var candidateTextSize: Config.CandidateTextSize.Value
    public var previous: PreviousSelection?

    public init(inputState: String, preedit: String, reading: String, candidates: [Candidate], selection: Int?,
                nodes: [Node], columns: [[Int]], selectedPath: [Int], focusedNode: Int?, candidatePage: Page,
                showCandidateIndex: Bool, showRelativeScores: Bool, candidateTextSize: Config.CandidateTextSize.Value,
                previous: PreviousSelection?) {
        self.inputState = inputState
        self.preedit = preedit
        self.reading = reading
        self.candidates = candidates
        self.selection = selection
        self.nodes = nodes
        self.columns = columns
        self.selectedPath = selectedPath
        self.focusedNode = focusedNode
        self.candidatePage = candidatePage
        self.showCandidateIndex = showCandidateIndex
        self.showRelativeScores = showRelativeScores
        self.candidateTextSize = candidateTextSize
        self.previous = previous
    }

    private enum CodingKeys: String, CodingKey {
        case inputState, preedit, reading, candidates, selection, nodes, columns, selectedPath, focusedNode
        case candidatePage, showCandidateIndex, showRelativeScores, candidateTextSize, previous
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputState = try container.decodeIfPresent(String.self, forKey: .inputState) ?? "none"
        preedit = try container.decodeIfPresent(String.self, forKey: .preedit) ?? ""
        reading = try container.decodeIfPresent(String.self, forKey: .reading) ?? ""
        candidates = try container.decodeIfPresent([Candidate].self, forKey: .candidates) ?? []
        selection = try container.decodeIfPresent(Int.self, forKey: .selection)
        nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        columns = try container.decodeIfPresent([[Int]].self, forKey: .columns) ?? []
        selectedPath = try container.decodeIfPresent([Int].self, forKey: .selectedPath) ?? []
        focusedNode = try container.decodeIfPresent(Int.self, forKey: .focusedNode)
        candidatePage = try container.decodeIfPresent(Page.self, forKey: .candidatePage)
            ?? Page(CandidatePage(entries: [], selectionIndex: nil))
        showCandidateIndex = try container.decodeIfPresent(Bool.self, forKey: .showCandidateIndex) ?? false
        showRelativeScores = try container.decodeIfPresent(Bool.self, forKey: .showRelativeScores) ?? false
        candidateTextSize = try container.decodeIfPresent(Config.CandidateTextSize.Value.self, forKey: .candidateTextSize) ?? .standard
        previous = try container.decodeIfPresent(PreviousSelection.self, forKey: .previous)
    }
}
