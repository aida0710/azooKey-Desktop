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
        try await OpenAIClient.sendRequest(suggestionConversion, apiKey: apiKey, apiEndpoint: aiEndpoint, session: session)
    }

    /// The reviewed suggestion request for the backend the platform chose.
    /// The macOS app can also answer it with the on-device model.
    public func suggestionRequest(backend: AIBackend, apiKey: String) -> AISuggestionRequest {
        AISuggestionRequest(conversion: suggestionConversion, backend: backend, apiKey: apiKey, apiEndpoint: aiEndpoint)
    }

    /// The reviewed text transformed by the user's instruction. The bridge
    /// always uses the OpenAI-compatible API; the macOS app may choose the
    /// on-device model, which ignores the model name, key and endpoint.
    public func requestTransformation(backend: AIBackend = .openAI, apiKey: String,
                                      session: URLSession = .shared) async throws -> String {
        guard let prompt else {
            throw SendingFailure.missingInstruction
        }
        let instructions = scope.transformationPrompt(instructions: prompt)
        switch backend {
        case .foundationModels:
            return try await FoundationModelsClientCompat.sendTextTransformRequest(instructions)
        case .openAI:
            return try await OpenAIClient.sendTextTransformRequest(
                prompt: instructions, modelName: modelName, apiKey: apiKey, apiEndpoint: aiEndpoint, session: session
            )
        }
    }

    private var suggestionConversion: OpenAIRequest {
        OpenAIRequest(prompt: scope.suggestionContext, target: target, modelName: modelName)
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
