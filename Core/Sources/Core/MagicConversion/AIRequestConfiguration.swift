import Foundation

/// Freeze the displayed destination and the request destination together.
public struct AIRequestConfiguration: Sendable {
    public let backend: AIBackend
    public let modelName: String
    public let apiKey: String
    public let apiEndpoint: String

    public init(backend: AIBackend, modelName: String, apiKey: String, apiEndpoint: String) {
        self.backend = backend
        self.modelName = modelName
        self.apiKey = apiKey
        self.apiEndpoint = apiEndpoint
    }

    public var destinationLabel: String {
        switch backend {
        case .foundationModels:
            return Localization.text("ai.destination.on-device")
        case .openAI:
            return Self.safeEndpointHost(apiEndpoint) ?? Localization.text("ai.destination.invalid")
        }
    }

    public static func safeEndpointHost(_ endpoint: String) -> String? {
        guard let url = URLComponents(string: endpoint),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else {
            return nil
        }
        // Credentials can appear in userinfo, paths and queries. None belong
        // in a destination label, even for a custom endpoint.
        return url.port.map { "\(host):\($0)" } ?? host
    }

    public func suggestionRequest(scope: AIRequestScope) -> AISuggestionRequest {
        AISuggestionRequest(
            conversion: .init(prompt: scope.suggestionContext, target: scope.target, modelName: modelName),
            backend: backend, apiKey: apiKey, apiEndpoint: apiEndpoint
        )
    }
}
