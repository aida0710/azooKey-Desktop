import AppKit
import Core

@MainActor
enum UserDictionarySaveService {
    static func save(_ entries: [Config.UserDictionaryEntry]) async -> UserDictionaryEditorOutcome {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else {
            return .saveFailed(messageKey: "activationFailed")
        }
        let directory = CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: AppGroup.memoryDirectoryURL())
        do {
            try await UserDictionarySaveTransaction.save(
                items: entries, directoryURL: directory,
                persistence: UserDictionaryConfigPersistence.make(items: entries),
                activate: { @MainActor in
                    delegate.kanaKanjiConverter.updateUserDictionaryURL(directory, forceReload: true)
                }
            )
            return .saved
        } catch let error as UserDictionarySaveError {
            if !error.rollbackFailures.isEmpty {
                return .saveFailed(messageKey: "rollbackFailed")
            }
            if let invalid = error.underlying as? UserDictionaryValidation.InvalidEntries {
                return .validationFailed(invalid.issues)
            }
            if error.underlying is UserDictionaryValidation.ResourceError {
                return .saveFailed(messageKey: "missingResources")
            }
            switch error.phase {
            case .snapshot, .persistence:
                return .saveFailed(messageKey: "persistenceFailed")
            case .compilation, .installation:
                return .saveFailed(messageKey: "compileFailed")
            case .activation:
                return .saveFailed(messageKey: "activationFailed")
            case .locking, .validation:
                return .saveFailed(messageKey: "unknownFailure")
            }
        } catch {
            return .saveFailed(messageKey: "unknownFailure")
        }
    }
}
