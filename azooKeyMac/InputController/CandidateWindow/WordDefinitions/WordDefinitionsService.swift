import CoreServices
import Foundation

/// Serializes OS dictionary calls, prioritizing the selected word between availability lookups.
final class WordDefinitionsService: @unchecked Sendable {
    typealias Completion = @MainActor @Sendable (String?) -> Void
    typealias AvailabilityCompletion = @MainActor @Sendable ([Bool]) -> Void
    static let maximumAvailabilityWords = 9 // One physical number-key page.
    private let maximumCachedWords = 128 // Bound spelling-only availability; do not retain dictionary bodies.
    private struct Request: Sendable {
        let id: UUID
        let word: String
        let completion: Completion
    }
    private struct AvailabilityRequest: Sendable {
        let id: UUID
        let words: [String]
        let completion: AvailabilityCompletion
        var found: [Bool] = []
    }
    private enum Work {
        case selected(Request)
        case availability(id: UUID, word: String)
    }

    private let queue = DispatchQueue(label: "dev.ensan.inputmethod.azooKeyMac.word-definitions", qos: .utility)
    private let lock = NSLock()
    private let lookup: @Sendable (String) -> String?
    // All mutable state is guarded by lock; the C function is called only on queue.
    private var waiting: Request?
    private var latestID: UUID?
    private var availability: AvailabilityRequest?
    private var cachedAvailability: [Data: Bool] = [:]
    private var cachedWordOrder: [Data] = []
    private var isWorking = false

    init(lookup: @escaping @Sendable (String) -> String?) { self.lookup = lookup }
    convenience init() { self.init(lookup: Self.dictionaryDefinition) }

    func search(word: String, completion: @escaping Completion) {
        let request = Request(id: UUID(), word: word, completion: completion)
        lock.lock()
        waiting = request
        latestID = request.id
        let needsWorker = !isWorking
        isWorking = true
        lock.unlock()
        if needsWorker { queue.async { [self] in drain() } }
    }

    func checkAvailability(words: [String], completion: @escaping AvailabilityCompletion) {
        guard !words.isEmpty else {
            cancelAvailability()
            Task { @MainActor in completion([]) }
            return
        }
        let request = AvailabilityRequest(id: UUID(), words: Array(words.prefix(Self.maximumAvailabilityWords)), completion: completion)
        lock.lock()
        availability = request
        let needsWorker = !isWorking
        isWorking = true
        lock.unlock()
        if needsWorker { queue.async { [self] in drain() } }
    }

    func cancelPending() {
        lock.lock()
        waiting = nil
        latestID = nil
        lock.unlock()
    }

    func cancelAvailability() {
        lock.lock()
        availability = nil
        lock.unlock()
    }

    private func drain() {
        while let work = takeNextWork() {
            switch work {
            case .selected(let request):
                let definition = lookup(request.word)
                lock.lock()
                rememberAvailability(word: request.word, found: Self.hasDefinition(definition))
                let isLatest = latestID == request.id
                lock.unlock()
                if isLatest { Task { @MainActor in request.completion(definition) } }
            case .availability(let id, let word):
                let found = definitionExists(word: word)
                finishAvailability(id: id, found: found)
            }
        }
    }

    private func takeNextWork() -> Work? {
        lock.lock()
        defer { lock.unlock() }
        if let request = waiting {
            waiting = nil
            return .selected(request)
        }
        if let request = availability {
            return .availability(id: request.id, word: request.words[request.found.count])
        }
        isWorking = false
        return nil
    }

    private func definitionExists(word: String) -> Bool {
        guard !word.isEmpty else {
            return false
        }
        let key = Data(word.utf8)
        lock.lock()
        let cached = cachedAvailability[key]
        lock.unlock()
        if let cached {
            return cached
        }
        let found = Self.hasDefinition(lookup(word))
        lock.lock()
        rememberAvailability(word: word, found: found)
        lock.unlock()
        return found
    }

    private func finishAvailability(id: UUID, found: Bool) {
        lock.lock()
        guard var request = availability, request.id == id else {
            lock.unlock()
            return
        }
        request.found.append(found)
        if request.found.count == request.words.count {
            availability = nil
            lock.unlock()
            let completedRequest = request
            Task { @MainActor in completedRequest.completion(completedRequest.found) }
        } else {
            availability = request
            lock.unlock()
        }
    }

    // Called with lock held; UTF-8 keys preserve distinct spellings even under Unicode canonical equivalence.
    private func rememberAvailability(word: String, found: Bool) {
        let key = Data(word.utf8)
        if cachedAvailability[key] == nil {
            cachedWordOrder.append(key)
            if cachedWordOrder.count > maximumCachedWords {
                cachedAvailability.removeValue(forKey: cachedWordOrder.removeFirst())
            }
        }
        cachedAvailability[key] = found
    }

    private static func hasDefinition(_ definition: String?) -> Bool {
        definition?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func queryRange(for word: String) -> CFRange {
        CFRange(location: 0, length: CFStringGetLength(word as CFString))
    }

    private static func dictionaryDefinition(_ word: String) -> String? {
        guard !word.isEmpty, let definition = DCSCopyTextDefinition(nil, word as CFString, queryRange(for: word)) else {
            return nil
        }
        return definition.takeRetainedValue() as String
    }
}
