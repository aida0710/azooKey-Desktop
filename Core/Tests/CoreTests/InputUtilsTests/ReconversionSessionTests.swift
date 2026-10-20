import Core
import Testing

private func document(before: String = "前", selected: String = "", after: String = "後",
                      start: Int? = nil, reversed: Bool = false, editable: Bool = true,
                      sensitive: Bool = false) -> ReconversionContext {
    let start = start ?? before.unicodeScalars.count
    let end = start + selected.unicodeScalars.count
    return .init(before: before, selected: selected, after: after,
                 cursor: reversed ? start : end, anchor: reversed ? end : start,
                 canReplace: editable, isSensitive: sensitive)
}

@Test func undoWaitsForTheExactHostDeletionBeforeRestoringTheReading() throws {
    let session = ReconversionSession()
    session.recordCommit("橋", checkpoint: .reading("はし"), context: document())
    let committed = document(before: "前橋")
    let replacement = try session.prepareUndo(in: committed)
    #expect(replacement.offset == -1)
    #expect(replacement.count == 1)
    #expect(throws: ReconversionSession.Failure.changedContext) {
        try session.confirm(replacement.token, in: committed)
    }
    let restored = try session.confirm(replacement.token, in: document())
    #expect(restored.checkpoint.reading == "はし")
    #expect(restored.originalText == "橋")
    #expect(throws: ReconversionSession.Failure.staleRequest) {
        try session.confirm(replacement.token, in: document())
    }
}

@Test(arguments: [false, true])
func selectionReplacementUsesTheSameRangeInEitherDirection(reversed: Bool) throws {
    let session = ReconversionSession()
    let selected = document(selected: "日本語", reversed: reversed)
    let replacement = try session.prepareSelection(in: selected, reading: "にほんご")
    #expect(replacement.offset == (reversed ? 0 : -3))
    #expect(replacement.count == 3)
    let restored = try session.confirm(replacement.token, in: document())
    #expect(restored.checkpoint.reading == "にほんご")
    #expect(restored.originalText == "日本語")
}

@Test func unsupportedReadonlyAndPrivateInputsNeverProduceAReplacement() {
    let contexts = [
        document(selected: "橋", editable: false),
        document(selected: "橋", sensitive: true),
        ReconversionContext(before: "", selected: "橋", after: "", cursor: 9, anchor: 0,
                            canReplace: true, isSensitive: false)
    ]
    for context in contexts {
        #expect(throws: ReconversionSession.Failure.self) {
            try ReconversionSession().prepareSelection(in: context, reading: "はし")
        }
    }
}

@Test func missingReadingLeavesTheSelectedWordUntouched() {
    #expect(throws: ReconversionSession.Failure.readingRequired) {
        try ReconversionSession().prepareSelection(in: document(selected: "相田"), reading: nil)
    }
}

@Test func movingTheCursorOrChangingTheDocumentInvalidatesCommitUndo() {
    let changedContexts = [
        document(before: "前端"),
        document(before: "前橋", start: 3),
        document(before: "前橋", after: "別"),
        document(before: "橋", start: 1),
        document(before: "前", selected: "橋")
    ]
    for context in changedContexts {
        let session = ReconversionSession()
        session.recordCommit("橋", checkpoint: .reading("はし"), context: document())
        #expect(throws: ReconversionSession.Failure.changedContext) {
            try session.prepareUndo(in: context)
        }
    }
}

@Test func focusChangeClearsBothCommitHistoryAndPendingReplacement() throws {
    let session = ReconversionSession()
    session.recordCommit("橋", checkpoint: .reading("はし"), context: document())
    let replacement = try session.prepareUndo(in: document(before: "前橋"))
    session.clear()
    #expect(throws: ReconversionSession.Failure.staleRequest) {
        try session.confirm(replacement.token, in: document())
    }
    #expect(throws: ReconversionSession.Failure.noRecentCommit) {
        try session.prepareUndo(in: document(before: "前橋"))
    }
}

@Test func replacementUsesScalarCountsForEmojiAndDoesNotNormalizeDocumentText() throws {
    let session = ReconversionSession()
    let text = "👩‍💻e\u{301}"
    let replacement = try session.prepareSelection(in: document(selected: text), reading: "えもじ")
    #expect(replacement.count == 5)
    #expect(replacement.offset == -5)
    #expect(try session.confirm(replacement.token, in: document()).originalText == text)

    session.recordCommit("e\u{301}", checkpoint: .reading("いー"), context: document())
    #expect(throws: ReconversionSession.Failure.changedContext) {
        try session.prepareUndo(in: document(before: "前é", start: 3))
    }
}

@Test func readingResolutionUsesOnlyKanaOrAnUnambiguousDictionaryEntry() {
    let entries = [Config.UserDictionaryEntry(word: "相田", reading: "あいだ")]
    #expect(ReconversionReading.resolve("相田", dictionary: entries) == "あいだ")
    #expect(ReconversionReading.resolve("ニホンゴ", dictionary: []) == "にほんご")
    #expect(ReconversionReading.resolve("日本語", dictionary: []) == nil)
    #expect(ReconversionReading.resolve("相田", dictionary: entries + [.init(word: "相田", reading: "そうだ")]) == nil)
}
