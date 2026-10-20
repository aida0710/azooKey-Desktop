import Foundation

/// Document positions use UTF-16 on both platforms; IBus deletion lengths use scalars.
/// Only a bounded neighborhood is needed; no document is kept on disk.
public struct ReconversionContext: Codable, Equatable, Sendable {
    public static let contextLimit = 256
    public static let selectionLimit = 256

    public var before: String
    public var selected: String
    public var after: String
    public var cursorUTF16: Int
    public var anchorUTF16: Int
    public var canReplace: Bool
    public var isSensitive: Bool

    public init(before: String, selected: String, after: String, cursorUTF16: Int, anchorUTF16: Int,
                canReplace: Bool, isSensitive: Bool) {
        self.before = String(before.unicodeScalars.suffix(Self.contextLimit))
        self.selected = selected
        self.after = String(after.unicodeScalars.prefix(Self.contextLimit))
        self.cursorUTF16 = cursorUTF16
        self.anchorUTF16 = anchorUTF16
        self.canReplace = canReplace
        self.isSensitive = isSensitive
    }

    public var selectionStart: Int { min(cursorUTF16, anchorUTF16) }

    var isValid: Bool {
        cursorUTF16 >= 0 && anchorUTF16 >= 0
            && selected.utf16.count == max(cursorUTF16, anchorUTF16) - selectionStart
            && selected.unicodeScalars.count <= Self.selectionLimit
            && before.unicodeScalars.count <= Self.contextLimit
            && after.unicodeScalars.count <= Self.contextLimit
            && before.utf16.count <= selectionStart
    }

    func replacingSelection(with text: String) -> Self {
        let newCursor = selectionStart + text.utf16.count
        return .init(before: before + text, selected: "", after: after, cursorUTF16: newCursor,
                     anchorUTF16: newCursor, canReplace: canReplace, isSensitive: isSensitive)
    }

    func removingPreceding(_ text: String) -> Self? {
        let scalarCount = text.unicodeScalars.count
        guard selected.isEmpty, before.unicodeScalars.suffix(scalarCount).elementsEqual(text.unicodeScalars) else {
            return nil
        }
        let newCursor = cursorUTF16 - text.utf16.count
        guard newCursor >= 0 else {
            return nil
        }
        return .init(before: String(before.unicodeScalars.dropLast(scalarCount)), selected: "", after: after,
                     cursorUTF16: newCursor, anchorUTF16: newCursor, canReplace: canReplace, isSensitive: isSensitive)
    }

    /// A deletion may reveal additional preceding context that was outside the
    /// adapter's bounded window. The known suffix and exact position must agree.
    public func matchesDocument(_ other: Self) -> Bool {
        guard isValid, other.isValid, other.canReplace, !other.isSensitive,
              cursorUTF16 == other.cursorUTF16, anchorUTF16 == other.anchorUTF16,
              selected.unicodeScalars.elementsEqual(other.selected.unicodeScalars),
              after.unicodeScalars.elementsEqual(other.after.unicodeScalars) else {
            return false
        }
        return before.unicodeScalars.elementsEqual(other.before.unicodeScalars) || (
            before.unicodeScalars.count < Self.contextLimit
                && other.before.unicodeScalars.suffix(before.unicodeScalars.count).elementsEqual(before.unicodeScalars)
                && before.utf16.count < selectionStart
        )
    }
}
