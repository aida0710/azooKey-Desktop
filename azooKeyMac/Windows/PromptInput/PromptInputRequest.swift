import Core

struct PromptInputRequest {
    let initialPrompt: String?
    let configuration: AIRequestConfiguration
    let targetText: String
}
