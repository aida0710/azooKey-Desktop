import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopReadingWorkerTests {
    private func request(_ operation: String, context: String, text: String? = nil) -> BridgeRequest {
        let event = text.map {
            KeyEventCore(modifierFlags: [], characters: $0, charactersIgnoringModifiers: $0, keyCode: 0)
        }
        return BridgeRequest(operation: operation, event: event, context: context)
    }

    @Test func independentContextsKeepTheirOwnReadingAndCancellation() throws {
        var worker = DesktopReadingWorker()
        let first = try worker.process(request("key", context: "first", text: "nihongo"))
        #expect(first.reading == "にほんご")
        let second = try worker.process(request("key", context: "second", text: "kyou"))
        #expect(second.reading == "きょう")
        let firstAgain = try worker.process(request("snapshot", context: "first"))
        #expect(firstAgain.reading == "にほんご")
        _ = try worker.process(request("close", context: "first"))
        let reopened = try worker.process(request("snapshot", context: "first"))
        #expect(reopened.reading.isEmpty)
        let retained = try worker.process(request("snapshot", context: "second"))
        #expect(retained.reading == "きょう")
    }

    @Test func unsupportedRequestsReturnTheUnchangedReadingWithoutCommitting() throws {
        var worker = DesktopReadingWorker()
        _ = try worker.process(request("key", context: "field", text: "nihongo"))
        let unsupported = request("configure", context: "field")
        #expect(throws: BridgeMain.ProtocolError.self) {
            try worker.process(unsupported)
        }
        let rejected = worker.rejected(unsupported, error: BridgeMain.ProtocolError.invalidRequest)
        #expect(!rejected.consumed)
        #expect(rejected.error == "invalid_request")
        #expect(rejected.reading == "にほんご")
        #expect(rejected.preedit == "にほんご")
        #expect(rejected.commits.isEmpty)
        let next = try worker.process(request("key", context: "field", text: "a"))
        #expect(next.reading == "にほんごあ")
    }
}
