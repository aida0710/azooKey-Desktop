import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
enum DesktopDictionaryController {
    static func response(
        to request: BridgeRequest, memoryDirectoryURL: URL, converter: KanaKanjiConverter
    ) async throws -> DesktopSnapshot? {
        switch request.operation {
        case "settings":
            var response = DesktopSnapshot()
            response.settings = DesktopSettings()
            return response
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
            guard let items = request.items, let path = request.stagedSettingsPath else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            return await Self.save(items: items, stagedPath: path, memoryDirectoryURL: memoryDirectoryURL, converter: converter)
        default:
            return try await DesktopDictionaryExchangeController.response(to: request)
        }
    }

    private static func save(
        items: [Config.UserDictionaryEntry], stagedPath: String,
        memoryDirectoryURL: URL, converter: KanaKanjiConverter
    ) async -> DesktopSnapshot {
        var response = DesktopSnapshot()
        response.dictionarySaved = false
        var settingsFile: DesktopDictionarySettingsFile?
        do {
            let file = try await UserDictionaryFileWorker.perform {
                try DesktopDictionarySettingsFile(
                    stagedURL: URL(fileURLWithPath: stagedPath),
                    settingsURL: DesktopDictionarySettingsFile.settingsURL(), entries: items
                )
            }
            settingsFile = file
            let directory = CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: memoryDirectoryURL)
            try await UserDictionarySaveTransaction.save(
                items: items, directoryURL: directory,
                persistence: .combining([UserDictionaryConfigPersistence.make(items: items), file.persistence()]),
                activate: { @MainActor in converter.updateUserDictionaryURL(directory, forceReload: true) }
            )
            // Failure to remove a redundant hard link does not undo a completed save.
            try? await UserDictionaryFileWorker.perform { try file.discardBackup() }
            response.dictionarySaved = true
        } catch let error as UserDictionarySaveError {
            response.dictionarySaveError = Self.publicStage(error)
            response.dictionaryIssues = (error.underlying as? UserDictionaryValidation.InvalidEntries)?.issues
        } catch {
            response.dictionarySaveError = "persistence"
        }
        if response.dictionarySaved != true, let settingsFile {
            // Compilation can fail after capture but before persistence is attempted.
            try? await UserDictionaryFileWorker.perform { try settingsFile.discardUnusedBackup() }
        }
        return response
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
        _ items: [Config.UserDictionaryEntry], memoryDirectoryURL: URL, converter: KanaKanjiConverter
    ) async throws {
        if DesktopDictionarySettingsFile.sameEntries(items, Config.UserDictionary().value.items) {
            return
        }
        let sourceCheck = UserDictionaryPersistence {
            try await UserDictionaryFileWorker.perform {
                let content = try Data(contentsOf: DesktopDictionarySettingsFile.settingsURL())
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
