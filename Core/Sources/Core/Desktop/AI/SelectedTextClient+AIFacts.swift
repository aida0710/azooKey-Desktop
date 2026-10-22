import Foundation

/// Facts for Core's AI decisions, read through `SelectedTextClient` by a
/// platform whose input API reads the document itself (macOS). The witness
/// is a second read through the same client: it cannot tell apart fields
/// that share the client, but it pins the absolute range and the window, so
/// a result is applied only where it was reviewed.
@MainActor
extension SelectedTextClient {
    /// A fresh report of the selection and of at most
    /// `AITextSelection.contextScalarLimit` UTF-16 units on each side of it.
    public func aiTextField(identity: [String], isSensitive: Bool) -> AITextField {
        AITextField(identity: identity, surrounding: readSelection()?.surrounding,
                    hasSurroundingUpdate: true, isSensitive: isSensitive)
    }

    /// nil when the selection cannot be read exactly.
    public func aiSelectionWitness(identity: [String], window: [String]) -> AISelectionWitness? {
        guard let read = readSelection() else {
            return nil
        }
        return AISelectionWitness(
            object: identity, window: window, start: read.range.location, end: read.range.location + read.range.length,
            before: read.before, selected: read.selected, after: read.after
        )
    }

    private func readSelection() -> SelectionRead? {
        let range = selectedRange
        let length = documentLength
        guard SelectedTextReplacement.isValid(range, documentLength: length),
              let selected = readText(in: range), selected.actualRange == range,
              selected.text.utf16.count == range.length else {
            return nil
        }
        let limit = AITextSelection.contextScalarLimit
        let beforeStart = max(0, range.location - limit)
        let afterStart = range.location + range.length
        return SelectionRead(
            range: range,
            before: readContext(in: NSRange(location: beforeStart, length: range.location - beforeStart)),
            selected: selected.text,
            after: readContext(in: NSRange(location: afterStart, length: min(limit, length - afterStart)))
        )
    }

    /// Surrounding text only widens what may be sent; an unreadable side is empty.
    private func readContext(in range: NSRange) -> String {
        range.length > 0 ? readText(in: range)?.text ?? "" : ""
    }
}

private struct SelectionRead {
    let range: NSRange
    let before: String
    let selected: String
    let after: String

    var surrounding: AITextField.Surrounding {
        let anchor = before.utf16.count
        return AITextField.Surrounding(
            text: before + selected + after, cursorUTF16: anchor + selected.utf16.count, anchorUTF16: anchor
        )
    }
}
