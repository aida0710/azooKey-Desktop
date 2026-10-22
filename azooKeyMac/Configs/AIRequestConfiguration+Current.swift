import Core

extension AIRequestConfiguration {
    static func current() -> AIRequestConfiguration? {
        let backend: AIBackend
        switch Config.AIBackendPreference().value {
        case .off: return nil
        case .foundationModels: backend = .foundationModels
        case .openAI: backend = .openAI
        }
        let model = Config.OpenAiModelName().value
        let endpoint = Config.OpenAiApiEndpoint().value
        return AIRequestConfiguration(
            backend: backend,
            modelName: model.isEmpty ? Config.OpenAiModelName.default : model,
            apiKey: Config.OpenAiApiKey().value,
            apiEndpoint: endpoint.isEmpty ? Config.OpenAiApiEndpoint.default : endpoint
        )
    }

    /// Core's desktop view of the same settings. Unlike the desktop bridge,
    /// macOS also counts the on-device model as enabled.
    func desktopConfiguration() -> AIDesktopConfiguration {
        AIDesktopConfiguration(
            isEnabled: true, modelName: modelName, endpoint: apiEndpoint,
            includesContext: Config.IncludeContextInAITransform().value,
            transformShortcut: Config.TransformShortcut().value
        )
    }
}
