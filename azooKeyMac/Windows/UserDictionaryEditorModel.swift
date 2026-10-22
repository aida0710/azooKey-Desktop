import Combine
import Core
import Foundation

enum UserDictionaryEditorOutcome: Sendable {
    case saved
    case validationFailed([UserDictionaryValidation.Issue])
    case saveFailed(messageKey: String)
}

enum UserDictionaryFileOperation: Equatable, Sendable {
    case importing
    case exporting
}

@MainActor
final class UserDictionaryEditorModel: ObservableObject {
    @Published private(set) var entries: [Config.UserDictionaryEntry]
    @Published private(set) var draft: Config.UserDictionaryEntry?
    @Published private(set) var issues: [UserDictionaryValidation.Issue] = []
    @Published private(set) var failureMessageKey: String?
    @Published private(set) var isSaving = false
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var didSave = false
    @Published private(set) var needsRecovery = false
    @Published private(set) var fileOperation: UserDictionaryFileOperation?
    @Published private(set) var importPreview: UserDictionaryImportPreview.Preview?
    @Published private(set) var didExport = false
    @Published var searchText = ""
    @Published var sortOrder = [KeyPathComparator(\Config.UserDictionaryEntry.reading)]

    private var savedEntries: [Config.UserDictionaryEntry]
    private let saveOperation: @MainActor ([Config.UserDictionaryEntry]) async -> UserDictionaryEditorOutcome

    init(
        entries: [Config.UserDictionaryEntry],
        save: @escaping @MainActor ([Config.UserDictionaryEntry]) async -> UserDictionaryEditorOutcome
    ) {
        self.entries = entries
        self.savedEntries = entries
        self.saveOperation = save
    }

    var isBusy: Bool { isSaving || fileOperation != nil }
    var canClose: Bool { !isBusy && importPreview == nil }
    var canEditEntries: Bool { canClose && !needsRecovery && draft == nil }
    var canAdd: Bool { canEditEntries }
    var canApplyImport: Bool {
        !isBusy && !needsRecovery && (importPreview?.counts.additions ?? 0) > 0
    }

    var visibleEntries: [Config.UserDictionaryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? entries : entries.filter {
            $0.word.localizedStandardContains(query)
                || $0.reading.localizedStandardContains(query)
                || $0.nonNullHint.localizedStandardContains(query)
        }
        return matching.sorted(using: sortOrder)
    }

    var draftWord: String {
        get { draft?.word ?? "" }
        set { updateDraft { $0.word = newValue } }
    }

    var draftReading: String {
        get { draft?.reading ?? "" }
        set { updateDraft { $0.reading = newValue } }
    }

    var draftHint: String {
        get { draft?.nonNullHint ?? "" }
        set { updateDraft { $0.nonNullHint = newValue } }
    }

    func beginAdding() {
        guard canAdd else {
            return
        }
        draft = Config.UserDictionaryEntry(word: "", reading: "")
        clearFeedback()
    }

    func beginEditing(_ id: UUID) {
        guard canEditEntries else {
            return
        }
        draft = entries.first { $0.id == id }
        clearFeedback()
    }

    func cancelEditing() {
        guard !isBusy else {
            return
        }
        draft = nil
        clearFeedback()
    }

    func remove(_ id: UUID) {
        guard canEditEntries, entries.contains(where: { $0.id == id }) else {
            return
        }
        entries.removeAll { $0.id == id }
        hasUnsavedChanges = true
        clearFeedback()
    }

    func cancelChanges() {
        guard !isBusy else {
            return
        }
        entries = savedEntries
        draft = nil
        importPreview = nil
        hasUnsavedChanges = false
        clearFeedback()
    }

    func refreshIfUnchanged(_ current: [Config.UserDictionaryEntry]) {
        guard canEditEntries, !hasUnsavedChanges else {
            return
        }
        entries = current
        savedEntries = current
    }

    func save() async {
        guard !isBusy, !needsRecovery, importPreview == nil else {
            return
        }
        let proposedEntries = entriesIncludingDraft()
        isSaving = true
        clearFeedback()
        let outcome = await saveOperation(proposedEntries)
        isSaving = false
        switch outcome {
        case .saved:
            entries = proposedEntries
            savedEntries = proposedEntries
            draft = nil
            hasUnsavedChanges = false
            didSave = true
        case .validationFailed(let issues):
            self.issues = issues
        case .saveFailed(let messageKey):
            needsRecovery = messageKey == "rollbackFailed"
            failureMessageKey = messageKey
        }
    }

    func prepareImport(
        using operation: @MainActor ([Config.UserDictionaryEntry]) async throws -> UserDictionaryImportPreview.Preview?
    ) async {
        guard canEditEntries else {
            return
        }
        fileOperation = .importing
        clearFeedback()
        defer { fileOperation = nil }
        do {
            importPreview = try await operation(entries)
        } catch is CancellationError {
            // A canceled file chooser leaves both the saved entries and draft unchanged.
        } catch {
            failureMessageKey = UserDictionaryExchangeFeedback.failureKey(error, operation: .importing)
        }
    }

    func cancelImport() {
        guard !isBusy, importPreview != nil else {
            return
        }
        importPreview = nil
        clearFeedback()
    }

    func applyImport() {
        guard canApplyImport, let preview = importPreview else {
            return
        }
        do {
            entries = try UserDictionaryImportPreview.applying(preview, to: entries)
            importPreview = nil
            hasUnsavedChanges = true
            clearFeedback()
        } catch {
            importPreview = nil
            failureMessageKey = UserDictionaryExchangeFeedback.failureKey(error, operation: .importing)
        }
    }

    func export(
        using operation: @MainActor ([Config.UserDictionaryEntry]) async throws -> Bool
    ) async {
        guard canEditEntries else {
            return
        }
        fileOperation = .exporting
        clearFeedback()
        defer { fileOperation = nil }
        do {
            didExport = try await operation(entries)
        } catch is CancellationError {
            // Canceling export does not mark the draft as saved.
        } catch {
            failureMessageKey = UserDictionaryExchangeFeedback.failureKey(error, operation: .exporting)
        }
    }

    private func updateDraft(_ change: (inout Config.UserDictionaryEntry) -> Void) {
        guard !isBusy, !needsRecovery, var entry = draft else {
            return
        }
        change(&entry)
        draft = entry
        clearFeedback()
    }

    private func entriesIncludingDraft() -> [Config.UserDictionaryEntry] {
        guard let draft else {
            return entries
        }
        var proposedEntries = entries
        if let index = proposedEntries.firstIndex(where: { $0.id == draft.id }) {
            proposedEntries[index] = draft
        } else {
            proposedEntries.append(draft)
        }
        return proposedEntries
    }

    private func clearFeedback() {
        issues = []
        failureMessageKey = needsRecovery ? "rollbackFailed" : nil
        didSave = false
        didExport = false
    }
}
