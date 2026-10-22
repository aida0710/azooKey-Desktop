import KanaKanjiConverterModule

/// A local reading prompt must not edit the selected document or request AI.
public struct ReconversionReadingInput {
    public enum Update: Equatable {
        case editing
        case submitted(String)
        case cancelled
    }

    private var composition = ComposingText()
    public var text: String { composition.convertTarget }

    public init() {}

    public mutating func process(_ event: KeyEventCore) -> Update {
        let previous = composition
        switch UserAction.getUserAction(eventCore: event, inputLanguage: .japanese) {
        case .input(let pieces):
            composition.insertAtCursorPosition(pieces.map { .init(piece: $0, inputStyle: .mapped(id: .defaultRomanToKana)) })
        case .number(let number):
            composition.insertAtCursorPosition([.init(piece: number.inputPiece, inputStyle: .mapped(id: .defaultRomanToKana))])
        case .backspace:
            composition.deleteBackwardFromCursorPosition(count: 1)
        case .enter:
            return .submitted(text)
        case .escape:
            return .cancelled
        default:
            break
        }
        if text.unicodeScalars.count > ReconversionContext.selectionLimit {
            composition = previous
        }
        return .editing
    }
}
