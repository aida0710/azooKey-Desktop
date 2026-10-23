import KanaKanjiConverterModuleWithDefaultDictionary

extension ComposingText {
    func prefix(toReadingPosition position: Int) -> ComposingText {
        var prefix = self
        _ = prefix.moveCursorFromCursorPosition(count: position - prefix.convertTargetCursorPosition)
        return prefix.prefixToCursorPosition()
    }

    func isWholeComposingText(composingCount: ComposingCount) -> Bool {
        var remaining = self
        remaining.prefixComplete(composingCount: composingCount)
        return remaining.isEmpty
    }
}
