import Foundation

/// The settings file's JSON text. Unlike JSONSerialization this rejects
/// duplicate member names and reports where a syntax error is, so every OS
/// tells the user the same thing about a hand-edited file.
public enum DesktopSettingsJSONText {
    public enum Failure: Error, Equatable, Sendable {
        case notUTF8
        case syntax(line: Int, column: Int)
        case duplicateKey(String)
        case tooDeep
    }

    /// Settings nest four levels deep. The bound keeps a damaged file from
    /// exhausting the stack of the thread that reads it.
    static let maximumNestingDepth = 64

    public static func parse(_ data: Data) throws -> DesktopSettingsJSON {
        var parser = SettingsJSONParser(scalars: try unicodeScalars(in: data))
        return try parser.parseDocument()
    }

    /// Writes the same layout Python's `json.dump(ensure_ascii=False)` produced.
    public static func serialize(_ value: DesktopSettingsJSON) -> Data {
        var output = ""
        write(value, into: &output)
        return Data(output.utf8)
    }

    private static func unicodeScalars(in data: Data) throws -> [Unicode.Scalar] {
        var scalars: [Unicode.Scalar] = []
        var bytes = data.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&bytes) {
            case .scalarValue(let scalar):
                scalars.append(scalar)
            case .emptyInput:
                return scalars
            case .error:
                throw Failure.notUTF8
            }
        }
    }

    private static func write(_ value: DesktopSettingsJSON, into output: inout String) {
        switch value {
        case .null:
            output += "null"
        case .bool(let flag):
            output += flag ? "true" : "false"
        case .integer(let number):
            output += String(number)
        case .number(let number):
            output += String(number)
        case .string(let text):
            writeString(text, into: &output)
        case .unpairedSurrogateString:
            writeString("\u{FFFD}", into: &output)
        case .array(let items):
            output += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 {
                    output += ", "
                }
                write(item, into: &output)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (offset, member) in members.enumerated() {
                if offset > 0 {
                    output += ", "
                }
                writeString(member.key, into: &output)
                output += ": "
                write(member.value, into: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ text: String, into output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":
                output += "\\\""
            case "\\":
                output += "\\\\"
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            case "\u{08}":
                output += "\\b"
            case "\u{0C}":
                output += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}

private struct SettingsJSONParser {
    let scalars: [Unicode.Scalar]
    var index = 0

    init(scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    mutating func parseDocument() throws -> DesktopSettingsJSON {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == scalars.count else {
            throw syntaxError()
        }
        return value
    }

    private var current: Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    private mutating func parseValue(depth: Int) throws -> DesktopSettingsJSON {
        guard let scalar = current else {
            throw syntaxError()
        }
        switch scalar {
        case "{":
            return try parseObject(depth: depth + 1)
        case "[":
            return try parseArray(depth: depth + 1)
        case "\"":
            let text = try parseString()
            return text.isUnicode ? .string(text.value) : .unpairedSurrogateString
        case "t":
            try expectLiteral("true")
            return .bool(true)
        case "f":
            try expectLiteral("false")
            return .bool(false)
        case "n":
            try expectLiteral("null")
            return .null
        case "-", "0"..."9":
            return try parseNumber()
        default:
            throw syntaxError()
        }
    }

    private mutating func parseObject(depth: Int) throws -> DesktopSettingsJSON {
        guard depth <= DesktopSettingsJSONText.maximumNestingDepth else {
            throw DesktopSettingsJSONText.Failure.tooDeep
        }
        index += 1
        skipWhitespace()
        var members: [DesktopSettingsJSON.Member] = []
        var keys: Set<String> = []
        if consume("}") {
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard current == "\"" else {
                throw syntaxError()
            }
            let key = try parseString().value
            guard keys.insert(key).inserted else {
                throw DesktopSettingsJSONText.Failure.duplicateKey(key)
            }
            skipWhitespace()
            guard consume(":") else {
                throw syntaxError()
            }
            skipWhitespace()
            members.append(.init(key: key, value: try parseValue(depth: depth)))
            skipWhitespace()
            if consume(",") {
                continue
            }
            guard consume("}") else {
                throw syntaxError()
            }
            return .object(members)
        }
    }

    private mutating func parseArray(depth: Int) throws -> DesktopSettingsJSON {
        guard depth <= DesktopSettingsJSONText.maximumNestingDepth else {
            throw DesktopSettingsJSONText.Failure.tooDeep
        }
        index += 1
        skipWhitespace()
        var items: [DesktopSettingsJSON] = []
        if consume("]") {
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try parseValue(depth: depth))
            skipWhitespace()
            if consume(",") {
                continue
            }
            guard consume("]") else {
                throw syntaxError()
            }
            return .array(items)
        }
    }

    private mutating func parseString() throws -> (value: String, isUnicode: Bool) {
        index += 1
        var result = String.UnicodeScalarView()
        var isUnicode = true
        while let scalar = current {
            switch scalar {
            case "\"":
                index += 1
                return (String(result), isUnicode)
            case "\\":
                index += 1
                guard let escape = current else {
                    throw syntaxError()
                }
                index += 1
                switch escape {
                case "\"", "\\", "/":
                    result.append(escape)
                case "b":
                    result.append("\u{08}")
                case "f":
                    result.append("\u{0C}")
                case "n":
                    result.append("\n")
                case "r":
                    result.append("\r")
                case "t":
                    result.append("\t")
                case "u":
                    if let decoded = try parseUnicodeEscape() {
                        result.append(decoded)
                    } else {
                        isUnicode = false
                    }
                default:
                    index -= 2
                    throw syntaxError()
                }
            default:
                // JSON forbids raw control characters inside strings.
                guard scalar.value >= 0x20 else {
                    throw syntaxError()
                }
                result.append(scalar)
                index += 1
            }
        }
        throw syntaxError()
    }

    /// Returns nil for an unpaired surrogate, which Python accepts but Unicode does not.
    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar? {
        let unit = try parseHexUnit()
        if UTF16.isLeadSurrogate(unit) {
            let afterLead = index
            if consume("\\"), consume("u") {
                let trail = try parseHexUnit()
                if UTF16.isTrailSurrogate(trail) {
                    let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(trail) - 0xDC00)
                    return Unicode.Scalar(value)
                }
            }
            index = afterLead
            return nil
        }
        return Unicode.Scalar(unit)
    }

    private mutating func parseHexUnit() throws -> UInt16 {
        guard index + 4 <= scalars.count else {
            throw syntaxError()
        }
        var value: UInt16 = 0
        for scalar in scalars[index..<index + 4] {
            guard let digit = Character(scalar).hexDigitValue else {
                throw syntaxError()
            }
            value = value * 16 + UInt16(digit)
        }
        index += 4
        return value
    }

    private mutating func parseNumber() throws -> DesktopSettingsJSON {
        let start = index
        _ = consume("-")
        guard let first = current, ("0"..."9").contains(first) else {
            throw syntaxError()
        }
        if first == "0" {
            index += 1
        } else {
            skipDigits()
        }
        var isInteger = true
        if consume(".") {
            isInteger = false
            try requireDigits()
        }
        if current == "e" || current == "E" {
            isInteger = false
            index += 1
            if current == "+" || current == "-" {
                index += 1
            }
            try requireDigits()
        }
        let text = String(String.UnicodeScalarView(scalars[start..<index]))
        if isInteger, let number = Int(text) {
            return .integer(number)
        }
        guard let number = Double(text) else {
            throw syntaxError(at: start)
        }
        return .number(number)
    }

    private mutating func requireDigits() throws {
        guard let scalar = current, ("0"..."9").contains(scalar) else {
            throw syntaxError()
        }
        skipDigits()
    }

    private mutating func skipDigits() {
        while let scalar = current, ("0"..."9").contains(scalar) {
            index += 1
        }
    }

    private mutating func expectLiteral(_ literal: String) throws {
        for expected in literal.unicodeScalars {
            guard current == expected else {
                throw syntaxError()
            }
            index += 1
        }
    }

    private mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        guard current == scalar else {
            return false
        }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let scalar = current, [" ", "\t", "\n", "\r"].contains(scalar) {
            index += 1
        }
    }

    /// Lines and columns count characters from 1, as Python's json module reports them.
    private func syntaxError(at position: Int? = nil) -> DesktopSettingsJSONText.Failure {
        let end = min(position ?? index, scalars.count)
        let preceding = scalars[..<end]
        let line = preceding.filter { $0 == "\n" }.count + 1
        let column = end - (preceding.lastIndex(of: "\n").map { $0 + 1 } ?? 0) + 1
        return .syntax(line: line, column: column)
    }
}
