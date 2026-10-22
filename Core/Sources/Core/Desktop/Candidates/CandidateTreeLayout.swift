/// Positions of the tree's word nodes. Platforms measure text with their own
/// fonts and draw these frames; they do not choose sizes or spacing.
public struct CandidateTreeLayout: Codable, Equatable, Sendable {
    /// Why the columns are, or are not, placed under the document's words.
    public enum AlignmentReason: String, Codable, Sendable {
        case estimatedInline = "estimated-inline"
        case unavailableOrNarrow = "unavailable-or-narrow"
        case outsideWorkArea = "outside-workarea"
    }

    public enum TextAlignment: String, Codable, Sendable {
        case leading
        case center
    }

    public struct Node: Codable, Equatable, Sendable {
        public let id: Int
        public let column: Int
        public let row: Int
        /// The pointer/AT target, including the score and number lines.
        public let frame: CandidateRect
        public let textFrame: CandidateRect
        /// The line where a centered score badge is drawn, when scores are shown.
        public let scoreFrame: CandidateRect?
        /// The leading-aligned number badge line, when numbers are shown.
        public let numberFrame: CandidateRect?
    }

    public struct Edge: Codable, Equatable, Sendable {
        /// The node the line leads to; color it as that node's selection state.
        public let node: Int
        public let start: CandidatePoint
        public let end: CandidatePoint
    }

    static let columnStartInset = 12.0
    // Separates compact columns; aligned columns follow the document instead.
    static let columnGap = 12.0
    static let columnTextPadding = 12.0
    // Long alternatives are ellipsized instead of covering the next column.
    static let maximumColumnWidth = 240.0
    static let minimumNodeSize = 44.0
    // Keeps a one-character word readable inside its node.
    static let minimumTextAllowance = 8.0
    static let rowGap = 4.0
    static let topInset = 6.0
    static let bottomInset = 6.0
    static let minimumContentWidth = 60.0
    static let minimumContentHeight = 32.0
    static let rootAnchorX = 4.0
    // Aligned text starts closer to the document word's edge.
    static let alignedTextInset = 2.0
    static let compactTextInset = 4.0
    static let numberHorizontalInset = 6.0

    public let metrics: CandidateTextMetrics
    public let aligned: Bool
    public let reason: AlignmentReason
    public let textAlignment: TextAlignment
    public let rowHeight: Double
    public let nodes: [Node]
    public let edges: [Edge]
    /// The dot before the first column, where root edges start.
    public let rootAnchor: CandidatePoint
    /// The drawing canvas of the tree.
    public let contentSize: CandidateSize
}

extension CandidateTreeLayout {
    struct Input {
        var columns: [CandidateLayoutRequest.Column]
        var columnWidths: [Double]?
        var metrics: CandidateTextMetrics
        var textWidthScale: Double
        var showScores: Bool
        var showNumbers: Bool
        var parents: [Int: Int]
        var reason: AlignmentReason
    }

    static func minimumColumnWidth(_ metrics: CandidateTextMetrics) -> Double {
        max(minimumNodeSize, metrics.fontSize + minimumTextAllowance)
    }

    /// Document word widths are used only when every column has one that is
    /// wide enough for a readable node.
    static func alignedColumnWidths(_ widths: [Double]?, columnCount: Int, metrics: CandidateTextMetrics) -> [Double]? {
        guard let widths, widths.count == columnCount, columnCount > 0,
              widths.allSatisfy({ $0 >= minimumColumnWidth(metrics) }) else {
            return nil
        }
        return widths
    }

    init(_ input: Input) {
        let metrics = input.metrics
        let aligned = input.columnWidths != nil
        let scoreHeight = input.showScores ? metrics.scoreHeight : 0
        let numberHeight = input.showNumbers ? metrics.numberHeight : 0
        let rowHeight = max(Self.minimumNodeSize, metrics.wordHeight + scoreHeight + numberHeight)
        let rowPitch = rowHeight + Self.rowGap
        let textInset = aligned ? Self.alignedTextInset : Self.compactTextInset
        var nodes: [Node] = []
        var x = Self.columnStartInset
        for (columnIndex, column) in input.columns.enumerated() {
            let width = input.columnWidths?[columnIndex] ?? max(Self.minimumColumnWidth(metrics), min(
                Self.maximumColumnWidth, column.textWidth * input.textWidthScale + Self.columnTextPadding))
            for (row, node) in column.nodes.enumerated() {
                let frame = CandidateRect(x: x, y: Self.topInset + Double(row) * rowPitch, width: width, height: rowHeight)
                nodes.append(Node(
                    id: node.id, column: columnIndex, row: row, frame: frame,
                    textFrame: CandidateRect(x: x + textInset, y: frame.y, width: width - textInset * 2, height: metrics.wordHeight),
                    scoreFrame: input.showScores
                        ? CandidateRect(x: x, y: frame.y + metrics.wordHeight, width: width, height: metrics.scoreHeight) : nil,
                    numberFrame: input.showNumbers
                        ? CandidateRect(x: x + Self.numberHorizontalInset, y: frame.maxY - metrics.numberHeight,
                                        width: width - Self.numberHorizontalInset * 2, height: metrics.numberHeight) : nil
                ))
            }
            x += width + (aligned ? 0 : Self.columnGap)
        }
        let rowCount = input.columns.map(\.nodes.count).max() ?? 0
        self.metrics = metrics
        self.aligned = aligned
        self.reason = input.reason
        self.textAlignment = aligned ? .leading : .center
        self.rowHeight = rowHeight
        self.nodes = nodes
        self.rootAnchor = CandidatePoint(x: Self.rootAnchorX, y: Self.topInset + rowHeight / 2)
        self.edges = Self.edges(nodes: nodes, parents: input.parents, rootAnchor: rootAnchor)
        self.contentSize = CandidateSize(
            width: max(Self.minimumContentWidth, x),
            height: max(Self.minimumContentHeight, Double(rowCount) * rowPitch + Self.bottomInset)
        )
    }

    /// A node whose parent is not drawn starts from the root anchor.
    private static func edges(nodes: [Node], parents: [Int: Int], rootAnchor: CandidatePoint) -> [Edge] {
        let frames = Dictionary(nodes.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        return nodes.map { node in
            let start = parents[node.id].flatMap { frames[$0] }
                .map { CandidatePoint(x: $0.maxX, y: $0.y + $0.height / 2) } ?? rootAnchor
            return Edge(node: node.id, start: start,
                        end: CandidatePoint(x: node.frame.x, y: node.frame.y + node.frame.height / 2))
        }
    }
}
