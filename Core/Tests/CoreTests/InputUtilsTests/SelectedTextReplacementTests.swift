@testable import Core
import Foundation
import Testing

@MainActor
struct SelectedTextReplacementTests {
    private final class Client: SelectedTextClient {
        var identity: ObjectIdentifier { ObjectIdentifier(self) }
        var isActive = true
        var documentLength: Int { text.utf16.count }
        var selectedRange = NSRange(location: 1, length: 4)
        var text = "前日本語文後"
        var actualRange: NSRange?
        var cannotRead = false
        var afterRead: (() -> Void)?
        var insertions: [(range: NSRange, text: String)] = []

        func readText(in range: NSRange) -> (text: String, actualRange: NSRange)? {
            guard !cannotRead, range.location >= 0, range.length >= 0,
                  range.location <= documentLength, range.length <= documentLength - range.location else {
                return nil
            }
            let selected = (text as NSString).substring(with: range)
            afterRead?()
            return (selected, actualRange ?? range)
        }

        func replaceText(in range: NSRange, with text: String) {
            insertions.append((range, text))
        }
    }

    @Test func unchangedOriginalSelectionIsReplacedExactlyOnce() throws {
        let client = Client()
        let target = try SelectedTextReplacement(client: client)
        try target.apply("変換した文🙂", to: client)
        #expect(client.insertions.count == 1)
        #expect(client.insertions.first?.range == NSRange(location: 1, length: 4))
        #expect(client.insertions.first?.text == "変換した文🙂")
        #expect(throws: SelectedTextReplacement.Failure.self) { try target.apply("二度目", to: client) }
        #expect(client.insertions.count == 1)
    }

    @Test func anotherClientWithIdenticalTextAndRangeIsNeverReplaced() throws {
        let original = Client()
        let target = try SelectedTextReplacement(client: original)
        let other = Client()
        #expect(throws: SelectedTextReplacement.Failure.self) { try target.apply("結果", to: other) }
        #expect(original.insertions.isEmpty)
        #expect(other.insertions.isEmpty)
    }

    @Test func changedTextOrSelectionOrActualRangePreservesTheDocument() throws {
        for change in 0..<4 {
            let client = Client()
            let target = try SelectedTextReplacement(client: client)
            switch change {
            case 0: client.text = "前別の本文後"
            case 1: client.selectedRange = NSRange(location: 0, length: 4)
            case 2: client.actualRange = NSRange(location: 1, length: 3)
            default: client.cannotRead = true
            }
            #expect(throws: SelectedTextReplacement.Failure.self) { try target.apply("結果", to: client) }
            #expect(client.insertions.isEmpty)
        }
    }

    @Test func losingFocusBeforeOrDuringValidationDoesNotWrite() throws {
        for deactivateDuringRead in [false, true] {
            let client = Client()
            let target = try SelectedTextReplacement(client: client)
            if deactivateDuringRead {
                client.afterRead = { client.isActive = false }
            } else {
                client.isActive = false
            }
            #expect(throws: SelectedTextReplacement.Failure.self) { try target.apply("結果", to: client) }
            #expect(client.insertions.isEmpty)
        }
    }

    @Test func selectionChangedDuringValidationDoesNotWrite() throws {
        let client = Client()
        let target = try SelectedTextReplacement(client: client)
        client.afterRead = { client.selectedRange = NSRange(location: 0, length: 4) }
        #expect(throws: SelectedTextReplacement.Failure.self) { try target.apply("結果", to: client) }
        #expect(client.insertions.isEmpty)
    }

    @Test func cancelingOrChangingSelectionDuringPreviewValidationRejectsTheTarget() throws {
        for cancelDuringRead in [false, true] {
            let client = Client()
            let target = try SelectedTextReplacement(client: client)
            client.afterRead = {
                if cancelDuringRead {
                    target.cancel()
                } else {
                    client.selectedRange = NSRange(location: 0, length: 4)
                }
            }
            #expect(!target.matchesDocument(in: client))
            #expect(client.insertions.isEmpty)
        }
    }

    @Test func nonBMPAndCombiningTextKeepTheirExactUTF16Range() throws {
        let client = Client()
        client.text = "前👩‍💻e\u{301}後"
        client.selectedRange = NSRange(location: 1, length: 7)
        let target = try SelectedTextReplacement(client: client)
        #expect(target.text == "👩‍💻e\u{301}")
        try target.apply("変換後", to: client)
        #expect(client.insertions.count == 1)
        #expect(client.insertions.first?.range == NSRange(location: 1, length: 7))
    }

    @Test func canonicallyEquivalentButChangedTextIsNotTheOriginalSelection() throws {
        let client = Client()
        client.text = "前a\u{301}\u{323}後"
        client.selectedRange = NSRange(location: 1, length: 3)
        let target = try SelectedTextReplacement(client: client)
        client.text = "前a\u{323}\u{301}後"
        #expect(target.text == "a\u{323}\u{301}")
        #expect(throws: SelectedTextReplacement.Failure.self) { try target.apply("結果", to: client) }
        #expect(client.insertions.isEmpty)
    }

    @Test func cancellationDuringTheFocusWaitCannotBeAppliedLater() throws {
        let client = Client()
        let target = try SelectedTextReplacement(client: client)
        target.cancel()
        #expect(throws: SelectedTextReplacement.Failure.self) { try target.apply("結果", to: client) }
        #expect(client.insertions.isEmpty)
    }

    @Test func invalidOrUnreportedSelectionCannotCreateAnApplicableTarget() {
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: 0, length: 0),
                      NSRange(location: 5, length: 5), NSRange(location: Int.max - 1, length: 4)] {
            let client = Client()
            client.selectedRange = range
            #expect(throws: SelectedTextReplacement.Failure.self) { try SelectedTextReplacement(client: client) }
            #expect(client.insertions.isEmpty)
        }
        let client = Client()
        client.actualRange = NSRange(location: NSNotFound, length: 0)
        #expect(throws: SelectedTextReplacement.Failure.self) { try SelectedTextReplacement(client: client) }
    }

    @Test func reentrantApplicationOrCancellationCannotWriteAnExtraResult() throws {
        for cancelDuringRead in [false, true] {
            let client = Client()
            let target = try SelectedTextReplacement(client: client)
            client.afterRead = {
                if cancelDuringRead {
                    target.cancel()
                } else {
                    #expect(throws: SelectedTextReplacement.Failure.self) { try target.apply("再入", to: client) }
                }
            }
            if cancelDuringRead {
                #expect(throws: SelectedTextReplacement.Failure.self) { try target.apply("結果", to: client) }
                #expect(client.insertions.isEmpty)
            } else {
                try target.apply("結果", to: client)
                #expect(client.insertions.count == 1)
            }
        }
    }
}
