import Foundation

/// A lossless backup format plus explicitly selected public text import formats.
public enum UserDictionaryExchange {
    public enum Format: String, Codable, CaseIterable, Sendable {
        case json
        case atok2017
        case mozc
    }

    public enum TextEncoding: String, Codable, CaseIterable, Sendable {
        /// Only UTF-8 and BOM-marked UTF-16 are detected; legacy encodings must be selected.
        case automatic
        case utf8
        case utf16
        case shiftJIS
    }

    public enum Failure: Error, Equatable, Sendable {
        case unknownEncoding
        case invalidEncoding(TextEncoding)
        case unsupportedBinary
        case unsupportedFormat
        case unsupportedVersion(Int)
        case invalidDocument
        case stalePreview
    }

    public enum Problem: String, Codable, Sendable {
        case invalidColumns
        case unsupportedFields
        case unsupportedPartOfSpeech
        case invalidEntry
        case duplicate
        case conflict
    }

    public enum Notice: String, Codable, Sendable {
        /// The current compiler registers every accepted entry as a proper noun.
        case properNounRegistration
    }

    public struct Row: Encodable, Sendable {
        /// A one-based item number; JSON does not pretend this is a physical line.
        public let sourceIndex: Int
        public let sourceLine: Int?
        public let item: Config.UserDictionaryEntry?
        public let partOfSpeech: String?
        public let problem: Problem?
    }

    public struct Document: Encodable, Sendable {
        public let format: Format
        public let encoding: TextEncoding
        public let rows: [Row]
        public let notices: [Notice]
    }

    public static func parse(
        _ content: Data, format: Format, encoding: TextEncoding = .automatic
    ) throws -> Document {
        let decoded = try UserDictionaryTextDecoder.decode(content, encoding: encoding)
        let rows: [Row]
        switch format {
        case .json:
            rows = try UserDictionaryJSONExchange.parse(decoded.text)
        case .atok2017, .mozc:
            rows = try UserDictionaryTextImport.parse(decoded.text, format: format)
        }
        return Document(format: format, encoding: decoded.encoding, rows: rows, notices: [.properNounRegistration])
    }

    /// Export preserves raw reading, word and optional hint; row IDs belong to the receiving editor.
    public static func export(_ items: [Config.UserDictionaryEntry]) throws -> Data {
        try UserDictionaryJSONExchange.export(items)
    }
}
