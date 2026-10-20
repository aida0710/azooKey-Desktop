import CoreServices
import Foundation

/// Serializes the synchronous OS lookup and keeps only the newest waiting word.
final class WordDefinitionsService: @unchecked Sendable {
    typealias Completion = @MainActor @Sendable (String?) -> Void
    private struct Request: Sendable {
        let id: UUID
        let word: String
        let completion: Completion
    }

    private let queue = DispatchQueue(label: "dev.ensan.inputmethod.azooKeyMac.word-definitions", qos: .utility)
    private let lock = NSLock()
    private let lookup: @Sendable (String) -> String?
    // All mutable state is guarded by lock; the C function is called only on queue.
    private var waiting: Request?
    private var latestID: UUID?
    private var isWorking = false

    init(lookup: @escaping @Sendable (String) -> String?) {
        self.lookup = lookup
    }

    convenience init() {
        self.init(lookup: Self.dictionaryDefinition)
    }

    func search(word: String, completion: @escaping Completion) {
        let request = Request(id: UUID(), word: word, completion: completion)
        lock.lock()
        waiting = request
        latestID = request.id
        let needsWorker = !isWorking
        isWorking = true
        lock.unlock()
        if needsWorker {
            queue.async { [self] in drain() }
        }
    }

    func cancelPending() {
        lock.lock()
        waiting = nil
        latestID = nil
        lock.unlock()
    }

    private func drain() {
        while let request = takeNextRequest() {
            let definition = lookup(request.word)
            lock.lock()
            let isLatest = latestID == request.id
            lock.unlock()
            if isLatest {
                Task { @MainActor in request.completion(definition) }
            }
        }
    }

    private func takeNextRequest() -> Request? {
        lock.lock()
        defer { lock.unlock() }
        guard let request = waiting else {
            isWorking = false
            return nil
        }
        waiting = nil
        return request
    }

    static func queryRange(for word: String) -> CFRange {
        CFRange(location: 0, length: CFStringGetLength(word as CFString))
    }

    private static func dictionaryDefinition(_ word: String) -> String? {
        guard !word.isEmpty else {
            return nil
        }
        guard let definition = DCSCopyTextDefinition(nil, word as CFString, queryRange(for: word)) else {
            return nil
        }
        return definition.takeRetainedValue() as String
    }
}
