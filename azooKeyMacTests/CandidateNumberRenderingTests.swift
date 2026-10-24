import AppKit
@testable import azooKeyMac
import Core
import XCTest

@MainActor
final class CandidateNumberRenderingTests: XCTestCase {
    func testListNumbersRenderAtEveryConfiguredTextSize() throws {
        let page = CandidatePage(entries: [.init(text: "日本語", tokens: [], candidateIndex: 0)], selectionIndex: 0)
        for textSize in Config.CandidateTextSize.Value.allCases {
            for number in ["1", "8", "9"] {
                let row = CandidateRowButton(item: try XCTUnwrap(page.items.first), number: number,
                                             fontSize: MacCandidateMetrics.fontSize(textSize))
                row.frame = NSRect(x: 0, y: 0, width: 160, height: row.preferredHeight(width: 160))
                let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
                row.cacheDisplay(in: row.bounds, to: bitmap)
                XCTAssertNotNil(bitmap.representation(using: .png, properties: [:]))
                XCTAssertEqual(row.title, "\(number). 日本語")
            }
        }
    }
}
