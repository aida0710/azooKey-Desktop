import Foundation

/// The text and destination shown before an AI request. Sending uses exactly
/// this content: a later settings change cannot redirect a reviewed request,
/// and the surrounding text leaves only when the user includes it.
public struct AIReviewContent: Sendable {
    public let target: String
    public let before: String
    public let after: String
    public let modelName: String
    public let endpoint: String
    public let includesContextByDefault: Bool

    public init(target: String, before: String, after: String, modelName: String, endpoint: String,
                includesContextByDefault: Bool) {
        self.target = target
        self.before = before.scalarSuffix(AITextSelection.contextScalarLimit)
        self.after = after.scalarPrefix(AITextSelection.contextScalarLimit)
        self.modelName = modelName
        self.endpoint = endpoint
        self.includesContextByDefault = includesContextByDefault
    }

    /// Host and port only; nil when the endpoint has none to show.
    public var destination: String? {
        AIRequestConfiguration.safeEndpointHost(endpoint)
    }

    public func arguments(includeContext: Bool, prompt: String? = nil) -> AIRequestArguments {
        AIRequestArguments(
            target: target, leftContext: includeContext ? before : "", rightContext: includeContext ? after : "",
            includeContext: includeContext, aiModel: modelName, aiEndpoint: endpoint, prompt: prompt
        )
    }
}

/// The fields of the bridge's `ai` and `transform` operations. The platform
/// adds only the API key, which never enters Core's review state.
public struct AIRequestArguments: Codable, Equatable, Sendable {
    public let target: String
    public let leftContext: String
    public let rightContext: String
    public let includeContext: Bool
    public let aiModel: String
    public let aiEndpoint: String
    /// The user's instruction for a selected-text transformation; nil for suggestions.
    public let prompt: String?
}
