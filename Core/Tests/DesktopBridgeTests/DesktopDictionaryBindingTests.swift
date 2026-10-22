import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopDictionaryBindingTests {
    private static let digest = String(repeating: "a", count: 64)

    @Test func initialBindingPreservesActiveInputReferencesAndAppliedCustomSettings() throws {
        var reader = DesktopReadingWorker()
        var settings = DesktopWorkerSettingsFixture.settings()
        settings.inputStyle = .custom
        settings.customTable = "q\tにほんご\n"
        settings.halfSpace = true
        let configured = try DesktopWorkerSettingsFixture.configure(&reader, settings: settings)
        let reference = try DesktopWorkerSettingsFixture.focus(&reader)
        _ = try DesktopWorkerSettingsFixture.key(&reader, reference: reference, text: "q")
        _ = try DesktopWorkerSettingsFixture.key(&reader, reference: reference, code: 123)
        let before = try snapshot(reader: &reader, reference: reference)
        let bound = try bind(&reader, dictionary: Self.digest, settings: settings)
        #expect(bound.settingsRevision == configured.settingsRevision)
        #expect(bound.settings == configured.settings)
        #expect(bound.customInputTableRevisions == configured.customInputTableRevisions)
        #expect(bound.dictionaryRevision == Self.digest)
        #expect(bound.snapshot == nil && bound.candidateView == nil && bound.reference == nil)
        #expect(try snapshot(reader: &reader, reference: reference) == before)
        #expect(try DesktopWorkerSettingsFixture.key(&reader, reference: reference, code: 36).commits == ["にほんご"])
        #expect(try DesktopWorkerSettingsFixture.key(&reader, reference: reference, text: "q").preedit == "にほんご")
    }

    @Test func anInitialCandidateBindingUsesThePreparedDictionaryWithoutLearningAndCanBeReacknowledged() async throws {
        let fixture = try DesktopDictionarySyncFixture()
        defer { fixture.close() }
        let item = Config.UserDictionaryEntry(word: "専用候補甲", reading: "あいだ")
        try await fixture.save([item])
        var settings = DesktopWorkerSettingsFixture.settings()
        settings.learning = .inputAndOutput
        try DesktopWorkerSettingsFixture.configure(fixture.worker, settings: settings)
        let dictionary = try await fixture.prepare()
        let preferences = fixture.defaults.dictionaryRepresentation() as NSDictionary
        let memory = try DesktopCandidateTestSupport.memory(in: fixture.directory)
        let bound = try await bind(fixture.worker, dictionary: dictionary, settings: settings)
        #expect(bound.settingsRevision == 0 && bound.dictionaryRevision == dictionary)
        #expect(bound.batch == nil && bound.completion == nil && bound.reconversionReadingResult == nil)
        #expect(fixture.defaults.dictionaryRepresentation() as NSDictionary == preferences)
        #expect(try DesktopCandidateTestSupport.memory(in: fixture.directory) == memory)
        #expect(try fixture.reading(of: item.word) == item.reading)
        let batch = try fixture.batch("aida")
        try DesktopCandidateTestSupport.retain(fixture.worker, batch)
        try await fixture.save([.init(word: "専用候補乙", reading: "あいだ")])
        let repeated = try await bind(fixture.worker, dictionary: dictionary, settings: settings)
        #expect(try DesktopReadingTestSupport.encodedJSON(repeated) == DesktopReadingTestSupport.encodedJSON(bound))
        let completion = try DesktopCandidateTestSupport.completion(batch, text: item.word)
        #expect(try DesktopCandidateTestSupport.complete(fixture.worker, completion).learningRequested)
        #expect(try DesktopCandidateTestSupport.complete(fixture.worker, completion).status == .alreadyCompleted)
    }

    @Test(arguments: ["pending", "adopted", "selected", "committed", "stopped", "reset"])
    func initialBindingCannotReauthorizeAnUnversionedCandidate(_ phase: String) throws {
        var reader = DesktopReadingWorker()
        let settings = DesktopWorkerSettingsFixture.settings()
        try DesktopWorkerSettingsFixture.configure(&reader, settings: settings)
        let reference = try DesktopWorkerSettingsFixture.focus(&reader)
        _ = try DesktopWorkerSettingsFixture.key(&reader, reference: reference, text: "a")
        let request = try #require(reader.process(.init(operation: "prepare-candidates", reference: reference,
                                                       candidateWorkerGeneration: "converter")).candidateRequest)
        let batch = try DesktopReadingTestSupport().batch(request, words: ["候補"])
        if ["adopted", "selected", "committed"].contains(phase) {
            _ = try reader.process(.init(operation: "adopt-candidates", reference: reference, batch: batch,
                                         retainedReference: DesktopCandidateTestSupport.reference(batch)))
        }
        if ["selected", "committed"].contains(phase) {
            _ = try reader.process(.init(operation: phase == "committed" ? "commit-candidate" : "select", reference: reference,
                selection: .init(batch: DesktopCandidateTestSupport.reference(batch), candidateID: batch.candidates[0].candidateID)))
        }
        if phase == "stopped" {
            _ = try reader.process(.init(operation: "candidate-worker-stopped", reference: reference, candidateWorkerGeneration: "converter"))
        } else if phase == "reset" {
            _ = try reader.process(.init(operation: "reset", reference: reference, submit: false))
        }
        let before = try snapshot(reader: &reader, reference: reference)
        #expect(throws: DesktopDictionarySyncFailure.bindingBusy) { try bind(&reader, dictionary: Self.digest, settings: settings) }
        #expect(try snapshot(reader: &reader, reference: reference) == before)
        #expect(try reader.process(.init(operation: "settings")).dictionaryRevision == nil)
    }

    @Test func aPendingReverseLookupCannotCrossTheInitialDictionaryBinding() throws {
        var reader = DesktopReadingWorker()
        let settings = DesktopWorkerSettingsFixture.settings()
        try DesktopWorkerSettingsFixture.configure(&reader, settings: settings)
        let reference = try DesktopWorkerSettingsFixture.focus(&reader)
        let context = ReconversionContext(before: "", selected: "専用候補", after: "", cursorUTF16: 4, anchorUTF16: 0,
                                          canReplace: true, isSensitive: false)
        let pending = try reader.process(.init(operation: "reconvert", reference: reference, candidateWorkerGeneration: "converter",
                                               reconversionContext: context))
        #expect(pending.reconversionReadingRequest != nil)
        let before = try snapshot(reader: &reader, reference: reference)
        #expect(throws: DesktopDictionarySyncFailure.bindingBusy) { try bind(&reader, dictionary: Self.digest, settings: settings) }
        #expect(try snapshot(reader: &reader, reference: reference) == before)
    }

    @Test func bindingRequiresTheExactAppliedSettingsAndKeepsNormalUpdatesInactive() throws {
        var reader = DesktopReadingWorker()
        var settings = DesktopWorkerSettingsFixture.settings()
        settings.profile = "e\u{301}"
        #expect(throws: DesktopWorkerSettingsFailure.fullSettingsRequired) { try bind(&reader, dictionary: Self.digest, settings: settings) }
        try DesktopWorkerSettingsFixture.configure(&reader, settings: settings)
        let reference = try DesktopWorkerSettingsFixture.focus(&reader)
        _ = try DesktopWorkerSettingsFixture.key(&reader, reference: reference, text: "a")
        let before = try snapshot(reader: &reader, reference: reference)
        var different = settings
        different.profile = "é"
        #expect(throws: DesktopWorkerSettingsFailure.staleSettings) { try bind(&reader, dictionary: Self.digest, settings: different) }
        #expect(throws: DesktopWorkerSettingsFailure.staleSettings) { try bind(&reader, dictionary: Self.digest, settings: settings, revision: 1) }
        _ = try bind(&reader, dictionary: Self.digest, settings: settings)
        _ = try bind(&reader, dictionary: Self.digest, settings: settings)
        let nextDictionary = String(repeating: "b", count: 64)
        #expect(throws: DesktopWorkerSettingsFailure.staleSettings) { try bind(&reader, dictionary: nextDictionary, settings: settings) }
        #expect(throws: DesktopWorkerSettingsFailure.settingsBusy) {
            try reader.process(.init(operation: "configure-settings", readingProcessGeneration: reader.readingProcessGeneration,
                                     settingsRevision: 1, settings: settings, dictionaryRevision: nextDictionary))
        }
        #expect(try snapshot(reader: &reader, reference: reference) == before)
        _ = try reader.process(.init(operation: "focus-out", reference: reference, submit: false))
        let updated = try reader.process(.init(operation: "configure-settings", readingProcessGeneration: reader.readingProcessGeneration,
                                               settingsRevision: 1, settings: settings, dictionaryRevision: nextDictionary))
        #expect(updated.dictionaryRevision == nextDictionary && updated.settingsRevision == 1)
    }

    @Test func aCandidateBindFailureDoesNotLoseTheReadersInputOrRebindItsDictionary() async throws {
        let fixture = try DesktopDictionarySyncFixture()
        defer { fixture.close() }
        let settings = DesktopWorkerSettingsFixture.settings()
        try DesktopWorkerSettingsFixture.configure(fixture.worker, settings: settings)
        var reader = DesktopReadingWorker()
        try DesktopWorkerSettingsFixture.configure(&reader, settings: settings)
        let reference = try DesktopWorkerSettingsFixture.focus(&reader)
        _ = try DesktopWorkerSettingsFixture.key(&reader, reference: reference, text: "a")
        let dictionary = try await fixture.prepare()
        _ = try bind(&reader, dictionary: dictionary, settings: settings)
        try await fixture.save([.init(word: "専用候補乙", reading: "あいだ")])
        await #expect(throws: DesktopDictionarySyncFailure.sourceChanged) { try await bind(fixture.worker, dictionary: dictionary, settings: settings) }
        #expect(try fixture.worker.process(.init(operation: "settings")).dictionaryRevision == nil)
        _ = try bind(&reader, dictionary: dictionary, settings: settings)
        #expect(try DesktopWorkerSettingsFixture.key(&reader, reference: reference, code: 36).commits == ["あ"])
        let changed = try await fixture.prepare()
        #expect(throws: DesktopWorkerSettingsFailure.staleSettings) { try bind(&reader, dictionary: changed, settings: settings) }
        _ = try reader.process(.init(operation: "focus-out", reference: reference, submit: false))
        _ = try reader.process(.init(operation: "configure-settings", readingProcessGeneration: reader.readingProcessGeneration,
                                     settingsRevision: 1, settings: settings, dictionaryRevision: changed))
        #expect(try await fixture.configure(changed).dictionaryRevision == changed)
    }

    private func bind(_ reader: inout DesktopReadingWorker, dictionary: String, settings: DesktopWorkerSettings,
                      revision: Int = 0) throws -> DesktopReadingWorkerResponse {
        try reader.process(.init(operation: "bind-initial-dictionary", readingProcessGeneration: reader.readingProcessGeneration,
                                 settingsRevision: revision, settings: settings, dictionaryRevision: dictionary))
    }

    private func bind(_ worker: DesktopCandidateWorker, dictionary: String,
                      settings: DesktopWorkerSettings, revision: Int = 0) async throws -> DesktopCandidateWorkerResponse {
        try await worker.processAsync(.init(operation: "bind-initial-dictionary", workerGeneration: worker.workerGeneration,
                                            settingsRevision: revision, settings: settings, dictionaryRevision: dictionary))
    }

    private func snapshot(reader: inout DesktopReadingWorker, reference: DesktopReadingContextReference) throws -> Data {
        try DesktopReadingTestSupport.encodedJSON(reader.process(.init(operation: "snapshot", reference: reference)))
    }
}
