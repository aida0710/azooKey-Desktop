import KanaKanjiConverterModule

/// Formal reading edits that do not require candidates, a converter, or learning.
public struct CompositionState: Sendable {
    public private(set) var composingText = ComposingText()
    public private(set) var lastInputStyle: InputStyle = .direct
    public private(set) var conversionRangeEnd: Int?

    public init() {}

    public init(checkpoint: CompositionCheckpoint) {
        self.composingText = checkpoint.composingText
        self.lastInputStyle = checkpoint.inputStyle
        self.conversionRangeEnd = checkpoint.conversionRangeEnd
    }

    public var isEmpty: Bool { self.composingText.isEmpty }
    public var convertTarget: String { self.composingText.convertTarget }
    public var readingCursorUTF16Offset: Int { self.composingText.convertTargetBeforeCursor.utf16.count }

    /// A value snapshot; calculating candidates from it cannot edit the live reading.
    public var conversionTarget: ComposingText {
        self.conversionRangeEnd.map { self.prefix(toReadingPosition: $0) } ?? self.composingText
    }

    public mutating func insertAtCursorPosition(_ string: String, inputStyle: InputStyle) {
        self.insertAtCursorPosition(pieces: string.map(InputPiece.character), inputStyle: inputStyle)
    }

    public mutating func insertAtCursorPosition(pieces: [InputPiece], inputStyle: InputStyle) {
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(pieces.map { .init(piece: $0, inputStyle: inputStyle) })
    }

    /// Returns whether a new separator was inserted, independently of candidate refresh policy.
    @discardableResult
    public mutating func insertCompositionSeparator(inputStyle: InputStyle) -> Bool {
        self.conversionRangeEnd = nil
        self.moveCursorToEnd()
        guard self.composingText.input.last?.piece != .compositionSeparator else {
            return false
        }
        self.insertAtCursorPosition(pieces: [.compositionSeparator], inputStyle: inputStyle)
        return true
    }

    public mutating func editSegment(count: Int, selectedCount: ComposingCount? = nil) {
        guard !self.isEmpty else {
            return
        }
        let currentRangeEnd: Int
        if let selectedCount {
            var remaining = self.composingText
            remaining.prefixComplete(composingCount: selectedCount)
            currentRangeEnd = self.convertTarget.count - remaining.convertTarget.count
        } else {
            currentRangeEnd = self.conversionRangeEnd ?? self.convertTarget.count
        }
        self.conversionRangeEnd = min(max(1, currentRangeEnd + count), self.convertTarget.count)
    }

    public mutating func moveCursor(_ movement: CompositionCursorMovement) {
        let offset = switch movement {
        case .backward: -1
        case .forward: 1
        case .start: -self.composingText.convertTargetCursorPosition
        case .end: self.convertTarget.count - self.composingText.convertTargetCursorPosition
        }
        _ = self.composingText.moveCursorFromCursorPosition(count: offset)
        self.conversionRangeEnd = nil
    }

    public mutating func deleteForwardFromCursorPosition() {
        self.composingText.deleteForwardFromCursorPosition(count: 1)
        self.conversionRangeEnd = nil
    }

    public mutating func deleteBackwardFromCursorPosition(count: Int = 1) {
        self.conversionRangeEnd = nil
        self.composingText.deleteBackwardFromCursorPosition(count: count)
    }

    public mutating func prefixComplete(composingCount: ComposingCount) {
        self.composingText.prefixComplete(composingCount: composingCount)
        // A commit from the middle must leave a valid cursor in the remaining input.
        self.moveCursorToEnd()
        self.conversionRangeEnd = nil
    }

    public mutating func clearConversionRange() {
        self.conversionRangeEnd = nil
    }

    public mutating func stopComposition() {
        self.composingText.stopComposition()
        self.conversionRangeEnd = nil
        self.lastInputStyle = .direct
    }

    public func checkpoint(selectedText: String? = nil) -> CompositionCheckpoint? {
        guard !self.isEmpty else {
            return nil
        }
        return .init(composingText: self.composingText, inputStyle: self.lastInputStyle,
                     conversionRangeEnd: self.conversionRangeEnd, selectedText: selectedText)
    }

    public func consumesWholeComposition(composingCount: ComposingCount) -> Bool {
        var remaining = self.composingText
        remaining.prefixComplete(composingCount: composingCount)
        return remaining.isEmpty
    }

    public func romanInputForSelection(composingCount: ComposingCount? = nil) -> (text: String, composingCount: ComposingCount) {
        let composingCount = composingCount ?? .surfaceCount(self.conversionRangeEnd ?? self.convertTarget.count)
        if case .inputCount(let count) = composingCount {
            return (self.composingText.input.prefix(count).map(\.piece).inputString(preferIntention: false), composingCount)
        }
        var remaining = self.composingText
        remaining.prefixComplete(composingCount: composingCount)
        // Preserve original keys at boundaries such as 「ん|ご」 and 「っ|て」.
        let inputCount = (0...self.composingText.input.count).reversed().first { count in
            var suffix = self.composingText
            suffix.prefixComplete(composingCount: .inputCount(count))
            return suffix.convertTarget == remaining.convertTarget
        }
        if let inputCount {
            return (self.composingText.input.prefix(inputCount).map(\.piece).inputString(preferIntention: false), .inputCount(inputCount))
        }
        // 「き|ょ」 has no matching key boundary; the formal prefix keeps only its selected reading.
        let selectedReadingCount = self.convertTarget.count - remaining.convertTarget.count
        let selectedInput = self.prefix(toReadingPosition: selectedReadingCount)
        return (selectedInput.input.map(\.piece).inputString(preferIntention: false), composingCount)
    }

    mutating func resetInputStyle() {
        self.lastInputStyle = .direct
    }

    mutating func replaceAfterPrediction(_ composingText: ComposingText) {
        self.composingText = composingText
        self.lastInputStyle = .direct
    }

    private mutating func moveCursorToEnd() {
        _ = self.composingText.moveCursorFromCursorPosition(count: self.convertTarget.count - self.composingText.convertTargetCursorPosition)
    }

    private func prefix(toReadingPosition position: Int) -> ComposingText {
        var prefix = self.composingText
        _ = prefix.moveCursorFromCursorPosition(count: position - prefix.convertTargetCursorPosition)
        return prefix.prefixToCursorPosition()
    }
}
