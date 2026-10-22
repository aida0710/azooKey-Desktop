import Core
import Foundation
import Testing

private typealias Column = CandidateLayoutRequest.Column
private typealias Node = CandidateLayoutRequest.Node

private func request(mode: CandidateDisplay.Mode = .list, columns: [Column], cursor: CandidateRect = .init(x: 100, y: 100, width: 1, height: 20),
                     workArea: CandidateRect = .init(x: 0, y: 0, width: 1280, height: 1024)) -> CandidateLayoutRequest {
    CandidateLayoutRequest(mode: mode, textSize: .standard, textScale: 1, measuredFontSize: 18,
                           columns: columns, cursor: cursor, workArea: workArea)
}

/// このように / 確率的に, with a long alternative for the first word.
private let documentColumns = [
    Column(nodes: [Node(id: 0, parent: nil), Node(id: 2, parent: nil)], textWidth: 90),
    Column(nodes: [Node(id: 1, parent: 0)], textWidth: 72)
]

private func frame(_ placement: CandidatePopupPlacement?) -> [Double]? {
    placement.map { [$0.x, $0.y, $0.width, $0.height] }
}

private func frames(_ layout: CandidateLayout) -> [Int: CandidateRect] {
    Dictionary(uniqueKeysWithValues: layout.tree.nodes.map { ($0.id, $0.frame) })
}

@Test func wordColumnsStayUnderDocumentWords() {
    var aligned = request(columns: documentColumns)
    aligned.documentWordWidths = [75, 60]
    aligned.columnAnchorX = 100
    aligned.showScores = true
    aligned.showNumbers = true
    let layout = CandidateLayout(aligned)
    let words = frames(layout)
    #expect(layout.tree.aligned && layout.tree.reason == .estimatedInline)
    #expect(layout.tree.textAlignment == .leading)
    #expect(words[1]!.x - words[0]!.x == 75)
    #expect(words[0]!.x == words[2]!.x)
    // Long alternatives must not cover the next word.
    #expect(words[2]!.width <= 75)
    #expect(words[1]!.height >= 44)
    #expect(layout.placementStatus == .notRequested && layout.placement == nil)

    aligned.columnAnchorX = 2
    let clamped = CandidateLayout(aligned)
    #expect(!clamped.tree.aligned, "Screen-edge clamping must not pretend to retain document coordinates")
    #expect(clamped.tree.reason == .outsideWorkArea)
}

@Test func narrowOrMismatchedDocumentWordsUseCompactColumns() {
    for widths in [[75.0], [75, 20], [75, 60, 40]] {
        var compact = request(columns: documentColumns)
        compact.documentWordWidths = widths
        compact.columnAnchorX = 100
        let layout = CandidateLayout(compact)
        #expect(!layout.tree.aligned && layout.tree.reason == .unavailableOrNarrow)
        #expect(layout.tree.textAlignment == .center)
    }
}

@Test func compactColumnsMeasureTextScaleAndClampTheirWidth() {
    let columns = [Column(nodes: [Node(id: 0, parent: nil)], textWidth: 50),
                   Column(nodes: [Node(id: 1, parent: 0)], textWidth: 600),
                   Column(nodes: [Node(id: 2, parent: 1)], textWidth: 4)]
    let standard = frames(CandidateLayout(request(columns: columns)))
    #expect(standard[0]!.x == 12 && standard[0]!.width == 62)
    #expect(standard[1]!.x == 12 + 62 + 12 && standard[1]!.width == 240)
    #expect(standard[2]!.width == 44)

    var scaled = request(columns: columns)
    scaled.textScale = 2
    let layout = CandidateLayout(scaled)
    #expect(layout.tree.metrics.fontSize == 36)
    // Widths measured at 18px are scaled to the 36px candidate font.
    #expect(frames(layout)[0]!.width == 112)
    #expect(frames(layout)[2]!.width == 44)

    var smallDesktop = request(columns: columns)
    smallDesktop.textScale = 0.8
    #expect(CandidateLayout(smallDesktop).tree.metrics.fontSize == 18, "Candidates never shrink below the setting")
}

@Test func rowsReserveScoreAndNumberLinesInsideEachNode() throws {
    let columns = [Column(nodes: [Node(id: 0, parent: nil), Node(id: 1, parent: nil)], textWidth: 40)]
    let plain = CandidateLayout(request(columns: columns))
    #expect(plain.tree.rowHeight == 44)
    #expect(frames(plain)[1]!.y == 6 + 44 + 4)
    #expect(plain.tree.nodes.allSatisfy { $0.scoreFrame == nil && $0.numberFrame == nil })

    var badges = request(columns: columns)
    badges.showScores = true
    badges.showNumbers = true
    let layout = CandidateLayout(badges)
    let metrics = layout.tree.metrics
    #expect(metrics.fontSize == 18 && metrics.numberFontSize == 12 && metrics.wordHeight == 32)
    #expect(layout.tree.rowHeight == 32 + 16 + 18)
    let node = try #require(layout.tree.nodes.first)
    #expect(node.textFrame == CandidateRect(x: 16, y: 6, width: node.frame.width - 8, height: 32))
    #expect(node.scoreFrame == CandidateRect(x: 12, y: 38, width: node.frame.width, height: 16))
    #expect(node.numberFrame == CandidateRect(x: 18, y: node.frame.maxY - 18, width: node.frame.width - 12, height: 18))
    #expect(layout.tree.contentSize.height == 2 * (66 + 4) + 6)

    var tall = request(columns: columns)
    tall.lineHeight = 30
    tall.textScale = 2
    // A measured 30px line at 18px is 60px at the 36px candidate font.
    #expect(CandidateLayout(tall).tree.metrics.wordHeight == 60)
}

