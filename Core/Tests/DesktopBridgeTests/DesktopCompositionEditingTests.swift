import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
extension DesktopSegmentEditingTests {
    @Test(arguments: [false, true])
    func leftArrowInsertsAndDeletesAtTheDisplayedReadingCursor(live: Bool) throws {
        try withSession(liveConversion: live, treeCandidates: false) { session in
            _ = type("nihongo", into: session)
            var snapshot = session.key(key(123))
            #expect(snapshot.preedit == "にほんご")
            #expect(snapshot.cursor == 3)
            #expect(snapshot.readingCursor == 3)
            #expect(snapshot.inputState == "composing")

            snapshot = type("a", into: session)
            #expect(snapshot.preedit == "にほんあご")
            #expect(snapshot.cursor == 4)
            snapshot = session.key(key(51))
            #expect(snapshot.preedit == "にほんご")
            #expect(snapshot.cursor == 3)
            snapshot = session.key(key(0x75))
            #expect(snapshot.preedit == "にほん")
            #expect(snapshot.cursor == 3)
        }
    }

    @Test(arguments: [false, true])
    func homeAndEndMoveTheReadingCursorWithoutCommitting(live: Bool) throws {
        try withSession(liveConversion: live, treeCandidates: false) { session in
            _ = type("nihongo", into: session)
            var snapshot = session.key(key(0x73))
            #expect(snapshot.preedit == "にほんご")
            #expect(snapshot.cursor == 0)
            snapshot = session.key(key(51))
            #expect(snapshot.preedit == "にほんご")
            #expect(snapshot.cursor == 0)
            snapshot = type("a", into: session)
            #expect(snapshot.preedit == "あにほんご")
            snapshot = session.key(key(0x77))
            #expect(snapshot.cursor == 5)
            snapshot = session.key(key(0x75))
            #expect(snapshot.preedit == "あにほんご")
            snapshot = type("i", into: session)
            #expect(snapshot.preedit == "あにほんごい")
            #expect(snapshot.cursor == 6)
            #expect(snapshot.commits.isEmpty)
        }
    }

    @Test func committingFromTheMiddleLeavesAValidCursorForTheNextComposition() throws {
        try withSession(liveConversion: true, treeCandidates: false) { session in
            _ = type("nihongo", into: session)
            _ = session.key(key(123))
            let committed = session.key(key(109))
            #expect(committed.commits == ["nihongo"])
            #expect(committed.preedit.isEmpty)
            let next = type("ka", into: session)
            #expect(next.reading == "か")
            #expect(next.cursor > 0)
        }
    }

    @Test(arguments: [false, true])
    func unfinishedRomanInputCanBeEditedBeforeTheSuffix(live: Bool) throws {
        try withSession(liveConversion: live, treeCandidates: false) { session in
            _ = type("niky", into: session)
            var snapshot = session.key(key(123))
            #expect(snapshot.preedit == "にky")
            #expect(snapshot.cursor == 2)
            snapshot = session.key(key(0x75))
            #expect(snapshot.preedit == "にk")
            snapshot = type("a", into: session)
            #expect(snapshot.preedit == "にか")
            #expect(snapshot.cursor == 2)
        }
    }

    @Test(arguments: [false, true], ["👩‍💻", "𠮷", "e\u{301}", "🇯🇵"])
    func editingTreatsAnEntireGraphemeAsOneCharacter(live: Bool, grapheme: String) throws {
        try withSession(liveConversion: live, treeCandidates: false) { session in
            _ = type(grapheme + "a", into: session)
            var snapshot = session.key(key(123))
            #expect(snapshot.preedit == grapheme + "あ")
            #expect(snapshot.cursor == grapheme.unicodeScalars.count)
            snapshot = session.key(key(51))
            #expect(snapshot.preedit == "あ")
            #expect(snapshot.cursor == 0)
            #expect(snapshot.commits.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func editingAPrefixThenReturningToReadingDoesNotMoveTheInsertionCursorToThatPrefix(live: Bool) throws {
        try withSession(liveConversion: live, treeCandidates: false) { session in
            _ = type("nihongo", into: session)
            _ = session.key(key(123, shift: true))
            var snapshot = session.key(key(0x73))
            #expect(snapshot.preedit == "にほんご")
            #expect(snapshot.cursor == 0)
            snapshot = type("a", into: session)
            #expect(snapshot.preedit == "あにほんご")
            #expect(snapshot.cursor == 1)
            snapshot = session.key(key(49))
            #expect(snapshot.reading == "あにほんご")
            #expect(snapshot.commits.isEmpty)
        }
    }

    @Test(arguments: [UInt16(101), UInt16(109)])
    func romanConversionPreservesOriginalInputAtNasalAndGeminateBoundaries(functionKey: UInt16) throws {
        let scenarios = [
            (input: "kyo", prefix: "き", suffix: "ょ"),
            (input: "kanta", prefix: "kan", suffix: "た"),
            (input: "nihongo", prefix: "nihon", suffix: "ご"),
            (input: "kitte", prefix: "kit", suffix: "て")
        ]
        try withSession(liveConversion: false, treeCandidates: false) { session in
            for scenario in scenarios {
                _ = session.reset(commit: false)
                _ = type(scenario.input, into: session)
                _ = session.key(key(123, shift: true))
                let snapshot = session.key(key(functionKey))
                let expectedPrefix = functionKey == 101
                    ? scenario.prefix.applyingTransform(.fullwidthToHalfwidth, reverse: true)!
                    : scenario.prefix
                #expect(snapshot.commits == [expectedPrefix])
                #expect(snapshot.reading == scenario.suffix)
            }
        }
    }
}
