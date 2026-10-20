import Core
@testable import DesktopBridge
import Testing

@MainActor
@Suite struct DesktopReadingCommitKeyTests {
    struct RomanBoundary: Sendable {
        let input: String
        let halfWidth: String
        let fullWidth: String
        let suffix: String
    }

    private let fixture = DesktopReadingTestSupport()

    @Test(arguments: [
        (keyCode: UInt16(97), text: "にほんご"),
        (keyCode: UInt16(98), text: "ニホンゴ"),
        (keyCode: UInt16(100), text: "ﾆﾎﾝｺﾞ"),
        (keyCode: UInt16(101), text: "ｎｉｈｏｎｇｏ"),
        (keyCode: UInt16(109), text: "nihongo")
    ])
    func functionKeysConvertTheWholeReadingWithoutCandidates(form: (keyCode: UInt16, text: String)) throws {
        var session = DesktopReadingSession()
        try fixture.type("nihongo", into: &session)
        let committed = try session.key(fixture.key(form.keyCode))
        #expect(committed.commits == [form.text])
        #expect(committed.reading.isEmpty)
        #expect(committed.preedit.isEmpty)
        #expect(committed.inputState == "none")
        #expect(committed.candidateCompletions == nil)
        #expect(try fixture.type("a", into: &session).preedit == "あ")
    }

    @Test(arguments: [
        (keyCode: UInt16(97), text: "に"),
        (keyCode: UInt16(98), text: "ニ"),
        (keyCode: UInt16(100), text: "ﾆ"),
        (keyCode: UInt16(101), text: "ｎｉ"),
        (keyCode: UInt16(109), text: "ni")
    ])
    func functionKeysKeepTheSuffixWhenTheSelectedCandidatesWorkerHasStopped(form: (keyCode: UInt16, text: String)) throws {
        var session = DesktopReadingSession()
        try fixture.type("nihongo", into: &session)
        let request = try fixture.request(from: &session)
        _ = try session.adoptCandidates(fixture.batch(request, words: ["荷"], prefixLength: 1))
        _ = try session.selectCurrentCandidate(index: 0)
        session.candidateWorkerUnavailable()
        let committed = try session.key(fixture.key(form.keyCode))
        #expect(committed.commits == [form.text])
        #expect(committed.preedit == "ほんご")
        #expect(committed.inputState == "composing")
        #expect(committed.request == "candidates")
        #expect(committed.candidateCompletions == nil)
        let suffix = try session.key(fixture.key(36))
        #expect(suffix.commits == ["ほんご"])
        #expect(suffix.candidateCompletions == nil)
    }

