import Foundation

/// The adapter supplies character positions in Unicode scalars, never UTF-16.
/// Only a bounded neighborhood is needed; no document is kept on disk.
public struct ReconversionContext: Codable, Equatable, Sendable {
    public static let contextLimit = 256
    public static let selectionLimit = 256

    public var before: String
    public var selected: String
    public var after: String
    public var cursor: Int
    public var anchor: Int
    public var canReplace: Bool
    public var isSensitive: Bool

    public init(before: String, selected: String, after: String, cursor: Int, anchor: Int,
                canReplace: Bool, isSensitive: Bool) {
        self.before = String(before.unicodeScalars.suffix(Self.contextLimit))
        self.selected = selected
        self.after = String(after.unicodeScalars.prefix(Self.contextLimit))
        self.cursor = cursor
        self.anchor = anchor
        self.canReplace = canReplace
        self.isSensitive = isSensitive
    }

    public var selectionStart: Int { min(cursor, anchor) }

    var isValid: Bool {
        cursor >= 0 && anchor >= 0
            && selected.unicodeScalars.count == max(cursor, anchor) - selectionStart
            && selected.unicodeScalars.count <= Self.selectionLimit
            && before.unicodeScalars.count <= Self.contextLimit
            && after.unicodeScalars.count <= Self.contextLimit
            && before.unicodeScalars.count <= selectionStart
    }

    func replacingSelection(with text: String) -> Self {
        let newCursor = selectionStart + text.unicodeScalars.count
        return .init(before: before + text, selected: "", after: after, cursor: newCursor,
                     anchor: newCursor, canReplace: canReplace, isSensitive: isSensitive)
    }

    func removingPreceding(_ text: String) -> Self? {
        let scalarCount = text.unicodeScalars.count
        guard selected.isEmpty, before.unicodeScalars.suffix(scalarCount).elementsEqual(text.unicodeScalars) else { return nil }
        let newCursor = cursor - scalarCount
        guard newCursor >= 0 else { return nil }
        return .init(before: String(before.unicodeScalars.dropLast(scalarCount)), selected: "", after: after,
                     cursor: newCursor, anchor: newCursor, canReplace: canReplace, isSensitive: isSensitive)
    }

    /// A deletion may reveal additional preceding context that was outside the
    /// adapter's bounded window. The known suffix and exact position must agree.
    func matchesDocument(_ other: Self) -> Bool {
        guard isValid, other.isValid, other.canReplace, !other.isSensitive,
              cursor == other.cursor, anchor == other.anchor,
              selected.unicodeScalars.elementsEqual(other.selected.unicodeScalars),
              after.unicodeScalars.elementsEqual(other.after.unicodeScalars) else { return false }
        return before.unicodeScalars.elementsEqual(other.before.unicodeScalars) || (
            before.unicodeScalars.count < Self.contextLimit
                && other.before.unicodeScalars.suffix(before.unicodeScalars.count).elementsEqual(before.unicodeScalars)
                && before.unicodeScalars.count < selectionStart
        )
    }
}
