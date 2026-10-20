import Combine
import Core
import Foundation

enum UserDictionaryEditorOutcome: Sendable {
    case saved
    case validationFailed([UserDictionaryValidation.Issue])
    case saveFailed(messageKey: String)
}

@MainActor
final class UserDictionaryEditorModel: ObservableObject {
    // Preserve the existing limit until the separate dictionary migration work measures larger lists.
    static let entryLimit = 50

    @Published private(set) var entries: [Config.UserDictionaryEntry]
    @Published private(set) var draft: Config.UserDictionaryEntry?
    @Published private(set) var issues: [UserDictionaryValidation.Issue] = []
    @Published private(set) var failureMessageKey: String?
    @Published private(set) var isSaving = false
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var didSave = false
    @Published private(set) var needsRecovery = false

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

    var canAdd: Bool { !isSaving && !needsRecovery && draft == nil && entries.count < Self.entryLimit }

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
        guard !isSaving, !needsRecovery, draft == nil else {
            return
        }
        draft = entries.first { $0.id == id }
        clearFeedback()
    }

    func cancelEditing() {
        guard !isSaving else {
            return
        }
        draft = nil
        clearFeedback()
    }

    func remove(_ id: UUID) {
        guard !isSaving, !needsRecovery, draft == nil else {
            return
        }
        entries.removeAll { $0.id == id }
        hasUnsavedChanges = true
        clearFeedback()
    }

    func cancelChanges() {
        guard !isSaving else {
            return
        }
        entries = savedEntries
        draft = nil
        hasUnsavedChanges = false
        clearFeedback()
    }

    func refreshIfUnchanged(_ current: [Config.UserDictionaryEntry]) {
        guard !isSaving, !hasUnsavedChanges, !needsRecovery, draft == nil else {
            return
        }
        entries = current
        savedEntries = current
    }

    func save() async {
        guard !isSaving, !needsRecovery else {
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

    private func updateDraft(_ change: (inout Config.UserDictionaryEntry) -> Void) {
        guard !isSaving, !needsRecovery, var entry = draft else {
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
    }
}
