import AppKit
import Core
import XCTest

@testable import azooKeyMac

@MainActor
final class WordDefinitionsSideViewTests: XCTestCase {
    private let target = WordDefinitionsModel.Target(generation: 1, candidateIndex: 42, nodeID: 3, word: "橋", reading: "ハシ")

    func testLoadingMissingAndEmptyDefinitionsHideTheEntireCardAndRetireItsAction() throws {
        let side = WordDefinitionsSideView(frame: .zero)
        for response: WordDefinitionsModel.Result in [.loading, .notFound, .definition(" \n\t")] {
            side.update(target: target, result: .definition("橋の説明"), fontSize: 18)
            let oldButton = try button(in: side)
            let oldAction = try XCTUnwrap(oldButton.activate)
            side.update(target: target, result: response, fontSize: 18)
            withExtendedLifetime(oldButton) { oldAction() }
            XCTAssertTrue(side.isHidden)
            XCTAssertFalse(side.expanded)
            XCTAssertFalse(try button(in: side).isEnabled)
        }
    }

    func testFullEntryAndSourceRemainReadableWithoutTakingTheDocumentFocus() throws {
        let side = WordDefinitionsSideView(frame: .zero)
        let definition = "語釈と用例\n" + String(repeating: "長い辞典の説明。", count: 100)
        for fontSize: CGFloat in [18, 24] {
            side.update(target: target, result: .definition(definition), fontSize: fontSize)
            let toggle = try button(in: side)
            if !side.expanded { toggle.activate?() }
            side.frame = NSRect(x: 0, y: 0, width: 280, height: side.preferredHeight)
            side.layoutSubtreeIfNeeded()
            let labels = candidateViewDescendants(in: side).compactMap { $0 as? NSTextField }
            let body = try XCTUnwrap(labels.first { $0.stringValue.contains(definition) })
            XCTAssertTrue(body.stringValue.contains(Localization.text("candidate.definition.readingNote")))
            XCTAssertTrue(labels.contains { $0.stringValue == Localization.text("candidate.definition.source") })
            XCTAssertTrue(labels.allSatisfy { !$0.isSelectable })
            XCTAssertEqual((body.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, fontSize)
            XCTAssertEqual(toggle.frame.height, 44)
            XCTAssertFalse(side.acceptsFirstResponder)
            XCTAssertFalse(toggle.acceptsFirstResponder)
            assertSubviewsFit(in: side)
        }
        let panel = CandidateTreePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: true)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    func testOldDisclosureCannotExpandANewerWordOrAHiddenDefinition() throws {
        let side = WordDefinitionsSideView(frame: .zero)
        side.update(target: target, result: .definition("橋の説明"), fontSize: 18)
        let oldButton = try button(in: side)
        let oldAction = try XCTUnwrap(oldButton.activate)
        let next = WordDefinitionsModel.Target(generation: 2, candidateIndex: 7, nodeID: 1, word: "箸", reading: "ハシ")
        side.update(target: next, result: .definition("箸の説明"), fontSize: 18)
        withExtendedLifetime(oldButton) { oldAction() }
        XCTAssertFalse(side.expanded)
        let hiddenButton = try button(in: side)
        let hiddenAction = try XCTUnwrap(hiddenButton.activate)
        side.update(target: nil, result: nil, fontSize: 18)
        withExtendedLifetime(hiddenButton) { hiddenAction() }
        XCTAssertTrue(side.isHidden)
        XCTAssertFalse(side.expanded)
    }

    func testSameWordRedrawPreservesExpansionAndScrollWhileANewWordStartsWithItsSummary() throws {
        let side = WordDefinitionsSideView(frame: .zero)
        let definition = String(repeating: "長い辞典の説明。\n", count: 100)
        side.update(target: target, result: .definition(definition), fontSize: 18)
        try button(in: side).activate?()
        side.frame = NSRect(x: 0, y: 0, width: 280, height: side.preferredHeight)
        side.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(side.subviews.compactMap { $0 as? CandidateDetailView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 29))
        side.update(target: target, result: .definition(definition), fontSize: 18)
        side.layoutSubtreeIfNeeded()
        XCTAssertTrue(side.expanded)
        XCTAssertEqual(scroll.contentView.bounds.minY, 29)
        let next = WordDefinitionsModel.Target(generation: 1, candidateIndex: 7, nodeID: 1, word: "箸", reading: "ハシ")
        side.update(target: next, result: .loading, fontSize: 18)
        XCTAssertFalse(side.expanded)
        XCTAssertFalse(try button(in: side).isEnabled)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
    }

    func testSmallAllocationsStayInsideTheirBoundsAndNeverShrinkTheDictionaryFont() throws {
        let side = WordDefinitionsSideView(frame: .zero)
        for fontSize: CGFloat in [18, 24] {
            side.update(target: target, result: .definition("現在の語の説明"), fontSize: fontSize)
            for height in [CGFloat.zero, 12, 20, 80, side.preferredHeight] {
                side.frame = NSRect(x: 0, y: 0, width: 280, height: height)
                side.layoutSubtreeIfNeeded()
                assertSubviewsFit(in: side)
                let title = try XCTUnwrap(side.subviews.compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == fontSize })
                XCTAssertEqual(title.font?.pointSize, fontSize)
            }
        }
    }

    func testShortMeaningIsASmallIndependentCardAndOnlyExplicitDetailsUseTheFullHeight() throws {
        let side = WordDefinitionsSideView(frame: .zero)
        for fontSize: CGFloat in [18, 24] {
            side.update(target: target, result: .definition(String(repeating: "語の意味。", count: 100)), fontSize: fontSize)
            if side.expanded { try button(in: side).activate?() }
            XCTAssertLessThanOrEqual(side.preferredHeight, 190)
            let toggle = try button(in: side)
            toggle.activate?()
            XCTAssertGreaterThanOrEqual(side.preferredHeight, 280)
            XCTAssertLessThanOrEqual(side.preferredHeight, 340)
            side.frame = NSRect(x: 0, y: 0, width: 280, height: side.preferredHeight)
            side.layoutSubtreeIfNeeded()
            XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
            XCTAssertLessThan(toggle.frame.width, 280)
            assertSubviewsFit(in: side)
        }
    }

    private func button(in side: WordDefinitionsSideView) throws -> CandidatePresentationButton {
        try XCTUnwrap(side.subviews.compactMap { $0 as? CandidatePresentationButton }.first)
    }

    private func assertSubviewsFit(in side: WordDefinitionsSideView) {
        for view in side.subviews {
            XCTAssertGreaterThanOrEqual(view.frame.minX, side.bounds.minX)
            XCTAssertGreaterThanOrEqual(view.frame.minY, side.bounds.minY)
            XCTAssertLessThanOrEqual(view.frame.maxX, side.bounds.maxX)
            XCTAssertLessThanOrEqual(view.frame.maxY, side.bounds.maxY)
        }
    }
}
