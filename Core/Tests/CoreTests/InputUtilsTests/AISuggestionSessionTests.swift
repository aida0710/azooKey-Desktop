import Core
import Foundation
import Testing

@MainActor
private final class DeferredSuggestionSender {
    private var continuations: [CheckedContinuation<[String], Error>] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func send(_ request: AISuggestionRequest) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            for waiter in requestWaiters where continuations.count >= waiter.count {
                waiter.continuation.resume()
            }
            requestWaiters.removeAll { continuations.count >= $0.count }
        }
    }

    func waitForRequests(_ count: Int) async {
        if continuations.count >= count {
            return
        }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func finish(_ index: Int, with response: Result<[String], Error>) {
        continuations[index].resume(with: response)
    }
}

@MainActor
@Suite("AI suggestions keep pending input usable")
struct AISuggestionSessionTests {
    private var request: AISuggestionRequest {
        AISuggestionRequest(
            conversion: .init(prompt: "", target: "にほんご", modelName: "mock"),
            backend: .openAI, apiKey: "", apiEndpoint: "https://unused.invalid"
        )
    }

    @Test func startingOrRepeatingSuggestionsKeepsOrdinaryComposition() {
        for state in [InputState.none, .composing, .replaceSuggestion] {
            let (_, callback) = state.event(
                eventCore: .init(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 0),
                userAction: .suggest, inputLanguage: .japanese,
                liveConversionEnabled: false, enableDebugWindow: false, enableSuggestion: true
            )
            guard case .transition(.composing) = callback else {
                Issue.record("AI を待つ間も通常の入力状態を保つ必要があります: \(state)")
                continue
            }
            let (action, _) = InputState.composing.event(
                eventCore: .init(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36),
                userAction: .enter, inputLanguage: .japanese,
                liveConversionEnabled: false, enableDebugWindow: false, enableSuggestion: true
            )
            guard case .commitMarkedText = action else {
                Issue.record("候補待機中の Enter は元の入力を確定する必要があります")
                continue
            }
        }
    }

    @Test func startingAnotherRequestImmediatelyRemovesOldSuggestions() async {
        let sender = DeferredSuggestionSender()
        let session = AISuggestionSession(sendRequest: sender.send)
        let first = session.request(request) { _ in }
        await sender.waitForRequests(1)
        sender.finish(0, with: .success(["前の候補"]))
        await first.value
        #expect(session.selectedSuggestion == "前の候補")

        let second = session.request(request) { _ in }
        #expect(session.suggestions.isEmpty)
        #expect(session.selectedSuggestion == nil)
        #expect(session.isLoading)
        await sender.waitForRequests(2)
        sender.finish(1, with: .success([]))
        await second.value
    }

    @Test func cancelledRequestCannotOverwriteNewResultsWithTheSameReading() async {
        let sender = DeferredSuggestionSender()
        let session = AISuggestionSession(sendRequest: sender.send)
        var completions: [AISuggestionSession.Completion] = []
        let first = session.request(request) { completions.append($0) }
        await sender.waitForRequests(1)
        session.cancel()
        let second = session.request(request) { completions.append($0) }
        await sender.waitForRequests(2)
        sender.finish(1, with: .success(["新しい候補"]))
        await second.value
        sender.finish(0, with: .success(["古い候補"]))
        await first.value

        #expect(session.suggestions == ["新しい候補"])
        #expect(session.selectedSuggestion == "新しい候補")
        #expect(completions == [.candidates])
    }

    @Test func cancelledFailureDoesNotPublishAnErrorToAnotherComposition() async {
        let sender = DeferredSuggestionSender()
        let session = AISuggestionSession(sendRequest: sender.send)
        var completions: [AISuggestionSession.Completion] = []
        let task = session.request(request) { completions.append($0) }
        await sender.waitForRequests(1)
        session.cancel()
        sender.finish(0, with: .failure(URLError(.timedOut)))
        await task.value

        #expect(completions.isEmpty)
        #expect(!session.isLoading)
        #expect(session.selectedSuggestion == nil)
    }

    @Test func emptyResultsAndErrorsNeverProvideASelectableCandidate() async {
        let sender = DeferredSuggestionSender()
        let session = AISuggestionSession(sendRequest: sender.send)
        var completions: [AISuggestionSession.Completion] = []
        let emptyTask = session.request(request) { completions.append($0) }
        await sender.waitForRequests(1)
        sender.finish(0, with: .success(["", " \n"]))
        await emptyTask.value
        #expect(completions == [.empty])
        #expect(session.selectedSuggestion == nil)

        let failedTask = session.request(request) { completions.append($0) }
        await sender.waitForRequests(2)
        sender.finish(1, with: .failure(URLError(.notConnectedToInternet)))
        await failedTask.value
        #expect(completions == [.empty, .failed])
        #expect(session.selectedSuggestion == nil)
        #expect(!session.isLoading)
    }
}
