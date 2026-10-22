import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
enum DesktopDictionaryController {
    static func response(
        to request: BridgeRequest, settings: DesktopSettingsController, memoryDirectoryURL: URL, converter: KanaKanjiConverter
    ) async throws -> DesktopSnapshot? {
        switch request.operation {
        case "dictionary-validate":
            guard let items = request.items else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            var response = DesktopSnapshot()
            do {
                response.dictionaryIssues = try await UserDictionaryFileWorker.perform {
                    try UserDictionaryValidation.validate(items: items)
                }
            } catch {
                response.dictionarySaveError = "compile"
            }
            return response
        case "dictionary-save":
            guard let items = request.items else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            return await Self.save(
                items: items, expectedStamp: request.settingsFile?.expectedStamp, settings: settings,
                memoryDirectoryURL: memoryDirectoryURL, converter: converter
            )
        default:
            return try await DesktopDictionaryExchangeController.response(to: request)
        }
    }

    /// Saves the dictionary into the settings file the screen opened, keeping
    /// every other setting the file holds.
    private static func save(
        items: [Config.UserDictionaryEntry], expectedStamp: DesktopSettingsFileStamp?, settings: DesktopSettingsController,
        memoryDirectoryURL: URL, converter: KanaKanjiConverter
    ) async -> DesktopSnapshot {
        var response = DesktopSnapshot()
        response.dictionarySaved = false
        let store = settings.store
        do {
            let saved = try await store.modify(
                knownGood: settings.activation.current, expectedStamp: expectedStamp,
                change: { $0.userDictionary.items = items }
            ) { staged in
                try await publish(items: items, stagedFileURL: staged, settingsFileURL: store.fileURL,
                                  memoryDirectoryURL: memoryDirectoryURL, converter: converter)
            }
            response.dictionarySaved = true
            settings.respond(with: saved, to: &response)
        } catch let error as UserDictionarySaveError {
            response.dictionarySaveError = Self.publicStage(error)
            response.dictionaryIssues = (error.underlying as? UserDictionaryValidation.InvalidEntries)?.issues
        } catch {
            response.dictionarySaveError = "persistence"
            response.settingsResult = .init(error: DesktopSettingsController.problem(for: error))
        }
        return response
    }

    /// Compiles and activates the dictionary while the staged file replaces the
    /// settings file; a failure puts back both the dictionary and the file.
    private static func publish(
        items: [Config.UserDictionaryEntry], stagedFileURL: URL, settingsFileURL: URL,
        memoryDirectoryURL: URL, converter: KanaKanjiConverter
    ) async throws {
        let file = try await UserDictionaryFileWorker.perform {
            try DesktopDictionarySettingsFile(stagedURL: stagedFileURL, settingsURL: settingsFileURL, entries: items)
        }
        let directory = CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: memoryDirectoryURL)
        do {
            try await UserDictionarySaveTransaction.save(
                items: items, directoryURL: directory,
                persistence: .combining([UserDictionaryConfigPersistence.make(items: items), file.persistence()]),
                activate: { @MainActor in converter.updateUserDictionaryURL(directory, forceReload: true) }
            )
        } catch {
            // Compilation can fail after capture but before persistence is attempted.
            try? await UserDictionaryFileWorker.perform { try file.discardUnusedBackup() }
            throw error
        }
        // Failure to remove a redundant hard link does not undo a completed save.
        try? await UserDictionaryFileWorker.perform { try file.discardBackup() }
    }

    private static func publicStage(_ error: UserDictionarySaveError) -> String {
        if !error.rollbackFailures.isEmpty {
            return "rollback"
        }
        switch error.phase {
        case .validation, .compilation, .installation:
            return "compile"
        case .activation:
            return "activation"
        case .locking, .snapshot, .persistence:
            return "persistence"
        }
    }

    /// A stale queued configure cannot revive a dictionary after its failed save was rolled back.
    static func applyDictionary(
        _ items: [Config.UserDictionaryEntry], settingsFileURL: URL, memoryDirectoryURL: URL, converter: KanaKanjiConverter
    ) async throws {
        if DesktopDictionarySettingsFile.sameEntries(items, Config.UserDictionary().value.items) {
            return
        }
        let sourceCheck = UserDictionaryPersistence {
            try await UserDictionaryFileWorker.perform {
                let content = try Data(contentsOf: settingsFileURL)
                guard let current = try DesktopDictionarySettingsFile.dictionary(in: content),
                      DesktopDictionarySettingsFile.sameEntries(current.items, items) else {
                    throw DesktopDictionarySettingsFile.Failure.dictionaryMismatch
                }
            }
            return .init(write: {}, restore: {})
        }
        let directory = CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: memoryDirectoryURL)
        try await UserDictionarySaveTransaction.save(
            items: items, directoryURL: directory,
            persistence: .combining([sourceCheck, UserDictionaryConfigPersistence.make(items: items)]),
            activate: { @MainActor in converter.updateUserDictionaryURL(directory, forceReload: true) }
        )
    }
}
