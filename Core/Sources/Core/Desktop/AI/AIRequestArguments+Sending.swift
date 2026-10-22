import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends reviewed arguments to the OpenAI-compatible API. The bridge runs
/// this in a separate process so a slow reply never holds up conversion.
extension AIRequestArguments {
    public enum SendingFailure: Error {
        /// A transformation needs the user's instruction.
        case missingInstruction
    }

    /// Candidates for the reviewed text.
    public func requestSuggestions(apiKey: String, session: URLSession = .shared) async throws -> [String] {
        try await OpenAIClient.sendRequest(
            .init(prompt: scope.suggestionContext, target: target, modelName: modelName),
            apiKey: apiKey, apiEndpoint: aiEndpoint, session: session
        )
    }

    /// The reviewed text transformed by the user's instruction.
    public func requestTransformation(apiKey: String, session: URLSession = .shared) async throws -> String {
        guard let prompt else {
            throw SendingFailure.missingInstruction
        }
        return try await OpenAIClient.sendTextTransformRequest(
            prompt: scope.transformationPrompt(instructions: prompt), modelName: modelName,
            apiKey: apiKey, apiEndpoint: aiEndpoint, session: session
        )
    }

    /// Surrounding text leaves only when included, whatever else the arguments carry.
    private var scope: AIRequestScope {
        AIRequestScope(target: target, before: leftContext, after: rightContext, includeContext: includeContext)
    }

    /// A blank model name selects the default model.
    private var modelName: String {
        aiModel.isEmpty ? Config.OpenAiModelName.default : aiModel
    }
}
