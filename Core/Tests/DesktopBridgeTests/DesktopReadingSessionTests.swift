import Core
@testable import DesktopBridge
import Foundation
import KanaKanjiConverterModule
import Testing

@MainActor
@Suite struct DesktopReadingSessionTests {
    private func key(_ code: UInt16, modifiers: KeyEventCore.ModifierFlag = []) -> KeyEventCore {
        .init(modifierFlags: modifiers, characters: nil, charactersIgnoringModifiers: nil, keyCode: code)
    }

    @discardableResult
    private func type(_ text: String, into session: inout DesktopReadingSession) throws -> DesktopSnapshot {
        var response = session.snapshot()
        for character in text {
            response = try session.key(.init(
                modifierFlags: [], characters: String(character),
                charactersIgnoringModifiers: String(character), keyCode: 0))
        }
        return response
    }

    @Test func editingAndCommittingReadingNeedNoCandidateResponse() throws {
        var session = DesktopReadingSession()
        let entered = try type("nihongo", into: &session)
        #expect(entered.preedit == "にほんご")
        #expect(entered.candidates.isEmpty)
        _ = try session.key(key(123))
        let inserted = try type("a", into: &session)
        #expect(inserted.preedit == "にほんあご")
        #expect(inserted.cursor == 4)
        let removed = try session.key(key(51))
        #expect(removed.preedit == "にほんご")
        #expect(removed.cursor == 3)
        let shortened = try session.key(key(0x75))
        #expect(shortened.preedit == "にほん")
        #expect(shortened.cursor == 3)
        let committed = try session.key(key(0x24))
        #expect(committed.commits == ["にほん"])
        #expect(committed.preedit.isEmpty)
        #expect(committed.inputState == "none")
        let emptyEnter = try session.key(key(0x24))
        #expect(!emptyEnter.consumed)
        let nextInput = try type("a", into: &session)
        #expect(nextInput.preedit == "あ")
    }

    @Test func homeEndAndUnfinishedRomanInputKeepTheirFormalCursor() throws {
        var session = DesktopReadingSession()
        _ = try type("niky", into: &session)
        let moved = try session.key(key(123))
        #expect(moved.cursor == 2)
        let removed = try session.key(key(0x75))
        #expect(removed.preedit == "にk")
        let completed = try type("a", into: &session)
        #expect(completed.preedit == "にか")
        let start = try session.key(key(0x73))
        #expect(start.cursor == 0)
        let prefix = try type("a", into: &session)
        #expect(prefix.preedit == "あにか")
        let end = try session.key(key(0x77))
        #expect(end.cursor == 3)
        let suffix = try type("i", into: &session)
        #expect(suffix.preedit == "あにかい")
    }

    @Test(arguments: [UInt16(0x24), UInt16(0x4C)])
    func returnAndKeypadEnterCommitOnceWithoutANewline(keyCode: UInt16) throws {
        var session = DesktopReadingSession()
        _ = try type("nihongo", into: &session)
        let committed = try session.key(key(keyCode))
        #expect(committed.commits == ["にほんご"])
        #expect(committed.preedit.isEmpty)
        let empty = try session.key(key(keyCode))
        #expect(!empty.consumed)
        #expect(empty.commits.isEmpty)
    }

    @Test(arguments: ["👩‍💻", "𠮷", "e\u{301}", "🇯🇵"])
    func theClientCursorCountsScalarsAndDeletionKeepsGraphemes(grapheme: String) throws {
        var session = DesktopReadingSession()
        _ = try type(grapheme + "a", into: &session)
        let moved = try session.key(key(123))
        #expect(moved.cursor == grapheme.unicodeScalars.count)
        #expect(moved.readingCursor == moved.cursor)
        let deleted = try session.key(key(51))
        #expect(deleted.preedit == "あ")
        #expect(deleted.cursor == 0)
        #expect(deleted.commits.isEmpty)
    }

    @Test func cancellationAndResetLeaveNoReadingForTheNextInput() throws {
        var session = DesktopReadingSession()
        _ = try type("nihongo", into: &session)
        let cancelled = try session.key(key(53))
        #expect(cancelled.preedit.isEmpty)
        #expect(cancelled.commits.isEmpty)
        _ = try type("ka", into: &session)
        let reset = try session.reset(commit: true)
        #expect(reset.commits == ["か"])
        #expect(reset.preedit.isEmpty)
        let emptyReset = try session.reset(commit: true)
        #expect(emptyReset.commits.isEmpty)
        let nextInput = try type("i", into: &session)
        #expect(nextInput.preedit == "い")
    }

    @Test(arguments: [UInt16(49), UInt16(48), UInt16(101), UInt16(109), UInt16(125)])
    func unsupportedActionsPreserveReadingStateAndCursor(keyCode: UInt16) throws {
        var session = DesktopReadingSession()
        _ = try type("nihongo", into: &session)
        _ = try session.key(key(123))
        let before = session.snapshot()
        #expect(throws: DesktopReadingSession.Failure.unsupportedAction) {
            try session.key(key(keyCode))
        }
        let after = session.snapshot()
        #expect(after.reading == before.reading)
        #expect(after.cursor == before.cursor)
        #expect(after.generation == before.generation)
        #expect(after.inputState == before.inputState)
        #expect(after.commits.isEmpty)
        let nextInput = try type("a", into: &session)
        #expect(nextInput.preedit == "にほんあご")
    }
}
