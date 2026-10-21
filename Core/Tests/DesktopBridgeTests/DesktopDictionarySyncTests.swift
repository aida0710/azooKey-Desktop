import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopDictionarySyncTests {
    private typealias Fixture = DesktopDictionarySyncFixture

    @Test func preparingASavedDictionaryLeavesActiveInputAndTheAppliedCandidateDictionaryUnchanged() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var item = Config.UserDictionaryEntry(word: "専用候補甲", reading: "あいだ", hint: "元のヒント")
        try await fixture.save([item])
        let original = try await fixture.prepare()
        try await fixture.configure(original)
        let batch = try fixture.batch("aida")
        #expect(batch.candidates.contains { $0.text == item.word })
        try DesktopCandidateTestSupport.retain(fixture.worker, batch)

        var reader = DesktopReadingWorker()
        _ = try reader.process(.init(operation: "configure-settings", readingProcessGeneration: reader.readingProcessGeneration,
                                    settingsRevision: 1, settings: DesktopWorkerSettingsFixture.settings(), dictionaryRevision: original))
        let focus = try DesktopWorkerSettingsFixture.focus(&reader)
        _ = try DesktopWorkerSettingsFixture.key(&reader, reference: focus, text: "nihongo")
        let before = try DesktopReadingTestSupport.encodedJSON(#require(reader.process(.init(operation: "snapshot", reference: focus)).snapshot))
        item.reading = "あいう"
        item.nonNullHint = "新しいヒント"
        try await fixture.save([item])
        let preferences = fixture.defaults.dictionaryRepresentation() as NSDictionary
        let memory = try DesktopCandidateTestSupport.memory(in: fixture.directory)
        let pending = try await fixture.prepare()
        #expect(pending != original)
        let readerAfter = try reader.process(.init(operation: "snapshot", reference: focus))
        #expect(try DesktopReadingTestSupport.encodedJSON(#require(readerAfter.snapshot)) == before)
        #expect(readerAfter.snapshot?.commits.isEmpty == true)
        #expect((readerAfter.snapshot?.candidateCompletions ?? []).isEmpty)
        #expect(try fixture.reading(of: item.word) == "あいだ")
        #expect(try fixture.batch("aida", revision: 2).candidates.contains { $0.text == item.word })
        #expect(fixture.defaults.dictionaryRepresentation() as NSDictionary == preferences)
        #expect(try DesktopCandidateTestSupport.memory(in: fixture.directory) == memory)
        await #expect(throws: DesktopWorkerSettingsFailure.settingsBusy) { try await fixture.configure(pending, revision: 2) }
        #expect(throws: DesktopWorkerSettingsFailure.settingsBusy) {
            try reader.process(.init(operation: "configure-settings", readingProcessGeneration: reader.readingProcessGeneration,
                                     settingsRevision: 2, settings: DesktopWorkerSettingsFixture.settings(), dictionaryRevision: pending))
        }
    }

    @Test func applyingTheSameRevisionToBothRolesRetiresOldCandidatesAndChangesConversionAndReverseLookupTogether() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var item = Config.UserDictionaryEntry(word: "専用候補甲", reading: "あいだ")
        try await fixture.save([item])
        let original = try await fixture.prepare()
        try await fixture.configure(original)
        let batch = try fixture.batch("aida")
        try DesktopCandidateTestSupport.retain(fixture.worker, batch)
        let completion = try DesktopCandidateTestSupport.completion(batch, text: item.word, settings: 1)
        item.reading = "あいう"
        try await fixture.save([item])
        let pending = try await fixture.prepare()
        try fixture.closeContext()
        let candidate = try await fixture.configure(pending, revision: 2)
        var reader = DesktopReadingWorker()
        let reading = try reader.process(.init(operation: "configure-settings", readingProcessGeneration: reader.readingProcessGeneration,
                                               settingsRevision: 2, settings: DesktopWorkerSettingsFixture.settings(), dictionaryRevision: pending))
        #expect(candidate.settingsRevision == reading.settingsRevision)
        #expect(candidate.dictionaryRevision == reading.dictionaryRevision)
        #expect(candidate.settings == reading.settings)
        #expect(throws: DesktopCandidateFailure.unknownBatch) { try DesktopCandidateTestSupport.complete(fixture.worker, completion) }
        #expect(throws: DesktopCandidateFailure.staleAuthority) {
            try DesktopCandidateTestSupport.batch(fixture.worker, request: DesktopCandidateTestSupport.request("aida", settings: 1))
        }
        #expect(try fixture.reading(of: item.word) == "あいう")
        #expect(try fixture.batch("aiu").candidates.contains { $0.text == item.word })
        #expect(try fixture.batch("aida", revision: 2).candidates.allSatisfy { $0.text != item.word })
    }

    @Test func anUnknownAcknowledgementCanBeRetriedWithoutDroppingTheDictionaryDuringOtherSettingsChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = Config.UserDictionaryEntry(word: "専用候補甲", reading: "あいだ")
        try await fixture.save([item])
        let revision = try await fixture.prepare()
        try await fixture.configure(revision)
        let active = try fixture.batch("aida")
        let repeated = try await fixture.configure(revision)
        #expect(repeated.dictionaryRevision == revision && repeated.settingsRevision == 1)
        #expect(repeated.batch == nil && repeated.completion == nil)
        #expect(throws: DesktopDictionarySyncFailure.revisionRequired) {
            try DesktopWorkerSettingsFixture.configure(fixture.worker, settings: DesktopWorkerSettingsFixture.settings(), revision: 2)
        }
        try fixture.closeContext()
        // A later external save is pending, not an instruction to silently replace this acknowledged version.
        try await fixture.save([.init(word: "専用候補乙", reading: "あいだ")])
        var settings = DesktopWorkerSettingsFixture.settings()
        settings.halfSpace = true
        let changed = try await fixture.configure(revision, revision: 2, settings: settings)
        #expect(changed.dictionaryRevision == revision)
        #expect(try fixture.reading(of: item.word) == "あいだ")
        #expect(try fixture.batch("aida").candidates.contains { $0.text == item.word })
        #expect(throws: DesktopCandidateFailure.unknownBatch) { try DesktopCandidateTestSupport.retain(fixture.worker, active) }
        await #expect(throws: DesktopWorkerSettingsFailure.staleSettings) { try await fixture.configure(revision, revision: 1) }
    }

    @Test func aSaveAfterPreparationAndAFailedSaveCannotPartiallyReplaceTheAppliedDictionary() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let original = Config.UserDictionaryEntry(word: "専用候補甲", reading: "あいだ")
        try await fixture.save([original])
        let revision = try await fixture.prepare()
        try await fixture.configure(revision)
        try await fixture.save([.init(word: "専用候補乙", reading: "あいだ")])
        let pending = try await fixture.prepare()
        try await fixture.save([.init(word: "専用候補丙", reading: "あいだ")])
        await #expect(throws: DesktopDictionarySyncFailure.sourceChanged) { try await fixture.configure(pending, revision: 2) }
        #expect(try fixture.worker.process(.init(operation: "settings")).dictionaryRevision == revision)
        #expect(try fixture.reading(of: original.word) == "あいだ")
        let saved = try await fixture.prepare()
        await #expect(throws: UserDictionarySaveError.self) {
            try await fixture.save([.init(word: "保存失敗候補", reading: "あいだ")], failActivation: true)
        }
        #expect(try await fixture.prepare() == saved)
        try await fixture.configure(saved, revision: 2)
        #expect(try fixture.reading(of: "専用候補丙") == "あいだ")
        #expect(try fixture.reading(of: "保存失敗候補") == nil)
    }

    @Test func restartingTheWorkerRequiresNewPreparationAndCannotAdoptOldLearningReceipts() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = Config.UserDictionaryEntry(word: "専用候補甲", reading: "あいだ")
        try await fixture.save([item])
        let revision = try await fixture.prepare()
        try await fixture.configure(revision)
        let batch = try fixture.batch("aida")
        try DesktopCandidateTestSupport.retain(fixture.worker, batch)
        let completion = try DesktopCandidateTestSupport.completion(batch, text: item.word, settings: 1)
        let restarted = try DesktopCandidateWorker(directory: fixture.directory, dictionarySourceStore: fixture.sourceStore)
        defer { restarted.shutdown() }
        await #expect(throws: DesktopCandidateFailure.wrongWorkerGeneration) {
            try await restarted.processAsync(.init(operation: "prepare-dictionary", workerGeneration: fixture.worker.workerGeneration))
        }
        let configure = DesktopCandidateWorkerRequest(operation: "configure-settings", workerGeneration: restarted.workerGeneration,
                                                       settingsRevision: 1, settings: DesktopWorkerSettingsFixture.settings(), dictionaryRevision: revision)
        await #expect(throws: DesktopDictionarySyncFailure.notPrepared) { try await restarted.processAsync(configure) }
        let prepared = try await restarted.processAsync(.init(operation: "prepare-dictionary", workerGeneration: restarted.workerGeneration))
        #expect(prepared.preparedDictionaryRevision == revision)
        #expect(try await restarted.processAsync(configure).dictionaryRevision == revision)
        #expect(throws: DesktopCandidateFailure.wrongWorkerGeneration) { try DesktopCandidateTestSupport.complete(restarted, completion) }
        #expect(try DesktopCandidateTestSupport.batch(restarted, request: DesktopCandidateTestSupport.request("aida", settings: 1))
            .candidates.contains { $0.text == item.word })
    }

    @Test func privateConversionUsesTheAcknowledgedDictionaryWithoutLearningOrSendingItsContentsInMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = Config.UserDictionaryEntry(word: "専用候補甲", reading: "あいだ", hint: "秘密のヒント")
        try await fixture.save([item])
        let revision = try await fixture.prepare()
        var settings = DesktopWorkerSettingsFixture.settings()
        settings.learning = .inputAndOutput
        try await fixture.configure(revision, settings: settings)
        let memory = try DesktopCandidateTestSupport.memory(in: fixture.directory)
        let batch = try fixture.batch("aida", privateInput: true)
        try DesktopCandidateTestSupport.retain(fixture.worker, batch)
        let completion = try DesktopCandidateTestSupport.complete(fixture.worker,
            DesktopCandidateTestSupport.completion(batch, text: item.word, settings: 1, privateInput: true))
        #expect(!completion.learningRequested)
        #expect(try DesktopCandidateTestSupport.memory(in: fixture.directory) == memory)
        #expect(throws: ReconversionSession.Failure.privateInput) {
            try fixture.reading(of: item.word, privateInput: true)
        }
        let metadata = try #require(String(data: JSONEncoder().encode(fixture.worker.process(.init(operation: "settings"))), encoding: .utf8))
        #expect(!metadata.contains(item.word) && !metadata.contains(item.reading) && !metadata.contains(item.nonNullHint))
    }

    @Test func invalidSavedEntriesFailPreparationWithoutDiscardingThePreviouslyAppliedDictionary() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = Config.UserDictionaryEntry(word: "専用候補甲", reading: "あいだ")
        try await fixture.save([item])
        let revision = try await fixture.prepare()
        try await fixture.configure(revision, revision: 0)
        let invalid = Config.UserDictionaryEntry(word: "不正な読み", reading: "😀")
        let content = try JSONSerialization.data(withJSONObject: ["items": JSONSerialization.jsonObject(with: JSONEncoder().encode([invalid]))])
        fixture.defaults.set(content, forKey: Config.UserDictionary.key)
        await #expect(throws: DesktopDictionarySyncFailure.prepareFailed) { try await fixture.prepare() }
        #expect(try fixture.worker.process(.init(operation: "settings")).dictionaryRevision == revision)
        #expect(try fixture.reading(of: item.word) == "あいだ")
        #expect(try fixture.batch("aida").candidates.contains { $0.text == item.word })
        #expect(fixture.defaults.data(forKey: Config.UserDictionary.key) == content)
    }
}
