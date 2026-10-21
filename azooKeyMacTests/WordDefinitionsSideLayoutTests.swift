import Core
import Foundation
import XCTest

@testable import azooKeyMac

final class WordDefinitionsSideLayoutTests: XCTestCase {
    func testWideAndNarrowViewportsKeepDefinitionsToTheRightOfReadableCandidates() {
        for width: CGFloat in [1200, 800, 640, 320] {
            let layout = WordDefinitionsSideLayout(availableWidth: width, preferredLeftWidth: 760,
                                                   showsDefinitions: true, compactMenu: true)
            XCTAssertEqual(layout.leftWidth, 260)
            XCTAssertEqual(layout.definitionWidth, 280)
            XCTAssertEqual(layout.contentWidth, layout.leftWidth + 10 + layout.definitionWidth)
            XCTAssertLessThanOrEqual(layout.viewportWidth, width)
            let left = WordDefinitionsSideLayout.LeftHeights(navigation: 260, tree: 180, details: 160, actions: 54)
            let frames = layout.frames(height: max(left.total, 360), left: left, definitionHeight: 360)
            XCTAssertEqual(frames.definitions.minX, frames.navigation.maxX + 10)
            XCTAssertEqual(frames.definitions.maxY, frames.navigation.maxY)
            XCTAssertEqual(frames.definitions.height, 360)
            if width < 550 { XCTAssertGreaterThan(layout.contentWidth, layout.viewportWidth) }
        }
    }

    func testShortBodyKeepsBothColumnsWithinBoundsAndReservesTheExistingActions() {
        let layout = WordDefinitionsSideLayout(availableWidth: 320, preferredLeftWidth: 480, showsDefinitions: true, compactMenu: true)
        let left = WordDefinitionsSideLayout.LeftHeights(navigation: 260, tree: 220, details: 160, actions: 54, minimumNavigation: 102)
        for height: CGFloat in [0, 20, 160, 320] {
            let frames = layout.frames(height: height, left: left, definitionHeight: 360)
            let bounds = CGRect(x: 0, y: 0, width: layout.contentWidth, height: height)
            for frame in [frames.navigation, frames.tree, frames.details, frames.actions, frames.definitions] {
                XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX)
                XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY)
                XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX)
                XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY)
            }
            XCTAssertEqual(frames.actions.height, min(height, left.actions))
            XCTAssertEqual(frames.definitions.maxY, height)
            if height >= left.actions + left.minimumNavigation {
                XCTAssertGreaterThanOrEqual(frames.navigation.height, left.minimumNavigation)
            }
        }
    }

    func testDefinitionVisibilityAndHeightNeverStretchTheCandidateCard() {
        for fontSize: CGFloat in [18, 24] {
            let shown = WordDefinitionsSideLayout(availableWidth: 1000, preferredLeftWidth: 480,
                                                  showsDefinitions: true, compactMenu: true, fontSize: fontSize)
            let hidden = WordDefinitionsSideLayout(availableWidth: 1000, preferredLeftWidth: 480,
                                                   showsDefinitions: false, compactMenu: true, fontSize: fontSize)
            XCTAssertEqual(shown.leftWidth, hidden.leftWidth)
            XCTAssertGreaterThanOrEqual(shown.leftWidth, 260)
            let left = WordDefinitionsSideLayout.LeftHeights(navigation: 228, tree: 0, details: 0, actions: 52)
            let short = shown.frames(height: 280, left: left, definitionHeight: 165)
            let full = shown.frames(height: 330, left: left, definitionHeight: 330)
            XCTAssertEqual(short.candidateCard.size, full.candidateCard.size)
            XCTAssertEqual(short.navigation.size, full.navigation.size)
            XCTAssertEqual(short.actions.size, full.actions.size)
            XCTAssertEqual(short.candidateCard.maxY, 280)
            XCTAssertEqual(full.candidateCard.maxY, 330)
        }
    }

    func testPointerMustUseTheCurrentWordToDefinitionRouteInsideTheViewport() {
        let source = CGRect(x: 8, y: 200, width: 464, height: 44)
        let definition = CGRect(x: 490, y: 100, width: 360, height: 300)
        let viewport = CGRect(x: 0, y: 0, width: 850, height: 500)
        for point in [CGPoint(x: 470, y: 220), CGPoint(x: 480, y: 220), CGPoint(x: 600, y: 220)] {
            XCTAssertTrue(WordDefinitionsSideLayout.retainsHover(at: point, source: source,
                                                               definitions: definition, viewport: viewport))
        }
        for point in [CGPoint(x: 200, y: 180), CGPoint(x: 480, y: 450), CGPoint(x: 900, y: 220)] {
            XCTAssertFalse(WordDefinitionsSideLayout.retainsHover(at: point, source: source,
                                                                definitions: definition, viewport: viewport))
        }
        XCTAssertFalse(WordDefinitionsSideLayout.retainsHover(at: CGPoint(x: 300, y: 220), source: source,
                                                            definitions: definition,
                                                            viewport: CGRect(x: 0, y: 0, width: 320, height: 500)))
    }

    func testTheCombinedPopupStaysInTheWorkAreaAtTheRightEdge() {
        for originX: Double in [0, -1200] {
            let layout = WordDefinitionsSideLayout(availableWidth: 1200, preferredLeftWidth: 480, showsDefinitions: true)
            let frame = WindowPositioning.frameNearCursor(
                currentFrame: .init(origin: .init(x: 0, y: 0), size: .init(width: 1, height: 1)),
                screenRect: .init(origin: .init(x: originX, y: 0), size: .init(width: 1200, height: 800)),
                cursorLocation: .init(x: originX + 1180, y: 400),
                desiredSize: .init(width: Double(layout.viewportWidth), height: 400)
            )
            XCTAssertGreaterThanOrEqual(frame.minX, originX)
            XCTAssertLessThanOrEqual(frame.maxX, originX + 1200)
            XCTAssertEqual(frame.maxX, originX + 1200)
        }
    }
}
