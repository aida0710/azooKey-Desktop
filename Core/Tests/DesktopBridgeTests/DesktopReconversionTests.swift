import Core
@testable import DesktopBridge
import Testing

@MainActor
extension DesktopSegmentEditingTests {
    private func reconversionDocument(before: String = "前", selected: String = "", sensitive: Bool = false) -> ReconversionContext {
        .init(before: before, selected: selected, after: "後",
              cursorUTF16: before.utf16.count + selected.utf16.count,
              anchorUTF16: before.utf16.count, canReplace: true, isSensitive: sensitive)
    }

    private func typeReconversionText(_ text: String, into session: DesktopSession) {
        for character in text {
            let value = String(character)
            _ = session.key(.init(modifierFlags: [], characters: value, charactersIgnoringModifiers: value, keyCode: 0))
        }
    }

    @Test func commitUndoRestoresTheOriginalRomanInputAndSelectedCandidate() throws {
        try withSession(liveConversion: false, treeCandidates: false) { session in
            session.reconversionContext = reconversionDocument()
            typeReconversionText("hashi", into: session)
            _ = session.key(key(49))
            var snapshot = session.key(key(49))
            let bridge = try #require(snapshot.candidates.first { $0.text == "橋" })
            snapshot = session.select(candidateIndex: bridge.index, submit: true, expectedGeneration: snapshot.generation)
            #expect(snapshot.commits == ["橋"])
            #expect(snapshot.canUndoCommit)

            session.reconversionContext = reconversionDocument(before: "前橋")
            let replacement = try #require(session.prepareReconversion(undo: true).reconversion)
            snapshot = session.confirmReconversion(replacement.token)
            #expect(snapshot.reconversionError == "changed_context")
            #expect(snapshot.preedit.isEmpty)

            session.reconversionContext = reconversionDocument()
            snapshot = session.confirmReconversion(replacement.token)
            #expect(snapshot.reading == "はし")
            #expect(try selectedCandidate(snapshot).text == "橋")
            #expect(snapshot.commits.isEmpty)
            snapshot = session.key(key(109))
            #expect(snapshot.commits == ["hashi"])
            #expect(snapshot.preedit.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func cancelingSelectionReconversionRestoresTheOriginalExactlyOnce(live: Bool) throws {
        try withSession(liveConversion: live, treeCandidates: false) { session in
            session.reconversionContext = reconversionDocument(selected: "日本語")
            var snapshot = session.prepareReconversion(undo: false)
            #expect(snapshot.reconversionError == "reading_required")
            #expect(snapshot.reconversion == nil)
            #expect(snapshot.preedit.isEmpty)
            snapshot = session.prepareReconversion(undo: false, reading: "にほんご")
            let replacement = try #require(snapshot.reconversion)
            session.reconversionContext = reconversionDocument()
            snapshot = session.confirmReconversion(replacement.token)
            #expect(snapshot.reading == "にほんご")
            #expect(snapshot.candidates.contains { $0.text == "日本語" })
            #expect(snapshot.commits.isEmpty)
            for _ in 0..<(live ? 2 : 3) { snapshot = session.key(key(53)) }
            #expect(snapshot.commits == ["日本語"])
            #expect(snapshot.preedit.isEmpty)
            #expect(session.key(key(53)).commits.isEmpty)
        }
    }

    @Test func reconversionNeverDeletesFromPrivateChangedOrUnfocusedContexts() throws {
        try withSession(liveConversion: false, treeCandidates: false) { session in
            session.reconversionContext = reconversionDocument(selected: "日本語", sensitive: true)
            #expect(session.prepareReconversion(undo: false, reading: "にほんご").reconversion == nil)
            session.reconversionContext = nil
            #expect(session.prepareReconversion(undo: false, reading: "にほんご").reconversionError == "replacement_unavailable")
            session.reconversionContext = reconversionDocument(selected: "日本語")
            let replacement = try #require(session.prepareReconversion(undo: false, reading: "にほんご").reconversion)
            _ = session.reset(commit: false)
            session.reconversionContext = reconversionDocument()
            let snapshot = session.confirmReconversion(replacement.token)
            #expect(snapshot.reconversionError == "stale_request")
            #expect(snapshot.preedit.isEmpty)
            #expect(snapshot.commits.isEmpty)
        }
    }

    @Test func partialCommitDuringReconversionLeavesTheOriginalAvailableForCancel() throws {
        try withSession(liveConversion: true, treeCandidates: false) { session in
            session.reconversionContext = reconversionDocument(selected: "日本語")
            let replacement = try #require(session.prepareReconversion(undo: false, reading: "にほんご").reconversion)
            session.reconversionContext = reconversionDocument()
            _ = session.confirmReconversion(replacement.token)
            _ = session.key(key(123, shift: true))
            let attempted = session.key(key(36))
            #expect(attempted.commits.isEmpty)
            #expect(attempted.reconversionError == "whole_selection_required")
            #expect(session.reset(commit: false).commits == ["日本語"])
            #expect(session.reset(commit: false).commits.isEmpty)
        }
    }
}
