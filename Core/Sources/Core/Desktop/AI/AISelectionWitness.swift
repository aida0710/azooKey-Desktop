import Foundation

/// A second, independent read of the focused editable object's selection
/// (AT-SPI on Ubuntu). Several fields can share one input context identity,
/// so the identity alone cannot prove that a result returns to its field.
public struct AISelectionWitness: Codable, Sendable {
    /// Identity of the editable object, including the connection it was read
    /// over, so a restarted accessibility bus is a different object.
    public var object: [String]
    public var window: [String]
    /// Selection bounds in the witness API's own units. They are compared only
    /// with another read of the same API, never with input-context offsets.
    public var start: Int
    public var end: Int
    public var before: String
    public var selected: String
    public var after: String

    public init(object: [String], window: [String], start: Int, end: Int, before: String, selected: String, after: String) {
        self.object = object
        self.window = window
        self.start = start
        self.end = end
        self.before = before
        self.selected = selected
        self.after = after
    }

    /// The input context may expose only the current paragraph, so the
    /// witness may see more text on either side; absolute offsets are not
    /// derived from that substring.
    public func describes(_ selection: AITextSelection) -> Bool {
        selected.hasSameScalars(as: selection.selected)
            && before.hasScalarSuffix(selection.before)
            && after.hasScalarPrefix(selection.after)
    }

    /// The same object, window, bounds and exact text.
    public func matches(_ other: AISelectionWitness) -> Bool {
        AITextSelection.sameIdentity(object, other.object) && AITextSelection.sameIdentity(window, other.window)
            && start == other.start && end == other.end
            && before.hasSameScalars(as: other.before)
            && selected.hasSameScalars(as: other.selected)
            && after.hasSameScalars(as: other.after)
    }
}
