import Foundation

enum UserDictionaryTextDecoder {
    struct DecodedText {
        let text: String
        let encoding: UserDictionaryExchange.TextEncoding
    }

    static func decode(
        _ content: Data, encoding: UserDictionaryExchange.TextEncoding
    ) throws -> DecodedText {
        let bytes = Array(content)
        let hasUTF8Mark = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        let hasLittleEndianMark = bytes.starts(with: [0xFF, 0xFE])
        let hasBigEndianMark = bytes.starts(with: [0xFE, 0xFF])
        // UTF-32 shares UTF-16's little-endian prefix, but is outside this format's contract.
        guard !bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]),
              !bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) else {
            throw UserDictionaryExchange.Failure.unknownEncoding
        }
        let selected: UserDictionaryExchange.TextEncoding = encoding == .automatic
            ? (hasLittleEndianMark || hasBigEndianMark ? .utf16 : .utf8) : encoding
        let text: String?
        switch selected {
        case .utf8, .automatic:
            text = String(data: hasUTF8Mark ? Data(bytes.dropFirst(3)) : content, encoding: .utf8)
        case .utf16:
            guard hasLittleEndianMark || hasBigEndianMark, (bytes.count - 2).isMultiple(of: 2) else {
                throw UserDictionaryExchange.Failure.invalidEncoding(.utf16)
            }
            text = try decodeUTF16(Array(bytes.dropFirst(2)), littleEndian: hasLittleEndianMark)
        case .shiftJIS:
            guard !hasUTF8Mark, !hasLittleEndianMark, !hasBigEndianMark else {
                throw UserDictionaryExchange.Failure.invalidEncoding(.shiftJIS)
            }
            text = String(data: content, encoding: .shiftJIS)
        }
        guard let text else {
            throw encoding == .automatic
                ? UserDictionaryExchange.Failure.unknownEncoding
                : UserDictionaryExchange.Failure.invalidEncoding(selected)
        }
        return DecodedText(text: text, encoding: selected)
    }

    private static func decodeUTF16(_ bytes: [UInt8], littleEndian: Bool) throws -> String {
        let units = stride(from: 0, to: bytes.count, by: 2).map { offset in
            littleEndian
                ? UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                : UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
        // String(decoding:as:) repairs unpaired surrogates, so validate before constructing the text.
        var offset = 0
        while offset < units.count {
            let unit = units[offset]
            if (0xD800...0xDBFF).contains(unit) {
                guard offset + 1 < units.count, (0xDC00...0xDFFF).contains(units[offset + 1]) else {
                    throw UserDictionaryExchange.Failure.invalidEncoding(.utf16)
                }
                offset += 2
            } else {
                guard !(0xDC00...0xDFFF).contains(unit) else {
                    throw UserDictionaryExchange.Failure.invalidEncoding(.utf16)
                }
                offset += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}
