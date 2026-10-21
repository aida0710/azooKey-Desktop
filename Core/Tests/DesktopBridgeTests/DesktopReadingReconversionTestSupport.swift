import Core
@testable import DesktopBridge
import Testing

@MainActor
enum DesktopReadingReconversionTestSupport {
    static func document(before: String = "前", selected: String = "", after: String = "後") -> ReconversionContext {
        .init(before: before, selected: selected, after: after,
              cursorUTF16: before.utf16.count + selected.utf16.count, anchorUTF16: before.utf16.count,
              canReplace: true, isSensitive: false)
    }

    static func key(_ code: UInt16 = 0, text: String? = nil) -> KeyEventCore {
        .init(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: code)
    }

    static func prepare(_ fixture: inout DesktopReadingWorkerFixture, selected: String = "日本語",
                        reading: String? = "にほんご") throws -> DesktopReadingWorkerResponse {
        try fixture.worker.process(.init(operation: "reconvert", reference: fixture.reference,
            candidateWorkerGeneration: reading == nil ? "converter" : nil,
            reconversionContext: document(selected: selected), reading: reading))
    }

    static func confirm(_ fixture: inout DesktopReadingWorkerFixture, token: String,
                        context: ReconversionContext = document()) throws -> DesktopReadingWorkerResponse {
        try fixture.worker.process(.init(operation: "confirm-reconversion", reference: fixture.reference,
            reconversionContext: context, reconversionToken: token))
    }

    static func originalCommit(_ fixture: inout DesktopReadingWorkerFixture) throws -> DesktopCandidateBatch {
        _ = try fixture.key(text: "nihongo")
        let batch = try fixture.batch()
        _ = try fixture.adopt(batch)
        let committed = try fixture.worker.process(.init(operation: "commit-candidate", reference: fixture.reference,
            selection: .init(batch: fixture.retained(batch), candidateID: "candidate"), reconversionContext: document()))
        #expect(committed.snapshot?.commits == ["日本語"])
        #expect(committed.snapshot?.canUndoCommit == true)
        #expect(committed.snapshot?.candidateCompletions?.count == 1)
        return batch
    }
}
