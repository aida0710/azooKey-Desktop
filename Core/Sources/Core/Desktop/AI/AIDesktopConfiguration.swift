import Foundation

/// The AI preferences one desktop decision depends on, read together so a
/// review and its request use the same values.
public struct AIDesktopConfiguration: Sendable {
    /// The desktop bridge talks only to an OpenAI-compatible API.
    public var isEnabled: Bool
    public var modelName: String
    public var endpoint: String
    public var includesContext: Bool
    public var transformShortcut: KeyboardShortcut

    public init(isEnabled: Bool, modelName: String, endpoint: String, includesContext: Bool, transformShortcut: KeyboardShortcut) {
        self.isEnabled = isEnabled
        self.modelName = modelName
        self.endpoint = endpoint
        self.includesContext = includesContext
        self.transformShortcut = transformShortcut
    }

    public static func current() -> Self {
        Self(
            isEnabled: Config.AIBackendPreference().value == .openAI,
            modelName: Config.OpenAiModelName().value,
            endpoint: Config.OpenAiApiEndpoint().value,
            includesContext: Config.IncludeContextInAITransform().value,
            transformShortcut: Config.TransformShortcut().value
        )
    }
}
