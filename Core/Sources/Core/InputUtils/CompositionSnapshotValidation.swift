/// Bounds for the opt-in transport, not for ordinary synchronous composition.
public enum CompositionSnapshotLimits {
    // A single request must remain bounded even when it contains escaped Unicode.
    public static let jsonByteCount = 4 * 1024 * 1024
    public static let inputElementCount = 16_384
    public static let readingCharacterCount = 16_384
    // One Character can contain arbitrarily many combining scalars.
    public static let pieceUTF8ByteCount = 4 * 1024
    public static let tableNameUTF8ByteCount = 1024
    public static let customTableCount = 64
    // Count trees describe consumption, not arbitrary recursive programs.
    public static let composingCountDepth = 32
    public static let composingCountNodes = 127
}

public enum CompositionSnapshotError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidValue(String)
    case limitExceeded(String)
    case customTableRevisionMismatch(String)
    case inconsistentReading
}

enum CompositionSnapshotValidation {
    struct Key: CodingKey {
        let stringValue: String
        let intValue: Int?
        init(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }
        init(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    static func keys(_ decoder: any Decoder, allowed: Set<String>) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw CompositionSnapshotError.invalidValue("unknownField")
        }
    }

    static func character(_ text: String, field: String) throws -> Character {
        guard text.utf8.count <= CompositionSnapshotLimits.pieceUTF8ByteCount else {
            throw CompositionSnapshotError.limitExceeded(field)
        }
        guard text.count == 1, let character = text.first else {
            throw CompositionSnapshotError.invalidValue(field)
        }
        return character
    }

    static func tableName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= CompositionSnapshotLimits.tableNameUTF8ByteCount else {
            throw CompositionSnapshotError.invalidValue("tableName")
        }
    }

    static func revision(_ revision: String) throws {
        // The registration owner hashes the exact exported table bytes.
        guard revision.utf8.count == 64,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CompositionSnapshotError.invalidValue("customTableRevision")
        }
    }
}
