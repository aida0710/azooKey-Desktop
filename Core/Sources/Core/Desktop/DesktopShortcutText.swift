import Foundation

/// The typed notation of a keyboard shortcut on the desktop, such as
/// `Ctrl+Alt+e`: modifier names joined by `+`, then one character.
public enum DesktopShortcutText {
    public enum Failure: String, Error, Codable, Sendable {
        /// Not modifier names followed by a single character.
        case format
        /// A character without Ctrl, Alt, Shift or Super.
        case modifierRequired
    }

    // Display order of the modifier names; parsing accepts any order.
    private static let modifierNames: [(name: String, flag: KeyEventCore.ModifierFlag)] = [
        ("Ctrl", .control), ("Alt", .option), ("Shift", .shift), ("Super", .command)
    ]

    /// nil for blank text, which means "no shortcut".
    public static func parse(_ text: String) throws(Failure) -> KeyboardShortcut? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, key.unicodeScalars.count == 1 else {
            throw .format
        }
        var modifiers: KeyEventCore.ModifierFlag = []
        for part in parts.dropLast() {
            guard let modifier = modifierNames.first(where: { $0.name.lowercased() == part }) else {
                throw .format
            }
            modifiers.insert(modifier.flag)
        }
        guard !modifiers.isEmpty else {
            throw .modifierRequired
        }
        return KeyboardShortcut(key: key, modifiers: modifiers)
    }

    public static func text(for shortcut: KeyboardShortcut?) -> String {
        guard let shortcut else {
            return ""
        }
        let names = modifierNames.filter { shortcut.modifiers.contains($0.flag) }.map(\.name)
        return (names + [shortcut.key]).joined(separator: "+")
    }
}
