import Foundation

/// A request captures its settings so changes made while it is pending cannot
/// redirect it to another backend.
public struct AISuggestionRequest: Sendable {
    public let conversion: OpenAIRequest
    public let backend: AIBackend
    public let apiKey: String
    public let apiEndpoint: String

    public init(conversion: OpenAIRequest, backend: AIBackend, apiKey: String, apiEndpoint: String) {
        self.conversion = conversion
        self.backend = backend
        self.apiKey = apiKey
        self.apiEndpoint = apiEndpoint
    }
}

/// Owns asynchronous AI results independently of the ordinary composition.
/// Cancelled requests may still finish; only the current request can publish.
@MainActor
public final class AISuggestionSession {
    public typealias RequestSender = @MainActor (AISuggestionRequest) async throws -> [String]

    public enum Completion: Equatable {
        case candidates
        case empty
        case failed
    }

    // Match the desktop bridge limit to keep an untrusted response bounded.
    private static let maximumCandidateCount = 30
    public var sendRequest: RequestSender
    public private(set) var suggestions: [String] = []
    public private(set) var selectedIndex: Int?
    public private(set) var isLoading = false
    private var requestID: UUID?
    private var requestTask: Task<Void, Never>?

    public init(sendRequest: @escaping RequestSender = AISuggestionSession.sendWithConfiguredBackend) {
        self.sendRequest = sendRequest
    }

    public static func sendWithConfiguredBackend(_ request: AISuggestionRequest) async throws -> [String] {
        try await AIClient.sendRequest(
            request.conversion,
            backend: request.backend,
            apiKey: request.apiKey,
            apiEndpoint: request.apiEndpoint
        )
    }

    @discardableResult
    public func request(
        _ request: AISuggestionRequest,
        completion: @escaping @MainActor (Completion) -> Void
    ) -> Task<Void, Never> {
        cancel()
        let requestID = UUID()
        self.requestID = requestID
        self.isLoading = true
        let sendRequest = self.sendRequest
        let task = Task { [weak self] in
            let response: Result<[String], Error>
            do {
                response = .success(try await sendRequest(request))
            } catch {
                response = .failure(error)
            }
            guard let self, self.requestID == requestID, !Task.isCancelled else {
                return
            }
            self.requestTask = nil
            self.isLoading = false
            switch response {
            case .success(let texts):
                self.suggestions = Array(texts.filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }.prefix(Self.maximumCandidateCount))
                self.selectedIndex = self.suggestions.isEmpty ? nil : 0
                completion(self.suggestions.isEmpty ? .empty : .candidates)
            case .failure:
                completion(.failed)
            }
        }
        self.requestTask = task
        return task
    }

    public func cancel() {
        requestID = nil
        requestTask?.cancel()
        requestTask = nil
        isLoading = false
        suggestions = []
        selectedIndex = nil
    }

    public func waitForPendingRequest() async {
        await requestTask?.value
    }

    public func select(_ index: Int) {
        guard suggestions.indices.contains(index) else {
            return
        }
        selectedIndex = index
    }

    public var selectedSuggestion: String? {
        guard let selectedIndex, suggestions.indices.contains(selectedIndex) else {
            return nil
        }
        return suggestions[selectedIndex]
    }
}
