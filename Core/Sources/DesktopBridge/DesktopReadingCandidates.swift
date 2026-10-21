import Core
import Foundation

/// Candidate availability and an explicitly selected commit, owned by the reading process.
/// Adopting a batch never edits the composition or constructs an application snapshot.
struct DesktopReadingCandidates {
    enum Failure: Error, Equatable {
        case staleRequest
        case changedComposition
        case invalidBatch
        case invalidContext
        case selectionActive
        case unavailableCandidate
        case changedSettings
    }

    struct Commit {
        let text: String
        let remaining: CompositionState
        let completion: DesktopCandidateCompletion
    }

    private struct Pending {
        let request: DesktopCandidateRequest
        let encodedComposition: Data
        let context: DesktopReadingCandidateContext
    }

    private struct Accepted {
        let batch: DesktopCandidateBatch
        let encodedComposition: Data
        var context: DesktopReadingCandidateContext
        let consumption: [CandidateConsumption]
    }

    private struct Selection {
        var accepted: Accepted
        let index: Int
    }

    private let customInputTableRevisions: [String: String]

    init(customInputTableRevisions: [String: String] = [:]) {
        self.customInputTableRevisions = customInputTableRevisions
    }

    private var pending: Pending?
    private var available: Accepted?
    private var selection: Selection?

    var batch: DesktopCandidateBatch? { available?.batch }
    var selectionIndex: Int? { selection?.index }
    var selectedText: String? { selection.map { $0.accepted.batch.candidates[$0.index].text } }
    var selectedSuffix: String? { selection.map { $0.accepted.consumption[$0.index].remaining.convertTarget } }
    var selectedCount: ComposingCountSnapshot? {
        selection.map { $0.accepted.batch.candidates[$0.index].composingCount }
    }
    var selectedReading: String? {
        guard let selection else {
            return nil
        }
        let reading = selection.accepted.batch.candidates[selection.index].presentation.tokens.map(\.reading).joined()
        return reading.isEmpty ? selection.accepted.consumption[selection.index].consumedReading : reading
    }
    var preferredSelectionIndex: Int? {
        guard let available, !available.batch.candidates.isEmpty else {
            return nil
        }
        return available.consumption.firstIndex { $0.remaining.isEmpty } ?? 0
    }

    func restoredSelectionIndex(text: String) -> Int? {
        guard let available else {
            return nil
        }
        return available.batch.candidates.indices.first { index in
            available.batch.candidates[index].text.utf8.elementsEqual(text.utf8)
                && available.consumption[index].remaining.isEmpty
        }
    }

    func view(options: DesktopCandidateView.Options) throws -> DesktopCandidateView? {
        guard let available else {
            return nil
        }
        // Presentation is not authority over the reading. Derive every displayed scope
        // from the same formal consumption used when this candidate is committed.
        let items = zip(available.batch.candidates, available.consumption).map { candidate, consumption in
            DesktopCandidateItem(candidateID: candidate.candidateID, text: candidate.text,
                composingCount: candidate.composingCount, presentation: .init(
                    tokens: candidate.presentation.tokens, annotation: candidate.presentation.annotation,
                    extraValues: candidate.presentation.extraValues, score: candidate.presentation.score,
                    comparisonGroup: candidate.presentation.comparisonGroup,
                    commitScope: .init(consumedReading: consumption.consumedReading,
                                       remainingReading: consumption.remaining.convertTarget)))
        }
        let batch = available.batch
        let displayed = DesktopCandidateBatch(authority: batch.authority, workerGeneration: batch.workerGeneration,
            batchID: batch.batchID, candidates: items, mainCandidateID: batch.mainCandidateID)
        let selectedID = selection.map { $0.accepted.batch.candidates[$0.index].candidateID }
        return try DesktopCandidateView(batch: displayed, selectedCandidateID: selectedID, options: options)
    }

    mutating func prepare(
        composition: CompositionState, context: DesktopReadingCandidateContext
    ) throws -> DesktopCandidateRequest {
        guard selection == nil else { throw Failure.selectionActive }
        guard !context.context.isEmpty, !context.readingProcessGeneration.isEmpty,
              context.focusEpoch >= 0, context.compositionRevision >= 0,
              context.settingsRevision >= 0 else { throw Failure.invalidContext }
        let snapshot = try CompositionSnapshot.capture(composition, registeredCustomTables: customInputTableRevisions)
        let request = DesktopCandidateRequest(
            authority: context.authority(requestID: UUID().uuidString),
            composition: snapshot, leftContext: context.leftContext,
            rightContext: context.rightContext, privateInput: context.privateInput)
        guard try JSONEncoder().encode(request).count <= CompositionSnapshotLimits.jsonByteCount else {
            throw CompositionSnapshotError.limitExceeded("candidateRequest")
        }
        pending = .init(request: request, encodedComposition: try snapshot.encoded(), context: context)
        available = nil
        return request
    }

