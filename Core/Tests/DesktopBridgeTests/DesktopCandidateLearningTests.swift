import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopCandidateLearningTests {
    private typealias Fixture = DesktopCandidateTestSupport

    @Test(arguments: [Config.Learning.Value.onlyOutput, .nothing])
    func disablingUpdatesAfterSelectionUsesTheCommitTimeMode(mode: Config.Learning.Value) throws {
        try Fixture.withWorker { worker, directory in
            let selected = try Fixture.batch(worker, request: Fixture.request("kyou"))
            try Fixture.retain(worker, selected)
            let before = try Fixture.memory(in: directory)
            try Fixture.learning(worker, mode, revision: 1)
            let completion = try Fixture.completion(selected, text: "京", settings: 1)
            let completed = try Fixture.complete(worker, completion)
            #expect(completed.status == .completed)
            #expect(!completed.learningRequested)
            #expect(Config.Learning().value == mode)
            #expect(try Fixture.memory(in: directory) == before)
        }
    }

    @Test func enablingUpdatesAfterSelectionKeepsTheActualCandidateAndSavesLearningOnce() throws {
        try Fixture.withWorker { worker, directory in
            try Fixture.learning(worker, .nothing, revision: 1)
            let selected = try Fixture.batch(worker, request: Fixture.request("kyou", settings: 1))
            try Fixture.retain(worker, selected)
            let before = try Fixture.memory(in: directory)
            try Fixture.learning(worker, .inputAndOutput, revision: 2)
            let completed = try Fixture.complete(worker, Fixture.completion(selected, text: "京", settings: 2))
            #expect(completed.status == .completed)
            #expect(completed.learningRequested)
            #expect(try Fixture.memory(in: directory) != before)
        }
    }

    @Test(arguments: [true, false], [true, false])
    func eitherPrivateBoundaryDisablesLearningWithoutChangingThePreference(sourcePrivate: Bool, commitPrivate: Bool) throws {
        try Fixture.withWorker { worker, directory in
            let selected = try Fixture.batch(worker, request: Fixture.request("kyou", privateInput: sourcePrivate))
            try Fixture.retain(worker, selected)
            let before = try Fixture.memory(in: directory)
            let completed = try Fixture.complete(worker, Fixture.completion(selected, text: "京", privateInput: commitPrivate))
            #expect(completed.learningRequested == (!sourcePrivate && !commitPrivate))
            #expect(Config.Learning().value == .inputAndOutput)
            if sourcePrivate || commitPrivate {
                #expect(try Fixture.memory(in: directory) == before)
            } else {
                #expect(try Fixture.memory(in: directory) != before)
            }
        }
    }

    @Test func aStaleLearningRevisionCannotChangeTheSettingOrCommitTheSelectedCandidate() throws {
        try Fixture.withWorker { worker, _ in
            let selected = try Fixture.batch(worker, request: Fixture.request("kyou"))
            try Fixture.retain(worker, selected)
            try Fixture.learning(worker, .nothing, revision: 1)
            #expect(throws: DesktopCandidateFailure.staleAuthority) { try Fixture.learning(worker, .inputAndOutput, revision: 0) }
            #expect(Config.Learning().value == .nothing)
            #expect(throws: DesktopCandidateFailure.staleAuthority) {
                try Fixture.complete(worker, Fixture.completion(selected, text: "京"))
            }
            #expect(try Fixture.complete(worker, Fixture.completion(selected, text: "京", settings: 1)).status == .completed)
        }
    }

    @Test func aLostCompletionAckCanBeReadAfterALaterLearningChangeWithoutLearningAgain() throws {
        try Fixture.withWorker { worker, directory in
            let selected = try Fixture.batch(worker, request: Fixture.request("kyou"))
            try Fixture.retain(worker, selected)
            let request = try Fixture.completion(selected, text: "京")
            _ = try Fixture.complete(worker, request)
            let before = try Fixture.memory(in: directory)
            try Fixture.learning(worker, .nothing, revision: 1)
            let receipt = try Fixture.complete(worker, request)
            #expect(receipt.status == .alreadyCompleted)
            #expect(receipt.learningRequested)
            #expect(Config.Learning().value == .nothing)
            #expect(try Fixture.memory(in: directory) == before)
        }
    }
}