@Test func edgesLeadFromEachDrawnParentOrTheRootAnchor() throws {
    let layout = CandidateLayout(request(columns: documentColumns))
    let words = frames(layout)
    let edges = Dictionary(uniqueKeysWithValues: layout.tree.edges.map { ($0.node, $0) })
    #expect(edges[0]?.start == layout.tree.rootAnchor)
    #expect(edges[2]?.start == layout.tree.rootAnchor)
    #expect(edges[1]?.start == CandidatePoint(x: words[0]!.maxX, y: words[0]!.y + words[0]!.height / 2))
    #expect(edges[1]?.end == CandidatePoint(x: words[1]!.x, y: words[1]!.y + words[1]!.height / 2))
    #expect(layout.tree.rootAnchor == CandidatePoint(x: 4, y: 6 + 22))
}

@Test func popupWidthFollowsTheModeTheTreeAndTheWorkArea() {
    let short = [Column(nodes: [Node(id: 0, parent: nil)], textWidth: 20)]
    #expect(CandidateLayout(request(mode: .tree, columns: short)).popupWidth == 240)
    // 26 full-width characters at 18px.
    #expect(CandidateLayout(request(mode: .list, columns: short)).popupWidth == 468)
    var large = request(mode: .list, columns: short)
    large.textSize = .large
    large.measuredFontSize = 24
    #expect(CandidateLayout(large).popupWidth == 560)
    let wide = (0..<6).map { Column(nodes: [Node(id: $0, parent: $0 == 0 ? nil : $0 - 1)], textWidth: 230) }
    #expect(CandidateLayout(request(mode: .tree, columns: wide)).popupWidth == 760)
    #expect(CandidateLayout(request(mode: .tree, columns: wide, workArea: .init(x: 0, y: 0, width: 320, height: 320))).popupWidth == 320)
}

@Test func placementNeedsTheMeasuredHeightAndReportsAnUnsafeCaret() {
    var layoutRequest = request(mode: .tree, columns: documentColumns)
    layoutRequest.popupHeight = 120
    let placed = CandidateLayout(layoutRequest)
    #expect(placed.placementStatus == .placed)
    #expect(frame(placed.placement) == [100, 120, 240, 120] && placed.placement?.side == .below)

    layoutRequest.cursor = .init(x: 0, y: 0, width: 1280, height: 1024)
    let unavailable = CandidateLayout(layoutRequest)
    #expect(unavailable.placementStatus == .unavailable && unavailable.placement == nil)
}

@Test func sidewaysPlacementGivesUpDocumentAlignment() throws {
    var aligned = request(columns: documentColumns, cursor: .init(x: 600, y: 350, width: 0, height: 35),
                          workArea: .init(x: 0, y: 0, width: 1280, height: 800))
    aligned.documentWordWidths = [75, 60]
    aligned.columnAnchorX = 100
    #expect(CandidateLayout(aligned).tree.aligned)
    aligned.popupHeight = 505
    let layout = CandidateLayout(aligned)
    let placement = try #require(layout.placement)
    #expect(!layout.tree.aligned && layout.tree.reason == .outsideWorkArea)
    #expect(placement.side == .right && placement.x == 601)
}

@Test func layoutRequestAndResponseUseTheDocumentedJSON() throws {
    let json = """
    {"mode":"tree","textSize":"standard","textScale":1,"measuredFontSize":18,
     "columns":[{"nodes":[{"id":0,"parent":null},{"id":2,"parent":null}],"textWidth":54},
                {"nodes":[{"id":1,"parent":0}],"textWidth":72}],
     "documentWordWidths":null,"columnAnchorX":null,"showScores":false,"showNumbers":true,
     "cursor":{"x":300,"y":200,"width":0,"height":24},"workArea":{"x":0,"y":32,"width":1280,"height":768},
     "popupHeight":150,"preferredSide":"below"}
    """
    let decoded = try JSONDecoder().decode(CandidateLayoutRequest.self, from: Data(json.utf8))
    let layout = CandidateLayout(decoded)
    #expect(frame(layout.placement) == [300, 224, 240, 150] && layout.placement?.side == .below)
    let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as? [String: Any])
    #expect(Set(encoded.keys) == ["tree", "popupWidth", "placementStatus", "placement"])
    let tree = try #require(encoded["tree"] as? [String: Any])
    #expect(Set(tree.keys) == ["metrics", "aligned", "reason", "textAlignment", "rowHeight", "nodes", "edges", "rootAnchor", "contentSize"])
}
