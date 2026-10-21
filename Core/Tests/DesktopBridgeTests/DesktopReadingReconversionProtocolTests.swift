import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopReadingReconversionProtocolTests {
    private typealias Support = DesktopReadingReconversionTestSupport

    @Test(arguments: ["context-field", "query-field", "authority-field", "result-field", "wrong-operation"])
    func unknownReconversionPayloadsAreRejectedBeforeFormalInputChanges(change: String) throws {
        var fixture = try DesktopReadingWorkerFixture()
        let query = try #require(Support.prepare(&fixture, reading: nil).reconversionReadingRequest)
        let request = DesktopReadingWorkerRequest(operation: "resolve-reconversion", reference: fixture.reference,
            reconversionContext: Support.document(selected: "日本語"), reconversionReadingResult: .init(request: query, reading: "にほんご"))
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        var resolved = try #require(payload["reconversionReadingResult"] as? [String: Any])
        var queryPayload = try #require(resolved["request"] as? [String: Any])
        switch change {
        case "context-field":
            var context = try #require(payload["reconversionContext"] as? [String: Any])
            context["trusted"] = true
            payload["reconversionContext"] = context
        case "query-field": queryPayload["trusted"] = true
        case "authority-field":
            var authority = try #require(queryPayload["authority"] as? [String: Any])
            authority["trusted"] = true
            queryPayload["authority"] = authority
        case "result-field": resolved["trusted"] = true
        default: payload["operation"] = "select"
        }
        resolved["request"] = queryPayload
        payload["reconversionReadingResult"] = resolved
        let malformed = try JSONSerialization.data(withJSONObject: payload)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DesktopReadingWorkerRequest.self, from: malformed) }
        #expect(try fixture.snapshot().preedit.isEmpty)
        let valid = try fixture.worker.process(request)
        #expect(valid.reconversion?.text == "日本語")
    }

    @Test(arguments: ["cancel", "changed", "private", "readonly", "invalid", "oversized"])
    func localReadingFailureNeverAuthorizesDeletionOrEditsTheDocument(failure: String) throws {
        var fixture = try DesktopReadingWorkerFixture()
        let query = try #require(Support.prepare(&fixture, reading: nil).reconversionReadingRequest)
        let original = Support.document(selected: "日本語")
        _ = try fixture.worker.process(.init(operation: "resolve-reconversion", reference: fixture.reference,
            reconversionContext: original, reconversionReadingResult: .init(request: query, reading: nil)))
        let before = try DesktopReadingTestSupport.encodedJSON(fixture.snapshot())
        var context = original
        switch failure {
        case "changed": context.after = "別"
        case "private": context.isSensitive = true
        case "readonly": context.canReplace = false
        case "invalid": context.cursorUTF16 = -1
        default: break
        }
        let reply: DesktopReadingWorkerResponse
        if failure == "oversized" {
            reply = try fixture.worker.process(.init(operation: "reconvert", reference: fixture.reference,
                reconversionContext: original, reading: String(repeating: "あ", count: 257)))
        } else {
            reply = try fixture.worker.process(.init(operation: "reconversion-reading", reference: fixture.reference,
                event: Support.key(failure == "cancel" ? 53 : 36), reconversionContext: context))
        }
        #expect(reply.reconversion == nil && reply.snapshot == nil)
        #expect(reply.reconversionReading == nil)
        #expect(failure == "cancel" ? reply.reconversionError == nil : reply.reconversionError != nil)
        #expect(try DesktopReadingTestSupport.encodedJSON(fixture.snapshot()) == before)
        let lateEnter = try fixture.worker.process(.init(operation: "reconversion-reading", reference: fixture.reference,
            event: Support.key(36), reconversionContext: original))
        #expect(lateEnter.reconversionError == "stale_request")
        #expect(lateEnter.reconversion == nil)
    }
}
