import Foundation

@MainActor
final class WordDefinitionsModel {
    struct Target: Equatable, Sendable {
        let generation: UInt
        let candidateIndex: Int
        let word: String
        let reading: String

        static func == (left: Self, right: Self) -> Bool {
            left.generation == right.generation && left.candidateIndex == right.candidateIndex &&
            left.word.utf8.elementsEqual(right.word.utf8) && left.reading.utf8.elementsEqual(right.reading.utf8)
        }
    }

    enum Result: Equatable {
        case loading
        case definition(String)
        case notFound
    }

    typealias Search = (String, @escaping WordDefinitionsService.Completion) -> Void
    var onChange: (() -> Void)?
    let availability: WordDefinitionsAvailabilityModel
    private(set) var target: Target?
    private(set) var result: Result?
    private let search: Search
    private let cancelPending: () -> Void
    private var revision: UInt = 0

    init(search: @escaping Search, cancelPending: @escaping () -> Void, availability: WordDefinitionsAvailabilityModel? = nil) {
        self.search = search
        self.cancelPending = cancelPending
        self.availability = availability ?? WordDefinitionsAvailabilityModel(check: { _, completion in completion([]) }, cancel: {})
    }

    convenience init() {
        let service = WordDefinitionsService()
        self.init(search: { service.search(word: $0, completion: $1) }, cancelPending: service.cancelPending,
                  availability: WordDefinitionsAvailabilityModel(check: { service.checkAvailability(words: $0, completion: $1) },
                                                               cancel: service.cancelAvailability))
    }

    func update(target next: Target?) {
        guard let next, !next.word.isEmpty else {
            invalidate()
            return
        }
        guard target != next else {
            return
        }
        revision &+= 1
        let requestedRevision = revision
        target = next
        result = .loading
        search(next.word) { [weak self] definition in
            guard let self, self.revision == requestedRevision, self.target == next else {
                return
            }
            // nil cannot distinguish a missing dictionary from an absent entry.
            if let definition, !definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.result = .definition(definition)
            } else {
                self.result = .notFound
            }
            self.availability.record(target: next, found: self.result != .notFound)
            self.onChange?()
        }
    }

    func invalidate() {
        guard target != nil || result != nil else {
            return
        }
        revision &+= 1
        target = nil
        result = nil
        cancelPending()
    }
}