    @Test(arguments: [
        (keyCode: UInt16(97), text: "に"),
        (keyCode: UInt16(98), text: "ニ"),
        (keyCode: UInt16(100), text: "ﾆ"),
        (keyCode: UInt16(101), text: "ｎｉ"),
        (keyCode: UInt16(109), text: "ni")
    ])
    func functionKeysUseAnEditedSegmentWhileItsCandidatesAreStillPending(form: (keyCode: UInt16, text: String)) throws {
        var session = DesktopReadingSession()
        try fixture.type("nihongo", into: &session)
        for _ in 0..<3 { _ = try session.key(fixture.key(123, modifiers: .shift)) }
        let request = try fixture.request(from: &session)
        let committed = try session.key(fixture.key(form.keyCode))
        #expect(committed.commits == [form.text])
        #expect(committed.preedit == "ほんご")
        #expect(committed.candidateCompletions == nil)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(fixture.batch(request, words: ["荷"], prefixLength: 1))
        }
        #expect(try fixture.type("a", into: &session).preedit == "ほんごあ")
    }

    @Test(arguments: [
        RomanBoundary(input: "kyo", halfWidth: "き", fullWidth: "き", suffix: "ょ"),
        RomanBoundary(input: "kanta", halfWidth: "kan", fullWidth: "ｋａｎ", suffix: "た"),
        RomanBoundary(input: "kitte", halfWidth: "kit", fullWidth: "ｋｉｔ", suffix: "て")
    ], [UInt16(101), UInt16(109)])
    func romanFunctionKeysPreserveTheOriginalKeyBoundary(
        example: RomanBoundary, keyCode: UInt16
    ) throws {
        var session = DesktopReadingSession()
        let reading = try fixture.type(example.input, into: &session).reading
        let request = try fixture.request(from: &session)
        _ = try session.adoptCandidates(fixture.batch(
            request, words: ["部分候補"], prefixLength: reading.count - example.suffix.count))
        _ = try session.selectCurrentCandidate(index: 0)
        let committed = try session.key(fixture.key(keyCode))
        #expect(committed.commits == [keyCode == 101 ? example.fullWidth : example.halfWidth])
        #expect(committed.preedit == example.suffix)
        #expect(committed.candidateCompletions == nil)
    }

    @Test func previewedPartialCandidateDoesNotNarrowWholeReadingFunctionConversion() throws {
        var session = DesktopReadingSession()
        try fixture.type("nihongo", into: &session)
        _ = try session.key(fixture.key(49))
        let request = try fixture.request(from: &session)
        _ = try session.adoptCandidates(fixture.batch(request, words: ["荷"], prefixLength: 1))
        #expect(try session.key(fixture.key(49)).inputState == "previewing")
        let committed = try session.key(fixture.key(109))
        #expect(committed.commits == ["nihongo"])
        #expect(committed.reading.isEmpty)
        #expect(committed.candidateCompletions == nil)
    }

    @Test func numberKeysCommitTheRealCandidateOnTheSelectedPage() throws {
        var session = DesktopReadingSession()
        try fixture.type("nihongo", into: &session)
        let request = try fixture.request(from: &session)
        let batch = try fixture.batch(request, words: (0..<12).map { "候補\($0)" })
        _ = try session.adoptCandidates(batch)
        let selected = try session.selectCurrentCandidate(index: 9)
        #expect(selected.showCandidateIndex)
        #expect(selected.pageStart == 9)
        let committed = try session.key(.init(
            modifierFlags: [], characters: "2", charactersIgnoringModifiers: "2", keyCode: 19))
        #expect(committed.commits == ["候補10"])
        #expect(committed.candidateCompletions?.first?.candidateID == batch.candidates[10].candidateID)
        #expect(committed.candidateCompletions?.first?.batchID == batch.batchID)
        #expect(committed.reading.isEmpty)
        #expect(!committed.showCandidateIndex)
    }

    @Test func anUnavailableNumberKeepsTheSelectedCandidateAndItsPage() throws {
        var session = DesktopReadingSession()
        try fixture.type("nihongo", into: &session)
        let request = try fixture.request(from: &session)
        _ = try session.adoptCandidates(fixture.batch(request, words: (0..<10).map { "候補\($0)" }))
        let selected = try session.selectCurrentCandidate(index: 9)
        let unavailable = try session.key(.init(
            modifierFlags: [], characters: "9", charactersIgnoringModifiers: "9", keyCode: 25))
        #expect(unavailable.commits.isEmpty)
        #expect(unavailable.preedit == selected.preedit)
        #expect(unavailable.selection == selected.selection)
        #expect(unavailable.pageStart == 9)
        #expect(unavailable.candidateCompletions == nil)
        let committed = try session.key(.init(
            modifierFlags: [], characters: "1", charactersIgnoringModifiers: "1", keyCode: 18))
        #expect(committed.commits == ["候補9"])
    }

    @Test func aNumberCanCommitAPrefixBeforeEnterFinishesTheWaitingSuffix() throws {
        var session = DesktopReadingSession()
        try fixture.type("nihongo", into: &session)
        let request = try fixture.request(from: &session)
        let batch = try fixture.batch(request, words: ["荷", "二"], prefixLength: 1)
        _ = try session.adoptCandidates(batch)
        _ = try session.selectCurrentCandidate(index: 0)
        let committed = try session.key(.init(
            modifierFlags: [], characters: "2", charactersIgnoringModifiers: "2", keyCode: 19))
        #expect(committed.commits == ["二"])
        #expect(committed.preedit == "ほんご")
        #expect(committed.request == "candidates")
        #expect(committed.candidateCompletions?.first?.candidateID == batch.candidates[1].candidateID)
        let suffix = try session.key(fixture.key(36))
        #expect(suffix.commits == ["ほんご"])
        #expect(suffix.candidateCompletions == nil)
    }

    @Test func aNumberDuringPendingConversionEditsTheReadingAndRetiresTheOldReply() throws {
        var session = DesktopReadingSession()
        try fixture.type("nihongo", into: &session)
        _ = try session.key(fixture.key(49))
        let request = try fixture.request(from: &session)
        let edited = try session.key(.init(
            modifierFlags: [], characters: "2", charactersIgnoringModifiers: "2", keyCode: 19))
        #expect(edited.commits.isEmpty)
        #expect(edited.preedit == "にほんご2")
        #expect(!edited.showCandidateIndex)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(fixture.batch(request))
        }
    }
}
