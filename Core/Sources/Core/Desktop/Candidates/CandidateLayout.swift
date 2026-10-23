/// Input of the `candidate-layout` bridge operation. All lengths are logical
/// pixels (96 dpi); platforms convert device pixels before and after.
public struct CandidateLayoutRequest: Codable, Sendable {
    public struct Node: Codable, Sendable {
        public var id: Int
        public var parent: Int?

        public init(id: Int, parent: Int?) {
            self.id = id
            self.parent = parent
        }
    }

    public struct Column: Codable, Sendable {
        /// Nodes from top to bottom, as in `candidateDisplay.columns`.
        public var nodes: [Node]
        /// Width of the column's first node text measured at `measuredFontSize`.
        public var textWidth: Double

        public init(nodes: [Node], textWidth: Double) {
            self.nodes = nodes
            self.textWidth = textWidth
        }
    }

    /// `list` when the full-sentence card is shown, `tree` for the tree alone.
    public var mode: CandidateDisplay.Mode
    public var textSize: Config.CandidateTextSize.Value
    public var textScale: Double
    /// Font size used to measure `textWidth` and `lineHeight`. Core scales
    /// them to the candidate font size, so platforms can measure before layout.
    public var measuredFontSize: Double
    /// One measured line of candidate text, including any border the platform
    /// draws inside a node. Word lines keep at least this ratio.
    public var lineHeight: Double?
    public var columns: [Column]
    /// Widths of the document's words under the composition, when known.
    public var documentWordWidths: [Double]?
    /// The x coordinate where the composition starts in the document.
    public var columnAnchorX: Double?
    public var showScores: Bool
    /// The real insertion caret, which the popup must never cover.
    public var cursor: CandidateRect
    public var workArea: CandidateRect
    /// The popup height measured at the returned `popupWidth`. Placement is
    /// computed only when this is present.
    public var popupHeight: Double?
    public var preferredSide: CandidatePopupPlacement.Side?

    public init(mode: CandidateDisplay.Mode, textSize: Config.CandidateTextSize.Value, textScale: Double,
                measuredFontSize: Double, columns: [Column], cursor: CandidateRect, workArea: CandidateRect) {
        self.mode = mode
        self.textSize = textSize
        self.textScale = textScale
        self.measuredFontSize = measuredFontSize
        self.columns = columns
        self.showScores = false
        self.cursor = cursor
        self.workArea = workArea
    }
}

/// Output of the `candidate-layout` bridge operation.
public struct CandidateLayout: Codable, Equatable, Sendable {
    public enum PlacementStatus: String, Codable, Sendable {
        /// No `popupHeight` was given; measure the popup at `popupWidth` first.
        case notRequested
        case placed
        /// The caret leaves no safe region; hide the popup.
        case unavailable
    }

    // The live tree has no permanent full-sentence list beside it.
    static let minimumTreeOnlyWidth = 185.0
    // Leaves room for readable sentences and the list's footer.
    static let minimumListWidth = 320.0
    // Wide enough for about this many full-width characters of a sentence.
    static let listLineCharacters = 26.0
    static let maximumListLineWidth = 430.0
    static let maximumCompactWidth = 585.0

    public let tree: CandidateTreeLayout
    /// Width at which the platform measures the rest of the popup.
    public let popupWidth: Double
    public let placementStatus: PlacementStatus
    public let placement: CandidatePopupPlacement?

    public init(_ request: CandidateLayoutRequest) {
        var tree = Self.tree(request, allowAlignment: true)
        guard let popupHeight = request.popupHeight else {
            self.init(tree: tree, popupWidth: Self.popupWidth(request, tree: tree), placement: nil, requested: false)
            return
        }
        var popupWidth = Self.popupWidth(request, tree: tree)
        var placement = Self.place(request, tree: tree, popupSize: CandidateSize(width: popupWidth, height: popupHeight))
        if tree.aligned, let side = placement?.side, !side.isVertical {
            // A sideways popup no longer follows the document's word positions.
            tree = Self.tree(request, allowAlignment: false)
            popupWidth = Self.popupWidth(request, tree: tree)
            placement = Self.place(request, tree: tree, popupSize: CandidateSize(width: popupWidth, height: popupHeight))
        }
        self.init(tree: tree, popupWidth: popupWidth, placement: placement, requested: true)
    }

