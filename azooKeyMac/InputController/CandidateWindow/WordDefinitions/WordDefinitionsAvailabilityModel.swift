import Foundation

/// Matches a bounded background availability result to the exact visible page and candidate spelling.
@MainActor
final class WordDefinitionsAvailabilityModel {
    typealias Check = ([String], @escaping WordDefinitionsService.AvailabilityCompletion) -> Void
    var onChange: (() -> Void)?
    private(set) var availableCandidateIndices: Set<Int> = []
    private var targets: [WordDefinitionsModel.Target] = []
    private var revision: UInt = 0
    private var selectedResults: [Int: Bool] = [:]
    private let check: Check
    private let cancel: () -> Void

    init(check: @escaping Check, cancel: @escaping () -> Void) {
        self.check = check
        self.cancel = cancel
    }

    func update(targets: [WordDefinitionsModel.Target]) {
        let boundedTargets = Array(targets.prefix(WordDefinitionsService.maximumAvailabilityWords))
        guard self.targets != boundedTargets else {
            return
        }
        revision &+= 1
        self.targets = boundedTargets
        availableCandidateIndices = []
        selectedResults = [:]
        guard !boundedTargets.isEmpty else {
            cancel()
            return
        }
        let requestedRevision = revision
        check(boundedTargets.map(\.word)) { [weak self] found in
            guard let self, self.revision == requestedRevision, self.targets == boundedTargets else {
                return
            }
            self.availableCandidateIndices = Set(zip(boundedTargets, found).compactMap { target, exists in
                (self.selectedResults[target.candidateIndex] ?? exists) ? target.candidateIndex : nil
            })
            self.onChange?()
        }
    }

    func record(target: WordDefinitionsModel.Target, found: Bool) {
        guard targets.contains(target) else {
            return
        }
        selectedResults[target.candidateIndex] = found
        if found { availableCandidateIndices.insert(target.candidateIndex) } else { availableCandidateIndices.remove(target.candidateIndex) }
        onChange?()
    }

    func invalidate() { update(targets: []) }
}
