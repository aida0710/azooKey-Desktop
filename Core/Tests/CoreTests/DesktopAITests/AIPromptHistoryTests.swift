import Core
import Foundation
import Testing

/// The history keeps instructions only. Ported from the Ubuntu prompt tests.
struct AIPromptHistoryTests {
    static let englishDefaults = ["Elaborate on this text", "Rewrite this clearly", "Use formal language", "Translate into English"]
    static let japaneseDefaults = ["内容を詳しくする", "わかりやすく書き直す", "敬語に直す", "英語へ翻訳する"]

    /// An English history in a fresh directory; the settings are not read.
    static func withHistory(_ test: (AIPromptHistory) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(AIPromptHistory(fileURL: directory.appendingPathComponent("azookey-tree/prompts.json"), language: .english))
    }

    /// The same history file shown in another language, as after the setting changes.
    static func reopened(_ history: AIPromptHistory, in language: Localization.Language) -> AIPromptHistory {
        AIPromptHistory(fileURL: history.fileURL, language: language)
    }

    static func writeFile(of history: AIPromptHistory, _ json: String) throws {
        try FileManager.default.createDirectory(at: history.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: history.fileURL)
    }

    @Test func aMissingFileOffersThePinnedDefaultsInTheChosenLanguage() throws {
        try Self.withHistory { history in
            let items = history.load()
            #expect(items.map(\.prompt) == Self.englishDefaults)
            #expect(items.allSatisfy { $0.pinned && $0.lastUsed == 0 && $0.shortcut == nil })
            #expect(Self.reopened(history, in: .japanese).load().map(\.prompt) == Self.japaneseDefaults)
            #expect(AIPromptHistory.defaultPrompts(in: .japanese) == Self.japaneseDefaults)
        }
    }

