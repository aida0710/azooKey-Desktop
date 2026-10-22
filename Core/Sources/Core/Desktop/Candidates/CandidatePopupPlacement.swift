/// Keeps the candidate popup inside the work area without covering the caret.
public struct CandidatePopupPlacement: Codable, Equatable, Sendable {
    public enum Side: String, Codable, CaseIterable, Sendable {
        case below, above, right, left

        var isVertical: Bool {
            self == .below || self == .above
        }
    }

    public struct Request: Sendable {
        public var cursor: CandidateRect
        public var workArea: CandidateRect
        public var popupSize: CandidateSize
        /// Keeps a side that still fits while candidates change or scroll.
        public var preferredSide: Side?
        /// The x coordinate of the composition start for document-aligned columns.
        public var columnAnchorX: Double?

        public init(cursor: CandidateRect, workArea: CandidateRect, popupSize: CandidateSize,
                    preferredSide: Side? = nil, columnAnchorX: Double? = nil) {
            self.cursor = cursor
            self.workArea = workArea
            self.popupSize = popupSize
            self.preferredSide = preferredSide
            self.columnAnchorX = columnAnchorX
        }
    }

    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let side: Side

    /// - Returns: nil when the caret covers the whole work area and no region
    ///   beside it is left for the popup.
    public static func place(_ request: Request) -> CandidatePopupPlacement? {
        let area = request.workArea
        let cursor = request.cursor
        // IBus commonly reports a zero-width insertion caret. Leave its pixel clear.
        let cursorRight = cursor.x + max(1, cursor.width)
        let spaces: [Side: Double] = [
            .below: max(0, area.maxY - max(area.y, cursor.maxY)),
            .above: max(0, min(area.maxY, cursor.y) - area.y),
            .right: max(0, area.maxX - max(area.x, cursorRight)),
            .left: max(0, min(area.maxX, cursor.x) - area.x)
        ]
        var width = min(request.popupSize.width, area.width)
        var height = min(request.popupSize.height, area.height)
        let fitting = Side.allCases.filter { ($0.isVertical ? height : width) <= spaces[$0, default: 0] }
        let side: Side
        if let first = fitting.first {
            side = request.preferredSide.flatMap { fitting.contains($0) ? $0 : nil } ?? first
        } else {
            // Preserve readable line width first. A bounded viewport keeps even
            // the confirmation controls reachable when their height does not fit.
            let vertical = larger(of: .below, .above, spaces: spaces)
            if spaces[vertical, default: 0] > 0 {
                side = vertical
                height = spaces[vertical, default: 0]
            } else {
                side = larger(of: .right, .left, spaces: spaces)
                width = spaces[side, default: 0]
            }
        }
        guard width > 0, height > 0 else {
            return nil
        }
        let desiredX = request.columnAnchorX.map { $0 - CandidateTreeLayout.columnStartInset } ?? cursor.x
        var x = max(area.x, min(desiredX, area.maxX - width))
        var y = max(area.y, min(cursor.y, area.maxY - height))
        switch side {
        case .below: y = max(area.y, cursor.maxY)
        case .above: y = min(area.maxY, cursor.y) - height
        case .right: x = max(area.x, cursorRight)
        case .left: x = min(area.maxX, cursor.x) - width
        }
        // Whole logical pixels; truncating toward zero keeps negative monitor origins stable.
        return CandidatePopupPlacement(x: x.rounded(.towardZero), y: y.rounded(.towardZero),
                                       width: width.rounded(.towardZero), height: height.rounded(.towardZero), side: side)
    }

    /// Ties keep the first side, matching the order of preference.
    private static func larger(of first: Side, _ second: Side, spaces: [Side: Double]) -> Side {
        spaces[second, default: 0] > spaces[first, default: 0] ? second : first
    }
}
