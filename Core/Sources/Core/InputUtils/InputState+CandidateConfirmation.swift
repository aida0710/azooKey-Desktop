extension InputState {
    /// 修飾キーなしの Enter が、選択・プレビュー中の候補を確定する状態か。
    /// composing の表示候補は、Enter が確定する marked text と異なる場合がある。
    public var enterConfirmsCandidate: Bool {
        switch self {
        case .previewing, .selecting, .replaceSuggestion:
            true
        case .none, .attachDiacritic, .composing, .unicodeInput:
            false
        }
    }
}
