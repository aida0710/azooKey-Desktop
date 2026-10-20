import Foundation

public struct UserDictionaryPersistence: Sendable {
    public struct RestorationErrors: Error, Sendable {
        public let errors: [any Error]
    }

    public struct Checkpoint: Sendable {
        let write: @Sendable () async throws -> Void
        let restore: @Sendable () async throws -> Void

        public init(
            write: @escaping @Sendable () async throws -> Void,
            restore: @escaping @Sendable () async throws -> Void
        ) {
            self.write = write
            self.restore = restore
        }
    }

    let capture: @Sendable () async throws -> Checkpoint

    /// Capture runs under the dictionary path lock and must not change the saved settings.
    public init(capture: @escaping @Sendable () async throws -> Checkpoint) {
        self.capture = capture
    }

    public static func combining(_ persistences: [Self]) -> Self {
        Self {
            var checkpoints: [Checkpoint] = []
            for persistence in persistences {
                checkpoints.append(try await persistence.capture())
            }
            let captured = checkpoints
            return Checkpoint(
                write: {
                    for checkpoint in captured {
                        try await checkpoint.write()
                    }
                },
                restore: {
                    var errors: [any Error] = []
                    for checkpoint in captured.reversed() {
                        do {
                            try await checkpoint.restore()
                        } catch {
                            errors.append(error)
                        }
                    }
                    if !errors.isEmpty {
                        throw RestorationErrors(errors: errors)
                    }
                }
            )
        }
    }
}

public struct UserDictionarySaveError: Error, Sendable {
    public enum Phase: String, Sendable {
        case locking
        case validation
        case snapshot
        case compilation
        case installation
        case persistence
        case activation
    }

    public struct RollbackFailure: Sendable {
        public enum Phase: String, Sendable {
            case dictionary
            case settings
            case converter
        }

        public let phase: Phase
        public let underlying: any Error
    }

    public let phase: Phase
    public let underlying: any Error
    public let rollbackFailures: [RollbackFailure]
    public let recoveryDirectoryURL: URL?
}

public enum UserDictionarySaveTransaction {
    public struct Receipt: Sendable {
        /// A redundant backup may remain if cleanup fails after all three save stages succeeded.
        public let retainedBackupDirectoryURL: URL?
    }

    struct Request: Sendable {
        let items: [Config.UserDictionaryEntry]
        let systemItems: [Config.UserDictionaryEntry]?
        let directoryURL: URL
        let charIDFileURL: URL?
    }

    @discardableResult
    public static func save(
        items: [Config.UserDictionaryEntry],
        systemItems: [Config.UserDictionaryEntry]? = nil,
        directoryURL: URL,
        persistence: UserDictionaryPersistence,
        activate: @escaping @Sendable () async throws -> Void
    ) async throws -> Receipt {
        try await Self.save(
            request: Request(
                items: items, systemItems: systemItems, directoryURL: directoryURL, charIDFileURL: nil
            ),
            persistence: persistence, activate: activate,
            operations: UserDictionaryFileOperations()
        )
    }

    @discardableResult
    static func save(
        request: Request,
        persistence: UserDictionaryPersistence,
        activate: @escaping @Sendable () async throws -> Void,
        operations: UserDictionaryFileOperations
    ) async throws -> Receipt {
        let directoryURL = UserDictionaryFileLock.canonicalDirectoryURL(request.directoryURL)
        let lock: UserDictionaryFileLock
        do {
            lock = try await UserDictionaryFileWorker.perform {
                try UserDictionaryFileLock(directoryURL: directoryURL)
            }
        } catch {
            throw UserDictionarySaveError(
                phase: .locking, underlying: error, rollbackFailures: [], recoveryDirectoryURL: nil
            )
        }
        defer { withExtendedLifetime(lock) {} }
        let combinedItems = request.items + (request.systemItems ?? Config.SystemUserDictionary().value.items)
        var phase = UserDictionarySaveError.Phase.validation
        var checkpoint: UserDictionaryPersistence.Checkpoint?
        var update: CompiledUserDictionaryUpdate?
        var didAttemptPersistence = false
        var didInstallDictionary = false
        do {
            try Task.checkCancellation()
            phase = .snapshot
            let captured = try await persistence.capture()
            checkpoint = captured
            phase = .compilation
            let prepared = try await UserDictionaryFileWorker.perform {
                try CompiledUserDictionaryStore.prepare(
                    items: combinedItems, directoryURL: directoryURL,
                    charIDFileURL: request.charIDFileURL, operations: operations
                )
            }
            update = prepared
            try Task.checkCancellation()
            phase = .installation
            try await UserDictionaryFileWorker.perform { try prepared.install() }
            didInstallDictionary = true
            phase = .persistence
            didAttemptPersistence = true
            try await captured.write()
            phase = .activation
            try await activate()
            let retainedBackup = try await UserDictionaryFileWorker.perform { prepared.finish() }
            return Receipt(retainedBackupDirectoryURL: retainedBackup)
        } catch {
            let originalError = error
            let rollbackFailures = await Self.rollback(
                update: update, checkpoint: didAttemptPersistence ? checkpoint : nil,
                activate: didInstallDictionary ? activate : nil
            )
            throw UserDictionarySaveError(
                phase: originalError is UserDictionaryValidation.InvalidEntries ? .validation : phase,
                underlying: originalError, rollbackFailures: rollbackFailures,
                recoveryDirectoryURL: update?.recoveryDirectoryURL
            )
        }
    }

    private static func rollback(
        update: CompiledUserDictionaryUpdate?,
        checkpoint: UserDictionaryPersistence.Checkpoint?,
        activate: (@Sendable () async throws -> Void)?
    ) async -> [UserDictionarySaveError.RollbackFailure] {
        var failures: [UserDictionarySaveError.RollbackFailure] = []
        var dictionaryRestored = true
        if let update {
            do {
                try await UserDictionaryFileWorker.perform { try update.rollback() }
            } catch {
                dictionaryRestored = false
                failures.append(.init(phase: .dictionary, underlying: error))
            }
        }
        if let checkpoint {
            do {
                try await checkpoint.restore()
            } catch {
                failures.append(.init(phase: .settings, underlying: error))
            }
        }
        if dictionaryRestored, let activate {
            do {
                try await activate()
            } catch {
                failures.append(.init(phase: .converter, underlying: error))
            }
        }
        return failures
    }
}
