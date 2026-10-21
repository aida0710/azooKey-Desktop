import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopCandidateReconversionReadingTests {
    @Test func dictionaryReadingResolutionDoesNotCreateCandidatesLearnOrWriteSettings() throws {
        try DesktopCandidateTestSupport.withWorker { worker, directory in
            let previous = Config.UserDictionary().value
            var dictionary = previous
            dictionary.items = [.init(word: "相田", reading: "あいだ")]
            Config.UserDictionary().value = dictionary
            defer { Config.UserDictionary().value = previous }
            let beforeMemory = try DesktopCandidateTestSupport.memory(in: directory)
            let beforeSettings = try DesktopReadingTestSupport.encodedJSON(Config.UserDictionary().value)
            let authority = try DesktopCandidateTestSupport.request("").authority
            for (text, reading) in [("相田", "あいだ"), ("ニホンゴ", "にほんご"), ("日本語", nil)] {
                let request = DesktopReconversionReadingRequest(authority: authority, workerGeneration: worker.workerGeneration,
                                                               text: text, privateInput: false)
                let reply = try worker.process(.init(operation: "resolve-reconversion-reading", reconversionReadingRequest: request))
                #expect(reply.reconversionReadingResult?.reading == reading)
                #expect(reply.reconversionReadingResult?.request.matches(request) == true)
                #expect(reply.authority == authority)
                #expect(reply.batch == nil && reply.completion == nil)
            }
            #expect(try DesktopCandidateTestSupport.memory(in: directory) == beforeMemory)
            #expect(try DesktopReadingTestSupport.encodedJSON(Config.UserDictionary().value) == beforeSettings)
            // A lookup alone must not create a candidate session that makes configuration busy.
            _ = try DesktopWorkerSettingsFixture.configure(worker, settings: DesktopWorkerSettingsFixture.settings(), revision: 1)
        }
    }

    @Test(arguments: ["worker", "settings", "private", "oversized"])
    func invalidDictionaryAuthorityProducesNoResolvedReading(change: String) throws {
        try DesktopCandidateTestSupport.withWorker { worker, _ in
            let authority = try DesktopCandidateTestSupport.request("", settings: change == "settings" ? 1 : 0).authority
            let request = DesktopReconversionReadingRequest(authority: authority,
                workerGeneration: change == "worker" ? "old-worker" : worker.workerGeneration,
                text: change == "oversized" ? String(repeating: "あ", count: 257) : "ニホンゴ", privateInput: change == "private")
            #expect(throws: (any Error).self) {
                try worker.process(.init(operation: "resolve-reconversion-reading", reconversionReadingRequest: request))
            }
        }
    }

    @Test func canonicallyEquivalentDictionarySurfaceDoesNotSupplyAnotherByteStringsReading() {
        let entries = [Config.UserDictionaryEntry(word: "\u{212B}", reading: "おんぐすとろーむ")]
        #expect("\u{212B}" == "Å")
        #expect(ReconversionReading.resolve("\u{212B}", dictionary: entries) == "おんぐすとろーむ")
        #expect(ReconversionReading.resolve("Å", dictionary: entries) == nil)
    }
}
