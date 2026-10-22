import Foundation

/// Keys that open the selected-text AI prompt. The caller applies them only
/// while text is selected in a field that is not sensitive and AI is enabled.
public struct AIPromptShortcuts: Sendable {
    /// Double-tapping 英数 or かな asks for a translation of the selection.
    private static let doubleTapPrompts: [UInt16: String] = [102: "english", 104: "japanese"]

    /// Pinned instructions in history order; the first matching one wins.
    public let pinned: [(shortcut: KeyboardShortcut, prompt: String)]
    /// Opens the prompt with an empty instruction.
    public let transformShortcut: KeyboardShortcut

    public init(pinned: [(shortcut: KeyboardShortcut, prompt: String)], transformShortcut: KeyboardShortcut) {
        self.pinned = pinned
        self.transformShortcut = transformShortcut
    }

    /// The instruction the prompt starts with, or nil when the key opens no prompt.
    public func initialPrompt(for event: KeyEventCore, doubleTap: Bool) -> String? {
        if let match = pinned.first(where: { Self.binding($0.shortcut).matches(event) }) {
            return match.prompt
        }
        if Self.binding(transformShortcut).matches(event) {
            return ""
        }
        return doubleTap ? Self.doubleTapPrompts[event.keyCode] : nil
    }

    /// Chords that must reach Core while text is selected. The double-tapped
    /// language keys are not listed: they always reach Core.
    public var bindings: [DesktopKeyBinding] {
        (pinned.map(\.shortcut) + [transformShortcut]).map(Self.binding)
    }

    private static func binding(_ shortcut: KeyboardShortcut) -> DesktopKeyBinding {
        DesktopKeyBinding(key: shortcut.key, modifiers: shortcut.modifiers, command: .prompt)
    }
}
