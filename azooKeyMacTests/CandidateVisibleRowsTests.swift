import AppKit
import Core
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

@testable import azooKeyMac

@MainActor
final class CandidateVisibleRowsTests: XCTestCase {
    func testChangingTheSettingResizesTheSameMenuAndKeepsItsSelectedNinthCandidateVisible() throws {
        let preference = Config.CandidateVisibleRows()
        let oldCount = preference.value
        let fontPreference = Config.CandidateTextSize()
        let oldSize = fontPreference.value
        defer {
            preference.value = oldCount
            fontPreference.value = oldSize
        }
        let view = CandidateTreeView()
        let entries = (0..<20).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0 + 40) }
        for size in [Config.CandidateTextSize.Value.standard, .large] {
            fontPreference.value = size
            for count in [Config.CandidateVisibleRows.Value.nine, .five, .seven] {
                preference.value = count
                view.update(entries: entries, selectionIndex: 48, numbers: [48: "9"], enterConfirmsCandidate: true)
                view.frame = NSRect(origin: .zero, size: view.preferredSize)
                view.layoutSubtreeIfNeeded()
                let list = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateNavigationView }.first)
                let scroll = try XCTUnwrap(list.subviews.compactMap { $0 as? NSScrollView }.first)
                let rows = candidateViewDescendants(in: list).compactMap { $0 as? CandidateRowButton }
                let ninth = try XCTUnwrap(rows.first { $0.candidateIndex == 48 })
                XCTAssertEqual(rows.count, 9)
                XCTAssertEqual(ninth.title, "9. 候補8")
                XCTAssertEqual(ninth.font?.pointSize, CGFloat(size.pointSize))
                XCTAssertEqual(scroll.contentSize.height, ninth.frame.height * CGFloat(count.rawValue), accuracy: 0.01)
                XCTAssertTrue(scroll.documentVisibleRect.contains(ninth.frame))
                XCTAssertTrue(ninth.isAccessibilitySelected())
                XCTAssertFalse(ninth.acceptsFirstResponder)
            }
        }
    }

    func testVisibleRowSettingsKeepPhysicalNumbersOnTheOriginalNineCandidatePage() throws {
        let preference = Config.CandidateVisibleRows()
        let previous = preference.value
        let treePreference = Config.TreeCandidates()
        let previousTree = treePreference.value
        defer {
            preference.value = previous
            treePreference.value = previousTree
        }
        treePreference.value = true
        let controller = CandidatesViewController()
        controller.showCandidateIndex = true
        _ = controller.view
        let candidates = (0..<20).map {
            CandidatePresentation(candidate: Candidate(text: "候補\($0)", value: 0,
                                                       composingCount: .surfaceCount(0), lastMid: 0, data: []))
        }
        for count in Config.CandidateVisibleRows.Value.allCases {
            preference.value = count
            controller.updateCandidatePresentations(candidates, selectionIndex: 8, cursorLocation: .zero,
                                                    enterConfirmsCandidate: true)
            XCTAssertEqual(controller.getNumberCandidate(num: 1), 0)
            XCTAssertEqual(controller.getNumberCandidate(num: 9), 8)
            XCTAssertTrue(controller.showCandidateIndex)
            XCTAssertEqual(controller.currentSelectedRow, 8)
            controller.selectNextCandidate()
            XCTAssertEqual(controller.getNumberCandidate(num: 1), 9)
            XCTAssertEqual(controller.getNumberCandidate(num: 9), 17)
            XCTAssertEqual(controller.currentSelectedRow, 9)
        }
    }

    func testFlatPagingAndConfirmButtonsLeaveTheirBackgroundTransparent() throws {
        let button = CandidatePresentationButton()
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        button.title = "‹"
        button.primary = true
        for flat in [false, true] {
            button.isFlat = flat
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            let edge = try XCTUnwrap(bitmap.colorAt(x: 3, y: bitmap.pixelsHigh / 2))
            XCTAssertEqual(edge.alphaComponent, flat ? 0 : 1, accuracy: 0.01)
            XCTAssertFalse(button.acceptsFirstResponder)
        }
    }
}
