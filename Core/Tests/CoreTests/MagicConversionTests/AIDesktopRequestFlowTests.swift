import Core
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
// Kept beside OpenAIClient, after Desktop/Settings in file order: when a file
// importing FoundationNetworking is compiled earlier in the same batch, Glibc's
// `struct stat` becomes owned by that module and invisible to later files that
// import only Glibc (Swift 6.2 on Linux).
import Testing

/// Replies of a local mock API, chosen by the instruction in each request.
/// Nothing leaves the process: the session only knows this protocol.
private final class FlowMockProtocol: URLProtocol {
    /// Held replies are released by the test, in any order.
    static let gates = ReplyGates()

    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "flow.mock.invalid" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let instruction = Self.instruction(in: readBody())
        let loading = Loading(protocolInstance: self)
        // Replying from another queue lets the test hold one reply while others continue.
        DispatchQueue.global().async {
            if instruction.hasPrefix("held:") {
                Self.gates.wait(for: instruction)
            }
            switch instruction {
            case "server-error":
                loading.protocolInstance.reply(status: 500, body: Data("synthetic failure".utf8))
            case "malformed":
                loading.protocolInstance.reply(status: 200, body: Data("not json".utf8))
            case "empty":
                loading.protocolInstance.reply(status: 200, body: Self.choices(content: #"{"result": ""}"#))
            default:
                loading.protocolInstance.reply(status: 200, body: Self.choices(content: #"{"result": "\#(instruction)の本文"}"#))
            }
        }
    }

    /// URLProtocol is not Sendable; Foundation calls it from one loading thread at a time.
    private struct Loading: @unchecked Sendable {
        let protocolInstance: FlowMockProtocol
    }

    override func stopLoading() {}

    private func reply(status: Int, body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func choices(content: String) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    }

    private static func instruction(in body: Data) -> String {
        let text = String(bytes: body, encoding: .utf8) ?? ""
        guard let range = text.range(of: "User instructions: ") else {
            return ""
        }
        return String(text[range.upperBound...].prefix { $0 != "\"" && $0 != "\\" })
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
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

private final class ReplyGates: @unchecked Sendable {
    private let lock = NSLock()
    private var semaphores: [String: DispatchSemaphore] = [:]

    private func semaphore(_ name: String) -> DispatchSemaphore {
        lock.lock()
        defer { lock.unlock() }
        if let existing = semaphores[name] {
            return existing
        }
        let created = DispatchSemaphore(value: 0)
        semaphores[name] = created
        return created
    }

    func wait(for name: String) { semaphore(name).wait() }
    func release(_ name: String) { semaphore(name).signal() }
}

/// The selected-text chain as a platform runs it: Core's arguments, the API
/// request, then Core's decision on the reply.
@Suite("AI request flow", .serialized)
struct AIDesktopRequestFlowTests {
    typealias Fixture = AITransformationTargetTests

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlowMockProtocol.self]
        return URLSession(configuration: configuration)
    }()

    static func transformation() throws -> AISelectedTextTransformation {
        var configuration = AISelectedTextTransformationTests.configuration
        configuration.endpoint = "https://flow.mock.invalid/v1/chat/completions"
        var transformation = try #require(AISelectedTextTransformation(id: 1, field: Fixture.field(), configuration: configuration))
        transformation.attachWitness(Fixture.witness(), current: Fixture.field())
        return transformation
    }

    /// What the platform reports to Core: the text, or nil when the request failed.
    static func send(_ arguments: AIRequestArguments?) async -> String? {
        guard let arguments else {
            return nil
        }
        return try? await arguments.requestTransformation(apiKey: "local-test-placeholder", session: session)
    }

    static func start(_ transformation: inout AISelectedTextTransformation, _ instruction: String) throws
        -> (revision: Int, reply: Task<String?, Never>) {
        let started = try transformation.beginPreview(prompt: instruction, includeContext: false, field: Fixture.field())
        let arguments = started.arguments
        return (started.revision, Task { await send(arguments) })
    }

    @Test func aDelayedReplyIsAppliedOnlyWhileItIsCurrent() async throws {
        var transformation = try Self.transformation()
        let request = try Self.start(&transformation, "held:slow")
        #expect(transformation.isLoading && transformation.applicableText == nil)
        FlowMockProtocol.gates.release("held:slow")
        let text = await request.reply.value
        #expect(text == "held:slowの本文")
        let accepted = transformation.completePreview(revision: request.revision, text: text, inputContextChanged: false)
        #expect(accepted && transformation.applicableText == "held:slowの本文")
    }

    @Test func repliesInReverseOrderKeepOnlyTheCurrentPreview() async throws {
        var transformation = try Self.transformation()
        let first = try Self.start(&transformation, "held:first")
        transformation.invalidatePreview()
        let second = try Self.start(&transformation, "held:second")
        FlowMockProtocol.gates.release("held:second")
        let secondText = await second.reply.value
        let secondAccepted = transformation.completePreview(revision: second.revision, text: secondText, inputContextChanged: false)
        FlowMockProtocol.gates.release("held:first")
        let firstText = await first.reply.value
        let firstAccepted = transformation.completePreview(revision: first.revision, text: firstText, inputContextChanged: false)
        #expect(secondAccepted && !firstAccepted)
        #expect(transformation.applicableText == "held:secondの本文")
        let confirmed = transformation.confirm()
        let replacement = transformation.takeReplacement(for: Fixture.field(), witness: Fixture.witness())
        #expect(confirmed && replacement == "held:secondの本文")
    }

    @Test(arguments: ["empty", "server-error", "malformed"])
    func emptyFailedOrMalformedRepliesLeaveNothingToApply(instruction: String) async throws {
        var transformation = try Self.transformation()
        let previous = try Self.start(&transformation, "前回")
        transformation.completePreview(revision: previous.revision, text: await previous.reply.value, inputContextChanged: false)
        let request = try Self.start(&transformation, instruction)
        let text = await request.reply.value
        transformation.completePreview(revision: request.revision, text: text, inputContextChanged: false)
        #expect(!transformation.isLoading && transformation.applicableText == nil)
        let confirmed = transformation.confirm()
        #expect(!confirmed)
    }

    @Test func reviewedSuggestionArgumentsCarryNoExcludedContextOrInstruction() async throws {
        let review = AISuggestionReview(id: 1, reading: "にほんご", generation: 1, before: "PRIVATE_BEFORE", after: "",
                                        configuration: AISuggestionReviewTests.configuration)
        let arguments = review.content.arguments(includeContext: false)
        let encoded = String(bytes: try JSONEncoder().encode(arguments), encoding: .utf8)
        #expect(encoded?.contains("PRIVATE_BEFORE") == false)
        await #expect(throws: AIRequestArguments.SendingFailure.self) {
            _ = try await arguments.requestTransformation(apiKey: "local-test-placeholder", session: Self.session)
        }
    }

    @Test func aSuggestionRequestKeepsTheReviewedDestinationWithTheChosenBackend() {
        let review = AISuggestionReview(id: 1, reading: "にほんご", generation: 1, before: "", after: "",
                                        configuration: AISuggestionReviewTests.configuration)
        let request = review.content.arguments(includeContext: false)
            .suggestionRequest(backend: .foundationModels, apiKey: "local-test-placeholder")
        #expect(request.backend == .foundationModels)
        #expect(request.apiKey == "local-test-placeholder")
        #expect(request.apiEndpoint == AISuggestionReviewTests.configuration.endpoint)
    }
}
