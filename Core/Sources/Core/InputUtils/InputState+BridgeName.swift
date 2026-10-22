extension InputState {
    /// The state name in desktop bridge snapshots (`inputState`).
    public var bridgeName: String {
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

    /// Resolves a snapshot's `inputState`. Associated text is not part of the
    /// name, so only state-wide rules such as `enterConfirmsCandidate` apply.
    public init?(bridgeName: String) {
        let states: [InputState] = [.none, .attachDiacritic(""), .composing, .previewing, .selecting,
                                    .replaceSuggestion, .unicodeInput("")]
        guard let state = states.first(where: { $0.bridgeName == bridgeName }) else {
            return nil
        }
        self = state
    }
}
