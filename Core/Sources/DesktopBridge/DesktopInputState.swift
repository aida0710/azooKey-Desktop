import Core

extension InputState {
    var bridgeName: String {
        switch self {
        case .none: "none"
        case .composing: "composing"
        case .previewing: "previewing"
        case .selecting: "selecting"
        case .replaceSuggestion: "replaceSuggestion"
        case .unicodeInput: "unicodeInput"
        case .attachDiacritic: "attachDiacritic"
        }
    }
}