    mutating func adopt(
        _ batch: DesktopCandidateBatch, composition: CompositionState,
        context: DesktopReadingCandidateContext
    ) throws -> DesktopCandidateBatchReference {
        guard let pending, batch.authority == pending.request.authority,
              context == pending.context else { throw Failure.staleRequest }
        guard selection == nil else { throw Failure.selectionActive }
        try verifyComposition(composition, encodedComposition: pending.encodedComposition)
        guard try JSONEncoder().encode(batch).count <= CompositionSnapshotLimits.jsonByteCount else {
            throw CompositionSnapshotError.limitExceeded("candidateBatch")
        }
        guard !batch.workerGeneration.isEmpty, !batch.batchID.isEmpty,
              batch.candidates.allSatisfy({ !$0.candidateID.isEmpty && !$0.text.isEmpty }),
              Set(batch.candidates.map(\.candidateID)).count == batch.candidates.count,
              batch.mainCandidateID.map({ mainID in batch.candidates.contains { $0.candidateID == mainID } }) ?? true else {
            throw Failure.invalidBatch
        }
        // Validate the complete list before replacing the previous accepted batch.
        let consumption = try batch.candidates.map {
            try CandidateConsumption(composition: composition, count: $0.composingCount)
        }
        available = .init(batch: batch, encodedComposition: pending.encodedComposition, context: context, consumption: consumption)
        self.pending = nil
        return .init(authority: batch.authority, workerGeneration: batch.workerGeneration, batchID: batch.batchID)
    }

    mutating func select(
        _ choice: DesktopCandidateSelection, composition: CompositionState, context: DesktopReadingCandidateContext
    ) throws {
        guard let available, context == available.context,
              choice.batch == DesktopCandidateBatchReference(
                authority: available.batch.authority, workerGeneration: available.batch.workerGeneration,
                batchID: available.batch.batchID),
              let index = available.batch.candidates.firstIndex(where: { $0.candidateID == choice.candidateID }) else {
            throw Failure.unavailableCandidate
        }
        try verifyComposition(composition, encodedComposition: available.encodedComposition)
        selection = .init(accepted: available, index: index)
    }

    mutating func takeSelection(
        composition: CompositionState, context: DesktopReadingCandidateContext
    ) throws -> Commit {
        guard let selection, context == selection.accepted.context else {
            throw Failure.unavailableCandidate
        }
        try verifyComposition(composition, encodedComposition: selection.accepted.encodedComposition)
        let batch = selection.accepted.batch
        let candidate = batch.candidates[selection.index]
        let consumption = selection.accepted.consumption[selection.index]
        let completion = DesktopCandidateCompletion(
            authority: batch.authority, workerGeneration: batch.workerGeneration,
            batchID: batch.batchID, candidateID: candidate.candidateID,
            commitID: UUID().uuidString, settingsRevision: context.settingsRevision,
            privateInput: context.privateInput)
        invalidate()
        return .init(text: candidate.text, remaining: consumption.remaining, completion: completion)
    }

    /// A learning-only setting change keeps the displayed candidate, but retires in-flight work.
    mutating func updateLearningRevision(from previous: Int, to next: Int) throws {
        guard previous >= 0, next > previous,
              available.map({ $0.context.settingsRevision == previous }) ?? true,
              selection.map({ $0.accepted.context.settingsRevision == previous }) ?? true else {
            throw Failure.changedSettings
        }
        pending = nil
        available?.context.settingsRevision = next
        selection?.accepted.context.settingsRevision = next
    }

    /// A stopped candidate process cannot change an already displayed commit target.
    mutating func workerUnavailable() {
        pending = nil
        available = nil
    }

    mutating func clearSelection() {
        selection = nil
    }

    mutating func invalidate() {
        pending = nil
        available = nil
        selection = nil
    }

    private func verifyComposition(_ composition: CompositionState, encodedComposition: Data) throws {
        guard try CompositionSnapshot.capture(composition, registeredCustomTables: customInputTableRevisions).encoded() == encodedComposition else {
            throw Failure.changedComposition
        }
    }
}
