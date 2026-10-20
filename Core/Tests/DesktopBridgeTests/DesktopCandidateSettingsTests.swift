import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopCandidateSettingsTests {
    typealias Fixture = DesktopWorkerSettingsFixture
    typealias Candidates = DesktopCandidateTestSupport

    @Test func bothRolesUseTheSameCustomTableForRealCandidateSelectionAndPrivateCompletion() throws {
        try Candidates.withWorker { candidate, _ in
            let preferences = Config.userDefaults.dictionaryRepresentation() as NSDictionary
            let customTable = CustomInputTableStore.load()
            var settings = Fixture.settings()
            settings.inputStyle = .custom
            settings.customTable = "q\tにほんご\n"
            settings.learning = .inputAndOutput
            var reader = DesktopReadingWorker()
            let readerACK = try Fixture.configure(&reader, settings: settings, revision: 8)
            let candidateACK = try Fixture.configure(candidate, settings: settings, revision: 8)
            #expect(readerACK.settings == candidateACK.settings)
            #expect(readerACK.customInputTableRevisions == candidateACK.customInputTableRevisions)
            #expect(candidateACK.settingsRevision == 8)
            #expect(candidateACK.workerGeneration == candidate.workerGeneration)
            let reference = try Fixture.focus(&reader)
            _ = try Fixture.key(&reader, reference: reference, text: "q")
            let prepared = try reader.process(.init(operation: "prepare-candidates", reference: reference,
                                                     candidateWorkerGeneration: candidate.workerGeneration))
            let request = try #require(prepared.candidateRequest)
            let batch = try Candidates.batch(candidate, request: request)
            let selected = try #require(batch.candidates.first { $0.text == "日本語" })
            try Candidates.retain(candidate, batch)
            _ = try reader.process(.init(operation: "adopt-candidates", reference: reference, batch: batch,
                                          retainedReference: Candidates.reference(batch)))
            _ = try reader.process(.init(operation: "select", reference: reference,
                                          selection: .init(batch: Candidates.reference(batch), candidateID: selected.candidateID)))
            let committed = try Fixture.key(&reader, reference: reference, code: 36)
            #expect(committed.commits == ["日本語"])
            let completion = try #require(committed.candidateCompletions?.first)
            #expect(completion.settingsRevision == 8)
            // Privacy can become stricter after candidate selection, without rewriting its identity.
            let privateCompletion = DesktopCandidateCompletion(
                authority: completion.authority, workerGeneration: completion.workerGeneration,
                batchID: completion.batchID, candidateID: completion.candidateID, commitID: completion.commitID,
                settingsRevision: completion.settingsRevision, privateInput: true)
            #expect(try !Candidates.complete(candidate, privateCompletion).learningRequested)
            #expect(Config.userDefaults.dictionaryRepresentation() as NSDictionary == preferences)
            #expect(CustomInputTableStore.load() == customTable)
        }
    }

    @Test func settingsCannotDiscardLiveBatchesAndClosedReceiptsCannotCrossTheNewRevision() throws {
        try Candidates.withWorker { worker, _ in
            var settings = Fixture.settings()
            settings.learning = .inputAndOutput
            try Fixture.configure(worker, settings: settings, revision: 1)
            let request = try Candidates.request("nihongo", settings: 1)
            let batch = try Candidates.batch(worker, request: request)
            try Candidates.retain(worker, batch)
            // Retrying the same ACK must keep the exact retained identity.
            try Fixture.configure(worker, settings: settings, revision: 1)
            settings.learning = .nothing
            #expect(throws: DesktopWorkerSettingsFailure.settingsBusy) {
                try Fixture.configure(worker, settings: settings, revision: 2)
            }
            let completion = try Candidates.completion(batch, text: "日本語", settings: 1)
            #expect(try Candidates.complete(worker, completion).learningRequested)
            #expect(try Candidates.complete(worker, completion).status == .alreadyCompleted)
            _ = try worker.process(.init(operation: "close", workerGeneration: worker.workerGeneration,
                                          context: request.authority.context, readingProcessGeneration: request.authority.readingProcessGeneration))
            try Fixture.configure(worker, settings: settings, revision: 2)
            #expect(throws: DesktopCandidateFailure.unknownBatch) { try Candidates.complete(worker, completion) }
            #expect(throws: DesktopCandidateFailure.staleAuthority) { try Candidates.batch(worker, request: request) }
            #expect(throws: DesktopWorkerSettingsFailure.fullSettingsRequired) {
                try Candidates.learning(worker, .inputAndOutput, revision: 3)
            }
            let latest = try Candidates.batch(worker, request: Candidates.request("nihongo", settings: 2))
            try Candidates.retain(worker, latest)
            #expect(try !Candidates.complete(worker, Candidates.completion(latest, text: "日本語", settings: 2)).learningRequested)
        }
    }

    @Test func aFailedPeerConfigurationLeavesTheOldSettingsAcknowledgementAndRejectsTheNewAuthority() throws {
        try Candidates.withWorker { worker, _ in
            var settings = Fixture.settings()
            try Fixture.configure(worker, settings: settings, revision: 1)
            settings.inputStyle = .custom
            settings.customTable = "invalid line"
            #expect(throws: DesktopWorkerSettingsFailure.invalidSettings) {
                try Fixture.configure(worker, settings: settings, revision: 2)
            }
            #expect(try worker.process(.init(operation: "settings")).settings == Fixture.settings())
            #expect(throws: DesktopCandidateFailure.staleAuthority) {
                try Candidates.batch(worker, request: Candidates.request("nihongo", settings: 2))
            }
            #expect(throws: DesktopCandidateFailure.wrongWorkerGeneration) {
                try worker.process(.init(operation: "configure-settings", workerGeneration: "old-process",
                                          settingsRevision: 2, settings: Fixture.settings()))
            }
            let batch = try Candidates.batch(worker, request: Candidates.request("nihongo", settings: 1))
            #expect(!batch.candidates.isEmpty)
        }
    }
}
