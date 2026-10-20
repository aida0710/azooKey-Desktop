public enum ReconversionShortcut {
    case undoCommit
    case selectedText

    public static func resolve(_ event: KeyEventCore) -> Self? {
        guard event.modifierFlags == [.control, .shift] else { return nil }
        if event.keyCode == 51 { return .undoCommit }
        if event.charactersIgnoringModifiers?.lowercased() == "r" { return .selectedText }
        return nil
    }
}
