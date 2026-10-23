import AppKit
@testable import azooKeyMac
import Core
import XCTest

@MainActor
final class CandidateNumberRenderingTests: XCTestCase {
    func testNumberedCandidatesRenderAtEveryConfiguredTextSize() throws {
        // Leave enough room for the word and its lower-left number at both text sizes.
        let candidateWidth: CGFloat = 120
        for textSize in Config.CandidateTextSize.Value.allCases {
            let fontSize = CGFloat(CandidateTextMetrics.baseFontSize(textSize))
            let button = TreeButton(frame: NSRect(
                x: 0, y: 0, width: candidateWidth, height: TreeButton.preferredHeight(fontSize: fontSize, hasNumber: true)
            ))
            button.font = .systemFont(ofSize: fontSize)
            button.title = "日本語"
            for number in ["1", "8", "9"] {
                button.candidateNumber = number
                let badge = try XCTUnwrap(button.numberBadgeFrame)
                XCTAssertGreaterThan(badge.width, 0)
                XCTAssertTrue(button.bounds.contains(badge))
                let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
                button.cacheDisplay(in: button.bounds, to: bitmap)
                XCTAssertNotNil(bitmap.representation(using: .png, properties: [:]))
            }
        }
    }
}
