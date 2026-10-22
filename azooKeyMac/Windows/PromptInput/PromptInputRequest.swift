import Core

struct PromptInputRequest {
    let initialPrompt: String?
    let configuration: AIRequestConfiguration
    /// Core's state for the selection the window was opened for.
    let transformation: AISelectedTextTransformation
    /// The field as read when the window opened. The window holds the keyboard
    /// focus while it is open, so these facts stand for the original field.
    let openedField: AITextField
}
