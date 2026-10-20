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