    private init(tree: CandidateTreeLayout, popupWidth: Double, placement: CandidatePopupPlacement?, requested: Bool) {
        self.tree = tree
        self.popupWidth = popupWidth
        self.placement = placement
        self.placementStatus = !requested ? .notRequested : placement == nil ? .unavailable : .placed
    }

    private static func tree(_ request: CandidateLayoutRequest, allowAlignment: Bool) -> CandidateTreeLayout {
        let measurementScale = measurementScale(request)
        let metrics = CandidateTextMetrics(
            textSize: request.textSize, textScale: request.textScale,
            lineHeightRatio: request.lineHeight.flatMap { request.measuredFontSize > 0 ? $0 / request.measuredFontSize : nil }
        )
        var input = CandidateTreeLayout.Input(
            columns: request.columns, columnWidths: nil, metrics: metrics, textWidthScale: measurementScale,
            showScores: request.showScores,
            parents: parents(request.columns), reason: .unavailableOrNarrow
        )
        guard allowAlignment, request.columnAnchorX != nil,
              let widths = CandidateTreeLayout.alignedColumnWidths(
                request.documentWordWidths, columnCount: request.columns.count, metrics: metrics) else {
            input.reason = allowAlignment ? .unavailableOrNarrow : .outsideWorkArea
            return CandidateTreeLayout(input)
        }
        input.columnWidths = widths
        input.reason = .estimatedInline
        let aligned = CandidateTreeLayout(input)
        guard fitsAligned(request, tree: aligned) else {
            // Clamping or scrolling would invalidate the document coordinates.
            input.columnWidths = nil
            input.reason = .outsideWorkArea
            return CandidateTreeLayout(input)
        }
        return aligned
    }

    /// Text widths scale linearly with the font size they were measured at.
    private static func measurementScale(_ request: CandidateLayoutRequest) -> Double {
        let fontSize = CandidateTextMetrics.fontSize(textSize: request.textSize, textScale: request.textScale)
        return request.measuredFontSize > 0 ? fontSize / request.measuredFontSize : 1
    }

    private static func parents(_ columns: [CandidateLayoutRequest.Column]) -> [Int: Int] {
        var parents: [Int: Int] = [:]
        for node in columns.flatMap(\.nodes) {
            parents[node.id] = node.parent
        }
        return parents
    }

    private static func minimumPopupWidth(_ request: CandidateLayoutRequest) -> Double {
        request.mode == .list ? minimumListWidth : minimumTreeOnlyWidth
    }

    private static func fitsAligned(_ request: CandidateLayoutRequest, tree: CandidateTreeLayout) -> Bool {
        guard let anchorX = request.columnAnchorX else {
            return false
        }
        let left = anchorX - CandidateTreeLayout.columnStartInset
        return left >= request.workArea.x && left + unclampedPopupWidth(request, tree: tree) <= request.workArea.maxX
    }

    private static func unclampedPopupWidth(_ request: CandidateLayoutRequest, tree: CandidateTreeLayout) -> Double {
        var width = max(minimumPopupWidth(request), tree.contentSize.width)
        if request.mode == .list {
            width = max(width, min(maximumListLineWidth, tree.metrics.fontSize * listLineCharacters))
        }
        return tree.aligned ? width : min(maximumCompactWidth, width)
    }

    private static func popupWidth(_ request: CandidateLayoutRequest, tree: CandidateTreeLayout) -> Double {
        min(unclampedPopupWidth(request, tree: tree), request.workArea.width).rounded()
    }

    private static func place(_ request: CandidateLayoutRequest, tree: CandidateTreeLayout,
                              popupSize: CandidateSize) -> CandidatePopupPlacement? {
        CandidatePopupPlacement.place(.init(
            cursor: request.cursor, workArea: request.workArea, popupSize: popupSize,
            preferredSide: request.preferredSide, columnAnchorX: tree.aligned ? request.columnAnchorX : nil
        ))
    }
}
