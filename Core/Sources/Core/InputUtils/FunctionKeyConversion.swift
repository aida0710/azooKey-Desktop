import Foundation
import KanaKanjiConverterModule

/// The character forms used by F6–F10, shared by the desktop input adapters.
public enum FunctionKeyConversion: Sendable {
    case hiragana
    case katakana
    case halfWidthKatakana
    case fullWidthRoman
    case halfWidthRoman

    public init?(action: ClientAction) {
        switch action {
        case .submitHiraganaCandidate: self = .hiragana
        case .submitKatakanaCandidate: self = .katakana
        case .submitHankakuKatakanaCandidate: self = .halfWidthKatakana
        case .submitFullWidthRomanCandidate: self = .fullWidthRoman
        case .submitHalfWidthRomanCandidate: self = .halfWidthRoman
        default: return nil
        }
    }

    public var isRoman: Bool {
        switch self {
        case .fullWidthRoman, .halfWidthRoman: true
        case .hiragana, .katakana, .halfWidthKatakana: false
        }
    }

    public func convert(_ text: String) -> String {
        switch self {
        case .hiragana: text.toHiragana()
        case .katakana: text.toKatakana()
        case .halfWidthKatakana: text.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        case .fullWidthRoman: text.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? text
        case .halfWidthRoman: text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        }
    }
}
