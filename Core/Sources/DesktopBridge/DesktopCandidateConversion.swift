import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// A batch owns its original conversion session until completion or explicit release.
@MainActor
final class DesktopCandidateConversion: SegmentManagerDelegate {
    struct StoredItem {
        let candidate: Candidate
        let item: DesktopCandidateItem

        init(presentation: CandidatePresentation, composition: CompositionState) throws {
            let count = try ComposingCountSnapshot(presentation.candidate.composingCount)
            _ = try CandidateConsumption(composition: composition, count: count)
            let candidate = presentation.candidate
            self.candidate = candidate
            item = .init(candidateID: UUID().uuidString, text: candidate.text, composingCount: count,
                         presentation: .init(tokens: candidate.data.map { .init(text: $0.word, reading: $0.ruby) },
                                             annotation: presentation.displayContext.annotationText,
                                             extraValues: presentation.displayContext.extraValues,
                                             score: candidate.value.isFinite ? Double(candidate.value) : nil,
                                             comparisonGroup: presentation.consumedInputCount,
                                             commitScope: presentation.commitScope))
        }
    }

    let request: DesktopCandidateRequest
    let composition: CompositionState
    private let converter: KanaKanjiConverter
    private let segments: SegmentsManager
    private(set) var items: [StoredItem] = []
    private(set) var retained = false

    init(request: DesktopCandidateRequest, composition: CompositionState,
         converter: KanaKanjiConverter, directory: URL, resources: URL?, useZenzai: Bool) {
        self.request = request
        self.composition = composition
        self.converter = converter
        segments = SegmentsManager(kanaKanjiConverter: converter,
                                   applicationDirectoryURL: directory.appendingPathComponent("memory"),
                                   containerURL: directory, context: .init(useZenzai: useZenzai, resourcesDirectoryURL: resources))
        segments.delegate = self
        segments.learningEnabled = !request.privateInput
        segments.activate()
        if let checkpoint = composition.checkpoint() {
            segments.restoreComposition(checkpoint)
            if case .selecting(let candidates, _) = segments.getCurrentCandidateWindow(inputState: .selecting) {
                // The ordinary window supplies real candidates. Entries without a usable
                // nonzero formal consumption cannot be adopted by the reading owner.
                items = segments.makeCandidatePresentations(candidates).compactMap {
                    try? StoredItem(presentation: $0, composition: composition)
                }
            }
        }
    }

    nonisolated func getLeftSideContext(maxCount: Int) -> String? {
        MainActor.assumeIsolated { String(request.leftContext.suffix(maxCount)) }
    }

    nonisolated func getRightSideContext(maxCount: Int) -> String? {
        MainActor.assumeIsolated { String(request.rightContext.prefix(maxCount)) }
    }

    func retain() {
        retained = true
    }

    func item(id: String) throws -> StoredItem {
        guard let item = items.first(where: { $0.item.candidateID == id }) else {
            throw DesktopCandidateFailure.unknownCandidate
        }
        return item
    }

    func complete(_ item: StoredItem, privateInput: Bool) -> Bool {
        segments.learningEnabled = !request.privateInput && !privateInput
        let learningRequested = segments.learningEnabled && Config.Learning().value == .inputAndOutput
        // Preserve the normal adapter's pre-private flush and the existing commit order.
        if !segments.learningEnabled { converter.commitUpdateLearningData() }
        segments.prefixCandidateCommited(item.candidate, leftSideContext: request.leftContext)
        converter.commitUpdateLearningData()
        segments.deactivate(flushLearningData: false)
        return learningRequested
    }

    func release() {
        segments.deactivate(flushLearningData: false)
    }
}
