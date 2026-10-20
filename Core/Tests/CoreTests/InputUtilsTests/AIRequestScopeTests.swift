@testable import Core
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

private final class RequestBodyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []

    func append(_ body: Data) {
        lock.lock()
        defer { lock.unlock() }
        bodies.append(body)
    }

    func takeLast() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        defer { bodies.removeAll() }
        return bodies.last
    }
}

private final class ScopeMockProtocol: URLProtocol {
    static let recorder = RequestBodyRecorder()

    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "mock.invalid" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            Self.recorder.append(readBody())
            let content: [String: Any] = request.url?.path == "/transform"
                ? ["result": "模擬の変換結果"] : ["predictions": ["模擬の候補"]]
            let contentData = try JSONSerialization.data(withJSONObject: content)
            let contentJSON = try #require(String(bytes: contentData, encoding: .utf8))
            let body = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": contentJSON]]]
            ])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func readBody() -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var body = Data()
        // A small buffer also covers URLSession implementations that stream JSON.
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }

    override func stopLoading() {}
}

@Suite("AI request scope", .serialized)
struct AIRequestScopeTests {
    @Test func destinationDisplaysOnlyTheHostAndPort() {
        let endpoint = "https://user:credential@example.invalid:8443/private-key/path?api_key=private-value#private-fragment"
        #expect(AIRequestConfiguration.safeEndpointHost(endpoint) == "example.invalid:8443")
        #expect(AIRequestConfiguration.safeEndpointHost("file:///private/secret") == nil)
        #expect(AIRequestConfiguration.safeEndpointHost("not a URL") == nil)
    }

    @Test func onDeviceDestinationDoesNotDisplayAnUnusedExternalEndpoint() {
        let configuration = AIRequestConfiguration(
            backend: .foundationModels, modelName: "", apiKey: "", apiEndpoint: "https://secret.example.invalid"
        )
        #expect(configuration.destinationLabel == Localization.text("ai.destination.on-device"))
        #expect(!configuration.destinationLabel.contains("secret.example.invalid"))
    }

    @Test func contextIsLimitedAtCharacterBoundaries() {
        let grapheme = "👩🏽‍💻"
        let scope = AIRequestScope(
            target: "対象", before: "除外" + String(repeating: grapheme, count: 101),
            after: String(repeating: "か\u{3099}", count: 101) + "除外", includeContext: true
        )
        #expect(scope.before.count == AIRequestScope.contextCharacterLimit)
        #expect(scope.after.count == AIRequestScope.contextCharacterLimit)
        #expect(scope.before == String(repeating: grapheme, count: 100))
        #expect(scope.after == String(repeating: "か\u{3099}", count: 100))
    }

    @Test(arguments: [false, true])
    func suggestionPayloadIncludesSurroundingTextOnlyWhenSelected(_ includeContext: Bool) async throws {
        let scope = AIRequestScope(
            target: "TARGET_TEXT", before: "PRIVATE_BEFORE", after: "PRIVATE_AFTER", includeContext: includeContext
        )
        let configuration = AIRequestConfiguration(
            backend: .openAI, modelName: "mock", apiKey: "test-key", apiEndpoint: "https://mock.invalid/suggest"
        )
        let request = configuration.suggestionRequest(scope: scope)
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let suggestions = try await OpenAIClient.sendRequest(
            request.conversion, apiKey: request.apiKey, apiEndpoint: request.apiEndpoint, session: session
        )
        #expect(suggestions == ["模擬の候補"])
        try expectPayload(includeContext: includeContext)
    }

    @Test(arguments: [false, true])
    func transformationPayloadIncludesSurroundingTextOnlyWhenSelected(_ includeContext: Bool) async throws {
        let scope = AIRequestScope(
            target: "TARGET_TEXT", before: "PRIVATE_BEFORE", after: "PRIVATE_AFTER", includeContext: includeContext
        )
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let text = try await OpenAIClient.sendTextTransformRequest(
            prompt: scope.transformationPrompt(instructions: "整えて"),
            modelName: "mock", apiKey: "test-key", apiEndpoint: "https://mock.invalid/transform", session: session
        )
        #expect(text == "模擬の変換結果")
        try expectPayload(includeContext: includeContext)
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScopeMockProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func expectPayload(includeContext: Bool) throws {
        let body = try #require(ScopeMockProtocol.recorder.takeLast())
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: String]])
        let userMessage = try #require(messages.first { $0["role"] == "user" }?["content"])
        #expect(userMessage.contains("TARGET_TEXT"))
        let entireBody = try #require(String(bytes: body, encoding: .utf8))
        #expect(entireBody.contains("PRIVATE_BEFORE") == includeContext)
        #expect(entireBody.contains("PRIVATE_AFTER") == includeContext)
    }
}
