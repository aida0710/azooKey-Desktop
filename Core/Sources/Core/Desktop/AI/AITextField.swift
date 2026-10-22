import Foundation

/// Facts an input method reports about the focused editable field. Core
/// decides from these what may be sent to AI and whether a result may replace
/// the original selection; the platform layer only observes and reports.
public struct AITextField: Codable, Sendable {
    /// Text around the caret as the field reported it. Positions are UTF-16
    /// offsets into `text`, like every other desktop document position.
    public struct Surrounding: Codable, Sendable {
        public var text: String
        public var cursorUTF16: Int
        public var anchorUTF16: Int

        public init(text: String, cursorUTF16: Int, anchorUTF16: Int) {
            self.text = text
            self.cursorUTF16 = cursorUTF16
            self.anchorUTF16 = anchorUTF16
        }
    }

    /// Opaque identity of the input target (on Ubuntu, the IBus input context
    /// path and client). nil when the platform cannot name the focused target.
    public var identity: [String]?
    public var surrounding: Surrounding?
    /// Whether `surrounding` arrived after the field last gained focus. An
    /// older report never describes the target that is focused now.
    public var hasSurroundingUpdate: Bool
    /// Password, PIN and private-input fields never reach an AI request.
    public var isSensitive: Bool

    public init(identity: [String]?, surrounding: Surrounding?, hasSurroundingUpdate: Bool, isSensitive: Bool) {
        self.identity = identity
        self.surrounding = surrounding
        self.hasSurroundingUpdate = hasSurroundingUpdate
        self.isSensitive = isSensitive
    }

    /// The selection of a fresh report from a named target, the only kind
    /// that can later be recognized as the same place in the same field.
    public var currentSelection: AITextSelection? {
        guard let identity, hasSurroundingUpdate, let surrounding else {
            return nil
        }
        return AITextSelection(identity: identity, surrounding: surrounding)
    }
}

/// A selection captured from reported surrounding text: the selected text and
/// at most `contextScalarLimit` scalars on each side of it.
public struct AITextSelection: Sendable {
    /// The same window is shown for review and sent when context is included.
    public static let contextScalarLimit = AIRequestScope.contextCharacterLimit

    public let identity: [String]?
    public let cursorUTF16: Int
    public let anchorUTF16: Int
    public let before: String
    public let selected: String
    public let after: String

    /// nil for offsets outside the text or inside a surrogate pair, and for an
    /// empty selection.
    public init?(identity: [String]?, surrounding: AITextField.Surrounding) {
        let text = surrounding.text
        guard let cursor = Self.scalarIndex(atUTF16Offset: surrounding.cursorUTF16, in: text),
              let anchor = Self.scalarIndex(atUTF16Offset: surrounding.anchorUTF16, in: text),
              cursor != anchor else {
            return nil
        }
        let start = min(cursor, anchor)
        let end = max(cursor, anchor)
        let scalars = text.unicodeScalars
        self.identity = identity
        self.cursorUTF16 = surrounding.cursorUTF16
        self.anchorUTF16 = surrounding.anchorUTF16
        self.before = String(String.UnicodeScalarView(scalars[..<start])).scalarSuffix(Self.contextScalarLimit)
        self.selected = String(String.UnicodeScalarView(scalars[start..<end]))
        self.after = String(String.UnicodeScalarView(scalars[end...])).scalarPrefix(Self.contextScalarLimit)
    }

    /// The same input target, selection direction and exact text.
    public func matches(_ other: AITextSelection) -> Bool {
        isSameTarget(as: other.identity)
            && cursorUTF16 == other.cursorUTF16 && anchorUTF16 == other.anchorUTF16
            && before.hasSameScalars(as: other.before)
            && selected.hasSameScalars(as: other.selected)
            && after.hasSameScalars(as: other.after)
    }

    /// Whether `identity` names the input target this selection was captured from.
    func isSameTarget(as identity: [String]?) -> Bool {
        switch (self.identity, identity) {
        case (nil, nil):
            return true
        case let (captured?, other?):
            return captured.hasSameScalars(as: other)
        default:
            return false
        }
    }

    private static func scalarIndex(atUTF16Offset offset: Int, in text: String) -> String.Index? {
        guard offset >= 0, offset <= text.utf16.count else {
            return nil
        }
        return text.utf16.index(text.utf16.startIndex, offsetBy: offset).samePosition(in: text.unicodeScalars)
    }
}
