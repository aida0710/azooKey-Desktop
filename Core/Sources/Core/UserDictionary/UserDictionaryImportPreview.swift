import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

public enum UserDictionaryImportPreview {
    public enum Outcome: String, Codable, Sendable {
        case addition
        case duplicate
        case conflict
        case excluded
    }

    public struct Row: Encodable, Sendable {
        public let source: UserDictionaryExchange.Row
        public let outcome: Outcome
        public let problem: UserDictionaryExchange.Problem?
        public let validationIssues: [UserDictionaryValidation.Issue]
        public let existingID: UUID?
    }

    public struct Counts: Encodable, Sendable {
        public let additions: Int
        public let duplicates: Int
        public let conflicts: Int
        public let excluded: Int
    }

    public struct Preview: Encodable, Sendable {
        public let rows: [Row]
        public let counts: Counts
        public let notices: [UserDictionaryExchange.Notice]
        let original: [EntrySnapshot]

        // Only the in-process preview can be applied; serialized UI output is not an authorization token.
        private enum CodingKeys: String, CodingKey {
            case rows, counts, notices
        }
    }

    struct EntrySnapshot: Equatable, Sendable {
        let id: UUID
        let wordUTF8: Data
        let readingUTF8: Data
        let hintUTF8: Data?

        init(_ entry: Config.UserDictionaryEntry) {
            id = entry.id
            wordUTF8 = Data(entry.word.utf8)
            readingUTF8 = Data(entry.reading.utf8)
            hintUTF8 = entry.hint.map { Data($0.utf8) }
        }
    }

    private struct Key: Hashable {
        let reading: String
        let wordUTF8: Data

        init(_ entry: Config.UserDictionaryEntry) {
            reading = entry.reading.toKatakana()
            wordUTF8 = Data(entry.word.utf8)
        }
    }

    public static func make(
        document: UserDictionaryExchange.Document,
        existing: [Config.UserDictionaryEntry],
        charIDFileURL: URL? = nil
    ) throws -> Preview {
        let candidates = document.rows.filter { $0.problem == nil }.compactMap(\.item)
        let issues = try UserDictionaryValidation.validate(items: candidates, charIDFileURL: charIDFileURL)
        let issuesByID = Dictionary(grouping: issues, by: \.rowID)
        var known = Dictionary(grouping: existing, by: Key.init)
        var rows: [Row] = []
        for source in document.rows {
            if let problem = source.problem {
                rows.append(.init(source: source, outcome: .excluded, problem: problem, validationIssues: [], existingID: nil))
                continue
            }
            guard let item = source.item else {
                rows.append(.init(source: source, outcome: .excluded, problem: .invalidEntry, validationIssues: [], existingID: nil))
                continue
            }
            if let invalid = issuesByID[item.id] {
                rows.append(.init(source: source, outcome: .excluded, problem: .invalidEntry, validationIssues: invalid, existingID: nil))
                continue
            }
            let key = Key(item)
            let matches = known[key] ?? []
            if let duplicate = matches.first(where: { Data($0.nonNullHint.utf8) == Data(item.nonNullHint.utf8) }) {
                rows.append(.init(source: source, outcome: .duplicate, problem: .duplicate, validationIssues: [], existingID: duplicate.id))
            } else if let conflict = matches.first {
                rows.append(.init(source: source, outcome: .conflict, problem: .conflict, validationIssues: [], existingID: conflict.id))
            } else {
                rows.append(.init(source: source, outcome: .addition, problem: nil, validationIssues: [], existingID: nil))
                known[key] = [item]
            }
        }
        return Preview(
            rows: rows,
            counts: Counts(
                additions: rows.filter { $0.outcome == .addition }.count,
                duplicates: rows.filter { $0.outcome == .duplicate }.count,
                conflicts: rows.filter { $0.outcome == .conflict }.count,
                excluded: rows.filter { $0.outcome == .excluded }.count
            ),
            notices: document.notices, original: existing.map(EntrySnapshot.init)
        )
    }

    public static func applying(
        _ preview: Preview, to current: [Config.UserDictionaryEntry]
    ) throws -> [Config.UserDictionaryEntry] {
        guard current.map(EntrySnapshot.init) == preview.original else {
            throw UserDictionaryExchange.Failure.stalePreview
        }
        return current + preview.rows.filter { $0.outcome == .addition }.compactMap(\.source.item)
    }
}
