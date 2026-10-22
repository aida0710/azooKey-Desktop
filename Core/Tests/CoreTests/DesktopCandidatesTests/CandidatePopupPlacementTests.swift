import Core
import Testing

private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CandidateRect {
    .init(x: x, y: y, width: width, height: height)
}

private func place(cursor: CandidateRect, area: CandidateRect, size: (Double, Double),
                   preferredSide: CandidatePopupPlacement.Side? = nil, columnAnchorX: Double? = nil) -> CandidatePopupPlacement? {
    CandidatePopupPlacement.place(.init(
        cursor: cursor, workArea: area, popupSize: .init(width: size.0, height: size.1),
        preferredSide: preferredSide, columnAnchorX: columnAnchorX
    ))
}

private func overlapsCaret(_ placement: CandidatePopupPlacement, _ cursor: CandidateRect) -> Bool {
    placement.x < cursor.x + max(1, cursor.width) && placement.x + placement.width > cursor.x
        && placement.y < cursor.maxY && placement.y + placement.height > cursor.y
}

private func expectSafe(_ placement: CandidatePopupPlacement?, cursor: CandidateRect, area: CandidateRect) throws {
    let placement = try #require(placement)
    #expect(placement.width > 0 && placement.height > 0)
    #expect(placement.x >= area.x && placement.y >= area.y)
    #expect(placement.x + placement.width <= area.maxX && placement.y + placement.height <= area.maxY)
    #expect(!overlapsCaret(placement, cursor))
}

@Test func menuMovesBesideTheCaretWhenNeitherVerticalSideFits() throws {
    let cursor = rect(936, 506, 0, 35), area = rect(0, 32, 1280, 768)
    let placement = place(cursor: cursor, area: area, size: (420, 505), preferredSide: .above)
    try expectSafe(placement, cursor: cursor, area: area)
    #expect(placement?.side == .left)
    #expect(placement?.width == 420 && placement?.height == 505)
}

@Test func cornersZeroWidthCaretsAndOversizedPopupsKeepASafeRegion() throws {
    for area in [rect(0, 32, 1280, 768), rect(-640, 20, 640, 320), rect(0, 0, 320, 320)] {
        for x in [area.x, area.x + area.width / 2, area.maxX] {
            for y in [area.y, area.y + area.height / 2, area.maxY - 35] {
                let cursor = rect(x, y, 0, 35)
                for size in [(240.0, 100.0), (420, 505), (1600, 1200)] {
                    try expectSafe(place(cursor: cursor, area: area, size: size), cursor: cursor, area: area)
                }
            }
        }
    }
}

@Test func constrainedPopupKeepsReadableWidthAndUsesTheLargerVerticalRegion() throws {
    let cursor = rect(320, 142, 0, 35), area = rect(0, 0, 640, 320)
    let placement = place(cursor: cursor, area: area, size: (420, 505))
    try expectSafe(placement, cursor: cursor, area: area)
    #expect(placement?.width == 420 && placement?.height == 143 && placement?.side == .below)
}

@Test func sizeChangesKeepTheUsableSide() throws {
    let cursor = rect(936, 506, 0, 35), area = rect(0, 32, 1280, 768)
    let first = try #require(place(cursor: cursor, area: area, size: (420, 505)))
    let smaller = place(cursor: cursor, area: area, size: (420, 300), preferredSide: first.side)
    #expect(smaller?.side == first.side)
    try expectSafe(smaller, cursor: cursor, area: area)
}

@Test func alignmentAnchorDoesNotReplaceTheRealCaretExclusion() throws {
    let cursor = rect(600, 350, 0, 35), area = rect(0, 32, 1280, 768)
    let placement = place(cursor: cursor, area: area, size: (420, 505), columnAnchorX: 100)
    try expectSafe(placement, cursor: cursor, area: area)
    #expect(placement?.x == 601 && placement?.side == .right)
}

@Test func caretCoveringTheWholeWorkAreaHasNoSafePlacement() {
    #expect(place(cursor: rect(0, 0, 320, 320), area: rect(0, 0, 320, 320), size: (200, 100)) == nil)
}

@Test func fullHeightCaretLeavesItsHorizontalRegionAvailable() throws {
    let cursor = rect(100, 0, 0, 320), area = rect(0, 0, 320, 320)
    let placement = place(cursor: cursor, area: area, size: (420, 505))
    try expectSafe(placement, cursor: cursor, area: area)
    #expect(placement?.width == 219 && placement?.height == 320 && placement?.side == .right)
}

@Test func secondaryMonitorPlacementPrefersBelowThenAboveAndKeepsAStableSide() throws {
    // Former GNOME expectations on a monitor left of the primary one.
    let area = rect(-1280, 32, 1280, 688)
    for cursor in [rect(-1280, 32, 0, 32), rect(-1, 32, 0, 32), rect(-1280, 688, 0, 32), rect(-1, 688, 0, 32)] {
        try expectSafe(place(cursor: cursor, area: area, size: (760, 2560)), cursor: cursor, area: area)
    }
    let below = try #require(place(cursor: rect(-1200, 100, 0, 32), area: area, size: (760, 260)))
    #expect([below.x, below.y] == [-1200, 132] && below.side == .below)
    let above = try #require(place(cursor: rect(-1200, 600, 0, 32), area: area, size: (760, 260)))
    #expect(above.y == 340 && above.side == .above)
    let stable = try #require(place(cursor: rect(-1200, 400, 0, 32), area: area, size: (760, 240), preferredSide: .above))
    #expect(stable.y == 160 && stable.side == .above)
}
