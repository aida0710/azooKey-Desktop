import Core
import Foundation
import InputMethodKit

/// Maps IMK document operations to the checked replacement boundary.
@MainActor
final class MacSelectedTextClient: SelectedTextClient {
    private let client: IMKTextInput
    private weak var focus: MacSelectedTextTransformSession?
    private let focusRevision: Int
    private let applicationIsActive: () -> Bool

    init(client: IMKTextInput, focus: MacSelectedTextTransformSession, applicationIsActive: @escaping () -> Bool) {
        self.client = client
        self.focus = focus
        self.focusRevision = focus.focusRevision
        self.applicationIsActive = applicationIsActive
    }

    var identity: ObjectIdentifier { ObjectIdentifier(client) }
    var isActive: Bool {
        focus?.focusRevision == focusRevision && focus?.isActive(client: client) == true && applicationIsActive()
    }
    var documentLength: Int { client.length() }
    var selectedRange: NSRange { client.selectedRange() }

    func readText(in range: NSRange) -> (text: String, actualRange: NSRange)? {
        var actual = NSRange(location: NSNotFound, length: 0)
        guard let text = client.string(from: range, actualRange: &actual) else {
            return nil
        }
        return (text, actual)
    }

    func replaceText(in range: NSRange, with text: String) {
        client.insertText(text, replacementRange: range)
    }
}
