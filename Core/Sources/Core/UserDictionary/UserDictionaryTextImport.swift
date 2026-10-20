import Foundation

enum UserDictionaryTextImport {
    private static let atokHeader = "!!ATOK_TANGO_TEXT_HEADER_1"
    // ATOK's published noun table (labels and IDs 1–8); conjugating noun categories stay excluded.
    private static let atokNouns: Set<String> = [
        "名詞", "固有人姓", "固有人名", "固有人他", "固有地名", "固有組織", "固有商品", "固有一般",
        "1", "2", "3", "4", "5", "6", "7", "8"
    ]
    // Mozc src/data/rules/user_pos.def; abbreviations and suggestion-only entries have different semantics.
    private static let mozcNouns: Set<String> = ["名詞", "固有名詞", "人名", "姓", "名", "組織", "地名"]

    static func parse(_ text: String, format: UserDictionaryExchange.Format) throws -> [UserDictionaryExchange.Row] {
        // JSON validates its own string syntax and may preserve literal C1 controls in hints.
        guard !text.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control && !["\t", "\r", "\n"].contains($0)
        }) else {
            throw UserDictionaryExchange.Failure.unsupportedBinary
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        if format == .atok2017 {
            guard lines.first?.caseInsensitiveCompare(atokHeader) == .orderedSame else {
                throw UserDictionaryExchange.Failure.unsupportedFormat
            }
        }
        var rows: [UserDictionaryExchange.Row] = []
        for (index, line) in lines.enumerated() {
            if line.isEmpty || (format == .atok2017 && line.hasPrefix("!!")) || (format == .mozc && line.hasPrefix("#")) {
                continue
            }
            if format == .mozc && line.hasPrefix("!") {
                throw UserDictionaryExchange.Failure.unsupportedFormat
            }
            rows.append(parseRow(line, lineNumber: index + 1, format: format, sourceIndex: rows.count + 1))
        }
        return rows
    }

    private static func parseRow(
        _ line: String, lineNumber: Int, format: UserDictionaryExchange.Format, sourceIndex: Int
    ) -> UserDictionaryExchange.Row {
        let columns = line.components(separatedBy: "\t")
        guard columns.count >= 3 else {
            return .init(sourceIndex: sourceIndex, sourceLine: lineNumber, item: nil, partOfSpeech: nil, problem: .invalidColumns)
        }
        let item = Config.UserDictionaryEntry(
            word: columns[1], reading: columns[0], hint: columns.count >= 4 ? columns[3] : nil
        )
        let originalPartOfSpeech = columns[2]
        var partOfSpeech = originalPartOfSpeech
        if format == .atok2017, let marker = partOfSpeech.last, marker == "*" || marker == "$" {
            partOfSpeech.removeLast()
        }
        let problem: UserDictionaryExchange.Problem?
        if columns.count > 4, columns.dropFirst(4).contains(where: { !$0.isEmpty }) {
            problem = .unsupportedFields
        } else if !(format == .atok2017 ? atokNouns : mozcNouns).contains(partOfSpeech) {
            problem = .unsupportedPartOfSpeech
        } else {
            problem = nil
        }
        return .init(
            sourceIndex: sourceIndex, sourceLine: lineNumber, item: item,
            partOfSpeech: originalPartOfSpeech, problem: problem
        )
    }
}
