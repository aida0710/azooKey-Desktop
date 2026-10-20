import Core
import Testing

@Test(arguments: ["👩‍💻", "e\u{301}", "🇯🇵", "𠮷"])
func visibleUnicodeGraphemesAreAcceptedAsInput(text: String) {
    let event = KeyEventCore(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: 0xFFFF)
    guard case .input = UserAction.getUserAction(eventCore: event, inputLanguage: .japanese) else {
        Issue.record("Expected printable grapheme input")
        return
    }
}

@Test(arguments: ["", "\u{200D}", "\n", "A\n", "\u{1B}"])
func nonprintingControlTextIsNotInserted(text: String) {
    let event = KeyEventCore(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: 0xFFFF)
    guard case .unknown = UserAction.getUserAction(eventCore: event, inputLanguage: .japanese) else {
        Issue.record("Expected nonprinting text to remain unhandled")
        return
    }
}
