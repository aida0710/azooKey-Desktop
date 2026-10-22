import Foundation

/// A key chord and the command Core gives it. Core publishes bindings so that
/// a platform whose key callback must answer at once (IBus, TSF) can tell,
/// without a round trip, which keys Core needs to see; Core still decides
/// what each key does when it arrives.
public struct DesktopKeyBinding: Codable, Equatable, Sendable {
    public enum Command: String, Codable, Sendable {
        /// Ask AI for candidates for the current composition.
        case suggestion
        /// Start entering a Unicode scalar by its code point.
        case unicode
        /// Open the selected-text AI prompt (only while text is selected).
        case prompt
        /// Send a reviewed AI suggestion request.
        case send
        /// Include or exclude the surrounding text in the reviewed request.
        case toggleContext
        /// Close the review without sending.
        case cancel
    }

    /// The lowercased character the key produces without modifiers.
    public var key: String?
    /// Matched instead of `key` for keys without a character, such as Escape.
    public var keyCode: UInt16?
    public var modifiers: KeyEventCore.ModifierFlag
    public var command: Command

    public init(key: String? = nil, keyCode: UInt16? = nil, modifiers: KeyEventCore.ModifierFlag, command: Command) {
        self.key = key?.lowercased()
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.command = command
    }

    public func matches(_ event: KeyEventCore) -> Bool {
        guard event.modifierFlags == modifiers else {
            return false
        }
        if let keyCode {
            return event.keyCode == keyCode
        }
        return key != nil && event.charactersIgnoringModifiers?.lowercased() == key
    }

    public static func command(for event: KeyEventCore, in bindings: [Self]) -> Command? {
        bindings.first { $0.matches(event) }?.command
    }
}

/// Chords Core acts on even when nothing is composed. They must reach Core
/// instead of the application; `UserAction` gives them their meaning.
public enum IMEShortcuts {
    public static let bindings: [DesktopKeyBinding] = [
        DesktopKeyBinding(key: "s", modifiers: [.control], command: .suggestion),
        DesktopKeyBinding(key: "u", modifiers: [.control, .shift], command: .unicode)
    ]
}
