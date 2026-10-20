import Core
@testable import DesktopBridge
import Foundation
import KanaKanjiConverterModule

@MainActor
struct DesktopReadingTestSupport {
    func key(_ code: UInt16, modifiers: KeyEventCore.ModifierFlag = []) -> KeyEventCore {
        .init(modifierFlags: modifiers, characters: nil, charactersIgnoringModifiers: nil, keyCode: code)
    }

    @discardableResult
    func type(_ text: String, into session: inout DesktopReadingSession) throws -> DesktopSnapshot {
        var snapshot = session.snapshot()
        for character in text {
            snapshot = try session.key(.init(
                modifierFlags: [], characters: String(character),
                charactersIgnoringModifiers: String(character), keyCode: 0))
        }
        return snapshot
    }

    func request(
        from session: inout DesktopReadingSession, leftContext: String = ""
    ) throws -> DesktopCandidateRequest {
        try session.prepareCandidates(context: .init(
            context: "field", readingProcessGeneration: "reader", focusEpoch: 1,
            compositionRevision: 0, settingsRevision: 0, leftContext: leftContext, rightContext: "", privateInput: false))
    }

    func batch(
        _ request: DesktopCandidateRequest, words: [String] = ["日本語", "二本語"], prefixLength: Int? = nil
    ) throws -> DesktopCandidateBatch {
        let count: ComposingCount = prefixLength.map(ComposingCount.surfaceCount)
            ?? .inputCount(request.composition.input.count)
        return try .init(
            authority: request.authority, workerGeneration: "converter", batchID: request.authority.requestID,
            candidates: words.enumerated().map { index, text in
                try .init(candidateID: "candidate-\(index)", text: text, composingCount: .init(count),
                          presentation: .init(tokens: [], annotation: nil, extraValues: [:],
                                              score: nil, comparisonGroup: nil, commitScope: nil))
            })
    }
}
