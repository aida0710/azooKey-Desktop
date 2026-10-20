@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite("ユーザー辞書の保存と復元")
struct UserDictionarySaveTransactionTests {
    @Test("コンパイル・置換・設定保存の失敗で旧辞書と旧設定を保持する",
          arguments: [DictionaryTestFailure.compilation, .installation, .persistence])
    func failedSaveKeepsPreviousFilesAndSettings(failure: DictionaryTestFailure) async throws {
        let fixture = try DictionaryTransactionFixture()
        let previousFiles = try fixture.files()
        let previousSettings = try Data(contentsOf: fixture.settingsURL)
        let compilations = DictionaryCallCounter()
        var operations = UserDictionaryFileOperations()
        let compile = operations.compile
        operations.compile = { entries, directory, characters in
            compilations.increment()
            if failure == .compilation {
                throw DictionaryTestFailure.compilation
            }
            try compile(entries, directory, characters)
        }
        operations.move = { source, destination in
            if failure == .installation, source.lastPathComponent.contains(".building-") {
                throw DictionaryTestFailure.installation
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        do {
            try await fixture.save(
                operations: operations,
                persistence: fixture.persistence(failWrite: failure == .persistence)
            )
            Issue.record("The injected failure was ignored")
        } catch let error as UserDictionarySaveError {
            #expect(error.underlying as? DictionaryTestFailure == failure)
            #expect(error.rollbackFailures.isEmpty)
            #expect(error.recoveryDirectoryURL == nil)
        }
        #expect(compilations.value == 1)
        #expect(try fixture.files() == previousFiles)
        #expect(try Data(contentsOf: fixture.settingsURL) == previousSettings)
    }

    @Test("復元の失敗を原失敗と分けて返し旧コンパイル済み辞書を残す")
    func rollbackFailureReportsBothCausesAndKeepsTheBackup() async throws {
        let fixture = try DictionaryTransactionFixture()
        let previousFiles = try fixture.files()
        var operations = UserDictionaryFileOperations()
        operations.move = { source, destination in
            if source.lastPathComponent.contains(".backup-") {
                throw DictionaryTestFailure.dictionaryRollback
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        do {
            try await fixture.save(
                operations: operations,
                persistence: fixture.persistence(failWrite: true, failRestore: true)
            )
            Issue.record("A persistence failure was reported as success")
        } catch let error as UserDictionarySaveError {
            #expect(error.phase == .persistence)
            #expect(error.underlying as? DictionaryTestFailure == .persistence)
            #expect(error.rollbackFailures.map(\.phase) == [.dictionary, .settings])
            let backup = try #require(error.recoveryDirectoryURL)
            #expect(try fixture.files(at: backup) == previousFiles)
            #expect(CompiledUserDictionaryStore.hasCompiledDictionary(at: fixture.directoryURL))
        }
    }

    @Test("変換エンジンへの反映に失敗しても旧辞書の候補が引き続き出る")
    @MainActor
    func failedActivationRestoresPreviousCandidatesWithoutRecompilation() async throws {
        let fixture = try DictionaryTransactionFixture(useDefaultCharacterTable: true)
        let converter = DictionaryCandidateProbe(memoryURL: fixture.rootURL)
        #expect(converter.candidates().contains(fixture.oldItems[0].word))
        let activations = DictionaryCallCounter()
        let compilations = DictionaryCallCounter()
        var operations = UserDictionaryFileOperations()
        let compile = operations.compile
        operations.compile = { entries, directory, characters in
            compilations.increment()
            try compile(entries, directory, characters)
        }
        do {
            try await fixture.save(operations: operations, activate: {
                await converter.reload()
                if activations.increment() == 1 {
                    throw DictionaryTestFailure.activation
                }
            })
            Issue.record("An activation failure was reported as success")
        } catch let error as UserDictionarySaveError {
            #expect(error.phase == .activation)
            #expect(error.rollbackFailures.isEmpty)
        }
        #expect(compilations.value == 1)
        #expect(activations.value == 2)
        #expect(converter.candidates().contains(fixture.oldItems[0].word))
        #expect(!converter.candidates().contains(fixture.newItems[0].word))
        #expect(try fixture.savedItems().map(\.id) == fixture.oldItems.map(\.id))
    }

    @Test("正常保存後は設定を読み直した新しい変換器にも登録語が現れる")
    @MainActor
    func successfulSaveSurvivesNewSettingsAndConverterInstances() async throws {
        let fixture = try DictionaryTransactionFixture(useDefaultCharacterTable: true)
        let suiteName = "DictionaryPersistenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode(Config.UserDictionary.Value(items: fixture.oldItems)),
            forKey: Config.UserDictionary.key
        )
        #expect(defaults.synchronize())
        let converter = DictionaryCandidateProbe(memoryURL: fixture.rootURL)
        let receipt = try await fixture.save(
            persistence: UserDictionaryConfigPersistence.make(items: fixture.newItems, defaults: defaults),
            activate: { await converter.reload() }
        )
        #expect(receipt.retainedBackupDirectoryURL == nil)
        #expect(converter.candidates().contains(fixture.newItems[0].word))
        let restartedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let encoded = try #require(restartedDefaults.data(forKey: Config.UserDictionary.key))
        let restartedItems = try JSONDecoder().decode(Config.UserDictionary.Value.self, from: encoded).items
        #expect(restartedItems.map(\.id) == fixture.newItems.map(\.id))
        #expect(restartedItems.map(\.word) == fixture.newItems.map(\.word))
        let restartedConverter = DictionaryCandidateProbe(memoryURL: fixture.rootURL)
        #expect(restartedConverter.candidates().contains(fixture.newItems[0].word))
        #expect(!restartedConverter.candidates().contains(fixture.oldItems[0].word))
    }

    @Test("UserDefaultsの同期失敗を成功にせず元の値を復元する")
    func defaultsSynchronizationFailureRestoresTheRawPreviousValue() async throws {
        let fixture = try DictionaryTransactionFixture()
        let suiteName = "DictionarySynchronizationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Preserve a malformed legacy value too; a default decoded value is not a faithful snapshot.
        defaults.set("legacy-value", forKey: Config.UserDictionary.key)
        #expect(defaults.synchronize())
        let synchronization = DictionaryCallCounter()
        let persistence = UserDictionaryConfigPersistence.make(
            items: fixture.newItems, defaults: defaults,
            synchronize: { defaults in
                if synchronization.increment() == 2 {
                    return false
                }
                return defaults.synchronize()
            }
        )
        let previousFiles = try fixture.files()
        do {
            try await fixture.save(persistence: persistence)
            Issue.record("UserDefaults synchronization failure was ignored")
        } catch let error as UserDictionarySaveError {
            #expect(error.phase == .persistence)
            #expect(error.underlying is UserDictionaryConfigPersistence.Failure)
            #expect(error.rollbackFailures.isEmpty)
        }
        #expect(defaults.string(forKey: Config.UserDictionary.key) == "legacy-value")
        #expect(try fixture.files() == previousFiles)
    }
}

final class DictionaryCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        self.lock.withLock {
            self.count += 1
            return self.count
        }
    }

    var value: Int {
        self.lock.withLock { self.count }
    }
}

@MainActor
private final class DictionaryCandidateProbe {
    private let manager: SegmentsManager

    init(memoryURL: URL) {
        self.manager = SegmentsManager(
            kanaKanjiConverter: .withDefaultDictionary(),
            applicationDirectoryURL: memoryURL, containerURL: nil,
            context: .init(useZenzai: false)
        )
    }

    func reload() {
        self.manager.reloadUserDictionary()
    }

    func candidates() -> [String] {
        self.manager.stopComposition()
        self.manager.insertAtCursorPosition("てすと", inputStyle: .direct)
        self.manager.requestSetCandidateWindowState(visible: true)
        switch self.manager.getCurrentCandidateWindow(inputState: .selecting) {
        case .selecting(let candidates, _), .composing(let candidates, _):
            return candidates.map(\.text)
        case .hidden:
            return []
        }
    }
}
