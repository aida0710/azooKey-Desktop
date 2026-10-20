import Core
import Foundation
import KanaKanjiConverterModule
import Testing

private func inputString(from action: UserAction) -> String? {
    guard case .input(let pieces) = action else {
        return nil
    }
    return pieces.inputString(preferIntention: true)
}

private func rawInputString(from action: UserAction) -> String? {
    guard case .input(let pieces) = action else {
        return nil
    }
    return pieces.inputString(preferIntention: false)
}

private func makeEvent(
    logicalKey: String,
    characters: String?,
    modifiers: KeyEventCore.ModifierFlag
) -> KeyEventCore {
    KeyEventCore(
        modifierFlags: modifiers,
        characters: characters,
        charactersIgnoringModifiers: logicalKey,
        keyCode: 0
    )
}

@Test func testOptionPunctuationMappings() async throws {
    let option: KeyEventCore.ModifierFlag = [.option]
    let shiftOption: KeyEventCore.ModifierFlag = [.shift, .option]

    // Mapping tests must not share mutable process preferences with parallel sessions.
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ",", characters: "≤", modifiers: option),
        inputLanguage: .japanese,
        punctuationStyle: .kutenAndToten
    )) == "，")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ".", characters: "≥", modifiers: option),
        inputLanguage: .japanese,
        punctuationStyle: .kutenAndToten
    )) == "．")

    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ",", characters: "≤", modifiers: option),
        inputLanguage: .japanese,
        punctuationStyle: .periodAndComma
    )) == "、")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ".", characters: "≥", modifiers: option),
        inputLanguage: .japanese,
        punctuationStyle: .periodAndComma
    )) == "。")

    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: "[", characters: "[", modifiers: option),
        inputLanguage: .japanese
    )) == "［")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: "[", characters: "{", modifiers: shiftOption),
        inputLanguage: .japanese
    )) == "｛")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: "]", characters: "]", modifiers: option),
        inputLanguage: .japanese
    )) == "］")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: "]", characters: "}", modifiers: shiftOption),
        inputLanguage: .japanese
    )) == "｝")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ",", characters: "¯", modifiers: shiftOption),
        inputLanguage: .japanese
    )) == "¯")
    #expect(inputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: ".", characters: "˘", modifiers: shiftOption),
        inputLanguage: .japanese
    )) == "˘")
}

@Test func testTypeBackSlashCanBeInjectedWithoutReadingProcessDefaults() async throws {
    #expect(rawInputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: "¥", characters: "¥", modifiers: []),
        inputLanguage: .japanese,
        typeBackSlash: true
    )) == "\\")
    #expect(rawInputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: "¥", characters: "¥", modifiers: [.option]),
        inputLanguage: .japanese,
        typeBackSlash: true
    )) == "¥")
    #expect(rawInputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: "¥", characters: "¥", modifiers: []),
        inputLanguage: .japanese,
        typeBackSlash: false
    )) == "¥")
    #expect(rawInputString(from: UserAction.getUserAction(
        eventCore: makeEvent(logicalKey: "¥", characters: "¥", modifiers: [.option]),
        inputLanguage: .japanese,
        typeBackSlash: false
    )) == "\\")
}