    @Test func changingTheLanguageReplacesOnlyDefaultsThatWereNeverUsed() throws {
        try Self.withHistory { history in
            let shortcut = #"{"key": "e", "modifiers": 6}"#
            try Self.writeFile(of: history, """
            [{"prompt": "Elaborate on this text", "pinned": true, "lastUsed": 0},
             {"prompt": "Rewrite this clearly", "pinned": true, "lastUsed": 5},
             {"prompt": "Use formal language", "pinned": true, "lastUsed": 0, "shortcut": \(shortcut)},
             {"prompt": "Translate into English", "pinned": false, "lastUsed": 0},
             {"prompt": "自分の指示", "pinned": true, "lastUsed": 0}]
            """)
            let japanese = Self.reopened(history, in: .japanese).load()
            #expect(japanese.map(\.prompt) == ["Rewrite this clearly", "内容を詳しくする", "Use formal language", "自分の指示",
                                               "Translate into English"],
                    "used, given a shortcut, unpinned and the user's own instructions keep their text")
            #expect(japanese.first { $0.prompt == "内容を詳しくする" }?.pinned == true)
            #expect(japanese.first { $0.prompt == "Use formal language" }?.shortcut == KeyboardShortcut(key: "e", modifiers: [.control, .option]))
        }
    }

    @Test func theEnglishWordsEarlierVersionsSavedAreReplacedToo() throws {
        try Self.withHistory { history in
            try Self.writeFile(of: history, """
            [{"prompt": "敬語", "pinned": false, "lastUsed": 1},
             {"prompt": "elaborate", "pinned": true, "lastUsed": 0}, {"prompt": "rewrite", "pinned": true, "lastUsed": 0},
             {"prompt": "formal", "pinned": true, "lastUsed": 0}, {"prompt": "english", "pinned": true, "lastUsed": 0}]
            """)
            #expect(history.load().map(\.prompt) == Self.englishDefaults + ["敬語"])
            #expect(Self.reopened(history, in: .japanese).load().map(\.prompt) == Self.japaneseDefaults + ["敬語"])
        }
    }

    @Test func savingKeepsUnusedDefaultsSwitchableAndUsingOneKeepsIt() throws {
        try Self.withHistory { history in
            // Saving in Japanese writes the unused defaults with their Japanese text.
            try Self.reopened(history, in: .japanese).recordUse("わかりやすく書き直す")
            let english = history.load()
            #expect(english.map(\.prompt) == ["わかりやすく書き直す", "Elaborate on this text", "Use formal language",
                                              "Translate into English"],
                    "the used default stays Japanese and first; the others follow the language")
            #expect(english.first?.pinned == true && (english.first?.lastUsed ?? 0) > 0)
        }
    }

    @Test func aDefaultIsNotListedAgainBesideTheUsersInstructionWithTheSameText() throws {
        try Self.withHistory { history in
            try Self.writeFile(of: history, """
            [{"prompt": "内容を詳しくする", "pinned": true, "lastUsed": 0},
             {"prompt": "Elaborate on this text", "pinned": false, "lastUsed": 3}]
            """)
            let items = history.load()
            #expect(items.map(\.prompt) == ["Elaborate on this text"])
            #expect(items.first?.pinned == false, "the user's own instruction is the one shown")
        }
    }

    @Test func pinsSurviveTheRecentLimitAndShortcutsAreUnique() throws {
        try Self.withHistory { history in
            let shortcut = KeyboardShortcut(key: "e", modifiers: [.control, .option])
            try history.save("敬語", pinned: true, shortcut: shortcut)
            for index in 0..<15 {
                try history.save("指示\(index)", pinned: false, shortcut: nil, usedAt: Date(timeIntervalSince1970: Double(index + 1)))
            }
            let items = history.load()
            #expect(items.filter { !$0.pinned }.count == AIPromptHistory.recentLimit)
            #expect(items.first { !$0.pinned }?.prompt == "指示14", "most recent first")
            #expect(items.first?.prompt == "敬語", "pinned first, then the defaults saved with the first instruction")
            #expect(items.contains { $0.prompt == "敬語" && $0.shortcut == shortcut })
            #expect(throws: AIPromptHistory.Failure.duplicateShortcut) {
                try history.save("重複", pinned: true, shortcut: shortcut)
            }
            #expect(history.pinnedShortcuts().map(\.prompt) == ["敬語"])
        }
    }

    @Test func theFileIsPrivateToTheUser() throws {
        try Self.withHistory { history in
            try history.save("敬語", pinned: false, shortcut: nil)
            let file = try FileManager.default.attributesOfItem(atPath: history.fileURL.path)
            let directory = try FileManager.default.attributesOfItem(atPath: history.fileURL.deletingLastPathComponent().path)
            #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            // Saving again replaces the existing file.
            try history.save("英訳", pinned: false, shortcut: nil)
            #expect(history.load().contains { $0.prompt == "英訳" })
        }
    }

    @Test func anUnpinnedInstructionKeepsNoShortcutAndResavingMovesItToTheFront() throws {
        try Self.withHistory { history in
            try history.save("敬語", pinned: false, shortcut: KeyboardShortcut(key: "k", modifiers: [.control]),
                             usedAt: Date(timeIntervalSince1970: 10))
            try history.save("英訳", pinned: false, shortcut: nil, usedAt: Date(timeIntervalSince1970: 20))
            try history.save("敬語", pinned: false, shortcut: nil, usedAt: Date(timeIntervalSince1970: 30))
            let unpinned = history.load().filter { !$0.pinned }
            #expect(unpinned.map(\.prompt) == ["敬語", "英訳"])
            #expect(unpinned.allSatisfy { $0.shortcut == nil })
        }
    }

    @Test func recordingAUseKeepsThePinAndShortcutAndANewInstructionStartsUnpinned() throws {
        try Self.withHistory { history in
            let shortcut = KeyboardShortcut(key: "e", modifiers: [.control, .option])
            try history.save("敬語", pinned: true, shortcut: shortcut, usedAt: Date(timeIntervalSince1970: 10))
            try history.recordUse("英訳")
            try history.recordUse("敬語")
            let items = history.load()
            #expect(items.first { $0.prompt == "敬語" }?.pinned == true)
            #expect(items.first { $0.prompt == "敬語" }?.shortcut == shortcut)
            #expect(items.first { $0.prompt == "英訳" }?.pinned == false)
            #expect(items.first { $0.pinned }?.prompt == "敬語", "the used pinned instruction moves to the front")
        }
    }

    @Test func importedItemsAreRankedAndKeepOnlyTheFirstShortcutOfAPinnedInstruction() throws {
        try Self.withHistory { history in
            let shortcut = KeyboardShortcut(key: "e", modifiers: [.control, .option])
            let other = KeyboardShortcut(key: "k", modifiers: [.control])
            var items = [
                AIPromptHistory.Item(prompt: "古い固定", pinned: true, lastUsed: 1, shortcut: shortcut),
                AIPromptHistory.Item(prompt: "新しい固定", pinned: true, lastUsed: 2, shortcut: shortcut),
                AIPromptHistory.Item(prompt: "固定しない", pinned: false, lastUsed: 3, shortcut: other),
                AIPromptHistory.Item(prompt: "固定しない", pinned: false, lastUsed: 0, shortcut: nil)
            ]
            items += (0..<15).map { AIPromptHistory.Item(prompt: "指示\($0)", pinned: false, lastUsed: 0, shortcut: nil) }
            try history.importItems(items)
            let imported = history.load()
            #expect(imported.prefix(3).map(\.prompt) == ["新しい固定", "古い固定", "固定しない"])
            #expect(imported.map(\.shortcut).prefix(3) == [shortcut, nil, nil])
            #expect(imported.filter { $0.prompt == "固定しない" }.count == 1)
            #expect(imported.filter { !$0.pinned }.count == AIPromptHistory.recentLimit)
            #expect(imported.last?.prompt == "指示8", "equal times keep the imported order")
        }
    }

    @Test func importingDoesNothingOnceTheHistoryFileExists() throws {
        try Self.withHistory { history in
            try history.save("敬語", pinned: false, shortcut: nil)
            try history.importItems([AIPromptHistory.Item(prompt: "古い", pinned: true, lastUsed: 1, shortcut: nil)])
            #expect(!history.load().contains { $0.prompt == "古い" })
        }
    }

    @Test func anUnreadableFileIsAnEmptyHistory() throws {
        try Self.withHistory { history in
            try FileManager.default.createDirectory(at: history.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"broken\":".utf8).write(to: history.fileURL)
            #expect(history.load().isEmpty)
        }
    }

    @Test func theUbuntuFileFormatIsReadAsIs() throws {
        try Self.withHistory { history in
            try FileManager.default.createDirectory(at: history.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let saved = #"[{"prompt": "古い", "pinned": false, "lastUsed": 1}, {"prompt": "敬語", "pinned": true, "lastUsed": 2, "shortcut": {"key": "e", "modifiers": 6}}]"#
            try Data(saved.utf8).write(to: history.fileURL)
            let items = history.load()
            #expect(items.map(\.prompt) == ["敬語", "古い"])
            #expect(items.first?.shortcut == KeyboardShortcut(key: "e", modifiers: [.control, .option]))
        }
    }
}

struct DesktopShortcutTextTests {
    @Test func theTypedNotationRoundTripsWithModifiersInDisplayOrder() throws {
        let shortcut = try #require(try DesktopShortcutText.parse("Alt+Ctrl+E"))
        #expect(shortcut == KeyboardShortcut(key: "e", modifiers: [.control, .option]))
        #expect(DesktopShortcutText.text(for: shortcut) == "Ctrl+Alt+e")
        #expect(DesktopShortcutText.text(for: KeyboardShortcut(key: "s", modifiers: [.shift, .command])) == "Shift+Super+s")
        #expect(DesktopShortcutText.text(for: nil).isEmpty)
    }

    @Test func blankTextMeansNoShortcut() throws {
        #expect(try DesktopShortcutText.parse("  ") == nil)
    }

    @Test(arguments: ["e", "ee", "Ctrl+", "Ctrl+ee", "Hyper+e", "Ctrl + e", "+"])
    func otherNotationsAreRejected(text: String) {
        let expected: DesktopShortcutText.Failure = text == "e" ? .modifierRequired : .format
        #expect(throws: expected) { try DesktopShortcutText.parse(text) }
    }
}
