import Cocoa
import XCTest

@MainActor
final class DocumentTextInputTests: XCTestCase {
    private var client: DocumentTextInput!
    private var textView: NSTextView!
    private let noReplacement = NSRange(location: NSNotFound, length: 0)
    private let noSelection = NSRange(location: NSNotFound, length: NSNotFound)

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        client = DocumentTextInput()
        textView = NSTextView(frame: .zero)
        textView.isRichText = false
        textView.string = client.document
        textView.setSelectedRange(client.selection)
    }

    override func tearDown() {
        client = nil
        textView = nil
        super.tearDown()
    }

    private func assertMatchesTextView(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(client.document, textView.string, file: file, line: line)
        XCTAssertEqual(client.selectedRange(), textView.selectedRange(), file: file, line: line)
        let markedRange = client.markedRange()
        XCTAssertEqual(
            markedRange.location != NSNotFound && markedRange.length > 0,
            textView.hasMarkedText(), file: file, line: line
        )
        if textView.hasMarkedText() {
            XCTAssertEqual(markedRange, textView.markedRange(), file: file, line: line)
        } else {
            // NSTextView may report an empty range at the document end; the fixture uses the protocol sentinel.
            XCTAssertEqual(markedRange, noReplacement, file: file, line: line)
        }
    }

    private func mark(_ text: String, selection: NSRange) {
        let markedText = NSAttributedString(string: text)
        client.setMarkedText(markedText, selectionRange: selection, replacementRange: noReplacement)
        textView.setMarkedText(markedText, selectedRange: selection, replacementRange: noReplacement)
        assertMatchesTextView()
    }

    func testMissingSelectionDuringPreviewMovesTheInsertionPointToTheNativeDocumentEnd() {
        mark("にほんご", selection: noSelection)
        XCTAssertEqual(client.document, "前にほんご後")
        XCTAssertEqual(client.selectedRange(), NSRange(location: 6, length: 0))
        mark("日本語", selection: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(client.document, "前日本語後")
        XCTAssertEqual(client.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testClearingAPreviewWithMissingSelectionMovesTheNextInputToTheNativeDocumentEnd() {
        mark("日本語", selection: NSRange(location: 3, length: 0))
        mark("にほんご", selection: noSelection)
        mark("", selection: noSelection)
        mark("あ", selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(client.document, "前後あ")
    }

    func testAnEmptyRefreshWithMissingSelectionMovesTheNextInputToTheNativeDocumentEnd() {
        client.insertText("日本語", replacementRange: noReplacement)
        textView.insertText("日本語", replacementRange: noReplacement)
        assertMatchesTextView()
        mark("", selection: noSelection)
        mark("あ", selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(client.document, "前日本語後あ")
    }

    func testClearingAPreviewWithExplicitSelectionKeepsTheNextInputBeforeTheSuffix() {
        mark("日本語", selection: NSRange(location: 3, length: 0))
        mark("にほんご", selection: NSRange(location: 4, length: 0))
        mark("", selection: NSRange(location: 0, length: 0))
        mark("あ", selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(client.document, "前あ後")
    }

    func testAnEmptyRefreshWithExplicitSelectionKeepsTheNextInputAfterTheCommit() {
        client.insertText("日本語", replacementRange: noReplacement)
        textView.insertText("日本語", replacementRange: noReplacement)
        assertMatchesTextView()
        mark("", selection: NSRange(location: 0, length: 0))
        mark("あ", selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(client.document, "前日本語あ後")
    }

    func testSelectionWithinMarkedTextUsesDocumentUTF16Offsets() {
        client.document = "😀前日本語後"
        client.selection = NSRange(location: 3, length: 3)
        textView.string = client.document
        textView.setSelectedRange(client.selection)
        mark("か\u{3099}😀", selection: NSRange(location: 2, length: 2))
        XCTAssertEqual(client.document, "😀前か\u{3099}😀後")
        XCTAssertEqual(client.selectedRange(), NSRange(location: 5, length: 2))
        XCTAssertEqual(client.markedRange(), NSRange(location: 3, length: 4))
    }

    func testMissingSelectionAtTheStartOfTheDocumentMatchesTheNativeInsertionPoint() {
        client.selection = NSRange(location: 0, length: 1)
        textView.setSelectedRange(client.selection)
        mark("先", selection: noSelection)
        XCTAssertEqual(client.document, "先日本語後")
    }
}
