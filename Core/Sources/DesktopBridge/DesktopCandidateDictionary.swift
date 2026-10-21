import Core
import Foundation

enum DesktopDictionarySyncFailure: String, Error {
    case invalidRevision = "invalid_dictionary_revision"
    case revisionRequired = "dictionary_revision_required"
    case notPrepared = "dictionary_not_prepared"
    case sourceChanged = "dictionary_source_changed"
    case prepareCancelled = "dictionary_prepare_cancelled"
    case prepareFailed = "dictionary_prepare_failed"
    case bindingBusy = "dictionary_binding_busy"

    static func validate(_ revision: String?) throws {
        guard let revision else {
            return
        }
        // SHA256 is transported as 64 lowercase hexadecimal bytes, never dictionary text or a path.
        guard revision.utf8.count == 64,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Self.invalidRevision
        }
    }
}

/// Staging never changes the dictionary visible to retained candidates or reverse lookup.
@MainActor
final class DesktopCandidateDictionary {
    private let sourceStore: UserDictionarySourceStore
    private let memoryDirectoryURL: URL
    private var preparation: UUID?
    private var prepared: CompiledUserDictionarySnapshot?
    private(set) var applied: CompiledUserDictionarySnapshot?

    init(memoryDirectoryURL: URL, sourceStore: UserDictionarySourceStore) {
        self.memoryDirectoryURL = memoryDirectoryURL
        self.sourceStore = sourceStore
    }

    func prepare() async throws -> String {
        let preparation = UUID()
        self.preparation = preparation
        defer { if self.preparation == preparation { self.preparation = nil } }
        let source = try await sourceStore.capture(memoryDirectoryURL: memoryDirectoryURL)
        guard self.preparation == preparation else { throw DesktopDictionarySyncFailure.prepareCancelled }
        let snapshot: CompiledUserDictionarySnapshot
        if let existing = [applied, prepared].compactMap({ $0 }).first(where: { $0.source.revision == source.revision }) {
            snapshot = existing
        } else {
            do {
                snapshot = try await CompiledUserDictionarySnapshot.prepare(source)
            } catch {
                // Validation/compilation details can contain dictionary text; only expose the fixed stage.
                throw DesktopDictionarySyncFailure.prepareFailed
            }
        }
        guard self.preparation == preparation else { throw DesktopDictionarySyncFailure.prepareCancelled }
        prepared = snapshot
        return source.revision
    }

    func verify(_ revision: String) async throws -> CompiledUserDictionarySnapshot {
        try DesktopDictionarySyncFailure.validate(revision)
        // Other settings can change while preserving the already acknowledged dictionary.
        if let applied, applied.source.revision == revision {
            return applied
        }
        guard let prepared, prepared.source.revision == revision else { throw DesktopDictionarySyncFailure.notPrepared }
        let source = try await sourceStore.capture(memoryDirectoryURL: memoryDirectoryURL)
        guard self.prepared === prepared else { throw DesktopDictionarySyncFailure.prepareCancelled }
        guard source.revision == revision else { throw DesktopDictionarySyncFailure.sourceChanged }
        return prepared
    }

    func apply(_ snapshot: CompiledUserDictionarySnapshot) {
        applied = snapshot
        if prepared === snapshot { prepared = nil }
    }

    func clear() {
        preparation = nil
        prepared = nil
        applied = nil
    }
}
