import AppKit
@testable import azooKeyMac
import Core
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

@MainActor
final class CandidateTextSizeTests: XCTestCase {
    func testPredictionTextAndLayoutFollowTheSizeSettingWithoutChangingSelectionEmphasis() throws {
        let preference = Config.CandidateTextSize()
        let previous = preference.value
        defer { preference.value = previous }
        let words = ["予測候補👩‍💻ABC", "次の予測候補"]
        let presentations = words.map {
            CandidatePresentation(candidate: Candidate(text: $0, value: 0,
                composingCount: .surfaceCount(0), lastMid: 0, data: []))
        }
        let controller = PredictionCandidatesViewController()
        _ = controller.view
        var previousWidth: CGFloat?
        var previousRowHeight: CGFloat?

        for size in [Config.CandidateTextSize.Value.standard, .large] {
            let expectedPoints = CGFloat(CandidateTextMetrics.baseFontSize(size))
            preference.value = size
            controller.updateCandidatePresentations(presentations, selectionIndex: 0, cursorLocation: .zero)
            let width = controller.getWindowWidth(maxContentWidth: controller.getMaxTextWidth(candidates: words))
            for (row, word) in words.enumerated() {
                let cell = try XCTUnwrap(controller.tableView(controller.tableView,
                    viewFor: controller.tableView.tableColumns.first, row: row) as? CandidateTableCellView)
                let attributedText = cell.candidateTextField.attributedStringValue
                let range = (attributedText.string as NSString).range(of: word)
                XCTAssertNotEqual(range.location, NSNotFound)
                guard range.location != NSNotFound else { continue }
                let font = try XCTUnwrap(attributedText.attribute(.font, at: range.location,
                    effectiveRange: nil) as? NSFont)
                XCTAssertEqual(font.pointSize, expectedPoints)
                XCTAssertEqual(cell.candidateTextField.font?.pointSize, expectedPoints)
                XCTAssertGreaterThan(controller.tableView.rowHeight, font.ascender - font.descender)
                XCTAssertGreaterThanOrEqual(width, attributedText.size().width)
                XCTAssertEqual(attributedText.attribute(.foregroundColor, at: range.location,
                    effectiveRange: nil) as? NSColor, row == 0 ? .white : .labelColor)
                XCTAssertEqual(controller.currentSelectedRow, 0)
            }
            if let previousWidth, let previousRowHeight {
                XCTAssertGreaterThan(width, previousWidth)
                XCTAssertGreaterThan(controller.tableView.rowHeight, previousRowHeight)
            }
            previousWidth = width
            previousRowHeight = controller.tableView.rowHeight
        }
    }
}
