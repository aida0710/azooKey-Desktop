import KanaKanjiConverterModule

/// One short-lived composition retained for an explicit commit undo.
/// It is never serialized or shared with another input context.
public struct CompositionCheckpoint {
    let composingText: ComposingText
    let inputStyle: InputStyle
    let conversionRangeEnd: Int?
    public let selectedText: String?

    public var reading: String { composingText.convertTarget }

    public static func reading(_ reading: String) -> Self {
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)
        return .init(composingText: composingText, inputStyle: .direct, conversionRangeEnd: nil, selectedText: nil)
    }
}
